import Foundation

public struct PushToTalkConfig: Sendable {
    /// Audio kept from *before* the key registered.
    ///
    /// People start talking as they press, not after. There's also latency in
    /// the keyboard, the event dispatcher, and the audio buffer itself. Because
    /// the engine runs continuously, this costs nothing to provide.
    public var prerollFrames: Int
    /// Hard cap, so a stuck key can't buffer without bound.
    public var maxFrames: Int
    /// Recordings shorter than this are treated as an accidental tap.
    public var minFrames: Int

    public init(
        prerollFrames: Int = AudioConstants.frames(forMilliseconds: 300),
        maxFrames: Int = AudioConstants.frames(forMilliseconds: 120_000),
        minFrames: Int = AudioConstants.frames(forMilliseconds: 250)
    ) {
        self.prerollFrames = prerollFrames
        self.maxFrames = maxFrames
        self.minFrames = minFrames
    }
}

public struct PushToTalkClip: Sendable {
    public let samples: [Float]
    public let duration: TimeInterval
    public let peakDb: Float
    /// True when the cap stopped it rather than the key being released.
    public let truncated: Bool
}

/// Captures audio while a key is held.
///
/// The microphone runs **continuously** from `warmUp()` rather than starting on
/// key-press. That's the whole performance argument for this class: starting
/// `AVAudioEngine` takes on the order of 100–300 ms, which would swallow the
/// first syllable of every command. With the engine already running, a press is
/// just a mark in a ring buffer — and the preroll needed to cover human and
/// system latency comes for free.
///
/// Note this path deliberately does **not** consult `VoiceGate`. When the user
/// says "record now", second-guessing them with a voice-activity detector can
/// only make things worse; the VAD exists for the hands-free path.
public final class PushToTalkRecorder: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case idle
        case recording
    }

    private let source: any AudioSource
    private let config: PushToTalkConfig
    private let lock = NSLock()

    /// Rolling recent audio, maintained whether or not we're recording.
    private var preroll: [[Float]] = []
    private var capturing: [[Float]] = []
    private var state: State = .idle
    private var isWarm = false
    private var clipHandler: (@Sendable (PushToTalkClip) -> Void)?
    private var stateHandler: (@Sendable (State) -> Void)?

    public init(source: any AudioSource, config: PushToTalkConfig = PushToTalkConfig()) {
        self.source = source
        self.config = config
        self.preroll.reserveCapacity(config.prerollFrames + 1)
    }

    public var currentState: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func onClip(_ handler: @escaping @Sendable (PushToTalkClip) -> Void) {
        lock.lock(); clipHandler = handler; lock.unlock()
    }

    public func onStateChange(_ handler: @escaping @Sendable (State) -> Void) {
        lock.lock(); stateHandler = handler; lock.unlock()
    }

    /// Starts the microphone and keeps it running. Call once, at launch.
    public func warmUp() throws {
        lock.lock()
        guard !isWarm else { lock.unlock(); return }
        isWarm = true
        lock.unlock()

        try source.start(
            onFrame: { [weak self] frame in self?.ingest(frame) },
            onEnd: {}
        )
    }

    public func shutDown() {
        source.stop()
        lock.lock()
        isWarm = false
        state = .idle
        preroll.removeAll()
        capturing.removeAll()
        lock.unlock()
    }

    public func beginRecording() {
        lock.lock()
        guard state == .idle else { lock.unlock(); return }
        state = .recording
        // Seed with the rolling buffer, so audio from before the keypress is
        // included rather than lost.
        capturing = preroll
        let handler = stateHandler
        lock.unlock()
        handler?(.recording)
    }

    public func endRecording() {
        lock.lock()
        guard state == .recording else { lock.unlock(); return }
        state = .idle
        let frames = capturing
        capturing.removeAll(keepingCapacity: true)
        let clipHandler = self.clipHandler
        let stateHandler = self.stateHandler
        lock.unlock()

        stateHandler?(.idle)

        guard frames.count >= config.minFrames else {
            Log.audio.notice("push-to-talk clip discarded: too short")
            return
        }
        if let clip = Self.makeClip(frames: frames, truncated: false) {
            clipHandler?(clip)
        }
    }

    // MARK: - Frame ingestion

    private func ingest(_ frame: [Float]) {
        lock.lock()

        switch state {
        case .idle:
            preroll.append(frame)
            if preroll.count > config.prerollFrames {
                preroll.removeFirst(preroll.count - config.prerollFrames)
            }
            lock.unlock()

        case .recording:
            capturing.append(frame)
            // Keep the rolling buffer current too, so a clip that ends and
            // another that starts immediately after still gets preroll.
            preroll.append(frame)
            if preroll.count > config.prerollFrames {
                preroll.removeFirst(preroll.count - config.prerollFrames)
            }

            guard capturing.count >= config.maxFrames else {
                lock.unlock()
                return
            }
            // Cap reached — emit what we have and stop, rather than growing
            // without bound behind a stuck key.
            state = .idle
            let frames = capturing
            capturing.removeAll(keepingCapacity: true)
            let clipHandler = self.clipHandler
            let stateHandler = self.stateHandler
            lock.unlock()

            stateHandler?(.idle)
            Log.audio.notice("push-to-talk hit its duration cap")
            if let clip = Self.makeClip(frames: frames, truncated: true) {
                clipHandler?(clip)
            }
        }
    }

    private static func makeClip(frames: [[Float]], truncated: Bool) -> PushToTalkClip? {
        guard !frames.isEmpty else { return nil }
        var samples = [Float]()
        samples.reserveCapacity(frames.count * AudioConstants.frameSampleCount)
        var peak: Float = 0
        for frame in frames {
            samples.append(contentsOf: frame)
            for sample in frame { peak = max(peak, abs(sample)) }
        }
        return PushToTalkClip(
            samples: samples,
            duration: Double(samples.count) / AudioConstants.sampleRate,
            peakDb: amplitudeToDb(peak),
            truncated: truncated
        )
    }
}
