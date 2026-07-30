import AVFoundation
import Foundation

/// A producer of fixed-size 16 kHz mono frames.
///
/// Abstracted so the segmenter can be driven by synthetic audio in tests — a
/// microphone needs TCC consent and a live session, neither of which belongs in
/// a unit test.
public protocol AudioSource: AnyObject, Sendable {
    /// `onFrame` is called with exactly `AudioConstants.frameSampleCount`
    /// samples, from an unspecified thread.
    ///
    /// `onEnd` signals that no more frames are coming. A microphone never ends
    /// on its own, but a finite source (a file, or a test script) must say so —
    /// otherwise a consumer awaiting the segment stream waits forever.
    func start(
        onFrame: @escaping @Sendable ([Float]) -> Void,
        onEnd: @escaping @Sendable () -> Void
    ) throws
    func stop()
}

public enum AudioSourceError: Error, LocalizedError {
    case microphonePermissionDenied
    case noInputDevice
    case unsupportedInputFormat(String)
    case converterUnavailable
    case engineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return """
            Microphone access denied. Grant it in System Settings ▸ Privacy & \
            Security ▸ Microphone for whichever app is running voxrouter (your \
            terminal, for a CLI run).
            """
        case .noInputDevice:
            return "No audio input device available."
        case .unsupportedInputFormat(let detail):
            return "Unsupported input format: \(detail)"
        case .converterUnavailable:
            return "Could not build a 16 kHz mono converter for the input device."
        case .engineFailed(let detail):
            return "Audio engine failed to start: \(detail)"
        }
    }
}

/// Live microphone capture, resampled once to 16 kHz mono.
public final class MicrophoneSource: AudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let accumulator = FrameAccumulator(frameSize: AudioConstants.frameSampleCount)
    private var isRunning = false

    public init() {}

    /// Current authorization, without prompting.
    public static var permissionStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Prompts if undetermined. The prompt requires a foreground app context —
    /// from a bare daemon it fails silently, which is exactly why the shipping
    /// form of this is a menu-bar `.app`.
    public static func requestPermission() async -> Bool {
        switch permissionStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// `onEnd` is retained but never invoked spontaneously: a live microphone
    /// only stops when we stop it.
    public func start(
        onFrame: @escaping @Sendable ([Float]) -> Void,
        onEnd: @escaping @Sendable () -> Void = {}
    ) throws {
        guard !isRunning else { return }
        guard Self.permissionStatus != .denied, Self.permissionStatus != .restricted else {
            throw AudioSourceError.microphonePermissionDenied
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            // A zero format means the OS handed us no usable input — typically
            // no device, or consent not yet granted.
            throw AudioSourceError.noInputDevice
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioConstants.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioSourceError.converterUnavailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioSourceError.converterUnavailable
        }

        let accumulator = self.accumulator
        let ratio = AudioConstants.sampleRate / inputFormat.sampleRate

        // 1024-frame tap: ~21 ms at 48 kHz. Small enough to keep latency low,
        // large enough not to wake the callback needlessly often.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            guard buffer.frameLength > 0 else { return }

            // Headroom on the output capacity: sample-rate conversion can emit
            // slightly more than the naive ratio suggests, and a short buffer
            // silently truncates audio.
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: capacity
            ) else { return }

            var supplied = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }

            if let conversionError {
                Log.audio.error(
                    "conversion failed: \(conversionError.localizedDescription, privacy: .public)"
                )
                return
            }

            guard let channel = converted.floatChannelData?[0],
                  converted.frameLength > 0 else { return }

            accumulator.append(
                UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)),
                emit: onFrame
            )
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioSourceError.engineFailed(error.localizedDescription)
        }
        isRunning = true
        Log.audio.notice(
            "microphone started: \(inputFormat.sampleRate, privacy: .public) Hz → 16 kHz mono"
        )
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        accumulator.reset()
        isRunning = false
    }
}

/// Re-chunks arbitrary-length buffers into exact fixed-size frames.
///
/// The tap delivers whatever the device felt like giving us, and after
/// resampling the count is fractional. The VAD needs uniform frames or its
/// energy estimates and frame-count thresholds mean nothing.
final class FrameAccumulator: @unchecked Sendable {
    private let frameSize: Int
    private var pending: [Float]
    private let lock = NSLock()

    init(frameSize: Int) {
        self.frameSize = frameSize
        self.pending = []
        self.pending.reserveCapacity(frameSize * 4)
    }

    func append(_ samples: UnsafeBufferPointer<Float>, emit: (([Float]) -> Void)) {
        lock.lock()
        pending.append(contentsOf: samples)
        var ready: [[Float]] = []
        while pending.count >= frameSize {
            ready.append(Array(pending[0..<frameSize]))
            pending.removeFirst(frameSize)
        }
        lock.unlock()
        // Emitted outside the lock: the consumer may be slow, and holding the
        // lock across it would stall the audio callback.
        for frame in ready { emit(frame) }
    }

    func reset() {
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
