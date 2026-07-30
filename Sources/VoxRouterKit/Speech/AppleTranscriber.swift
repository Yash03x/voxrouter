import AVFoundation
import Foundation
import Speech

/// On-device recognition via `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+).
///
/// Chosen as the default because it needs no model download managed by us, no
/// Python runtime, and no network — and because being in-process on the ANE
/// keeps the latency budget for a short command in the low hundreds of
/// milliseconds.
@available(macOS 26, *)
public final class AppleTranscriber: Transcriber {
    public let identifier = "apple-speechanalyzer"
    private let locale: Locale
    private let vocabulary: [String]

    /// - Parameter vocabulary: terms to bias recognition toward. Note this
    ///   produced no measurable improvement in testing — see
    ///   `TechnicalVocabulary` for the measurement and the caveats.
    public init(locale: Locale = Locale.current, vocabulary: [String] = TechnicalVocabulary.default) {
        self.locale = locale
        self.vocabulary = vocabulary
    }

    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    public static var installedLocales: [Locale] {
        get async { await SpeechTranscriber.installedLocales }
    }

    public static var supportedLocales: [Locale] {
        get async { await SpeechTranscriber.supportedLocales }
    }

    /// Resolves the closest supported locale, e.g. `en_DE` → `en_US`.
    public static func resolvedLocale(for locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    /// Downloads the on-device model if it isn't present.
    ///
    /// Separated from `transcribe` deliberately: a multi-hundred-megabyte
    /// download must never be triggered implicitly by someone holding a key.
    public static func installModel(
        for locale: Locale,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status != .installed else { return }
        guard status != .unsupported else {
            throw TranscriberError.localeUnsupported(locale.identifier)
        }

        guard let request = try await AssetInventory
            .assetInstallationRequest(supporting: [transcriber]) else {
            // Nothing to install — treat as already satisfied.
            return
        }

        let observation = onProgress.map { handler in
            request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                handler(progress.fractionCompleted)
            }
        }
        defer { observation?.invalidate() }

        try await request.downloadAndInstall()
    }

    public static func modelStatus(for locale: Locale) async -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return "installed"
        case .downloading: return "downloading"
        case .supported: return "supported (not installed)"
        case .unsupported: return "unsupported"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Transcribe

    public func transcribe(samples: [Float]) async throws -> Transcript {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriberError.unavailable("SpeechTranscriber reports unavailable on this device")
        }
        guard !samples.isEmpty else {
            return Transcript(text: "", engine: identifier)
        }

        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.localeUnsupported(locale.identifier)
        }

        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)

        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw TranscriberError.modelNotInstalled(resolved.identifier)
        }

        // The recogniser picks its own preferred format; our pipeline is 16 kHz
        // mono, so convert once here rather than assuming they match.
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        )
        guard let buffer = Self.makeBuffer(from: samples, targetFormat: analyzerFormat) else {
            throw TranscriberError.audioConversionFailed
        }

        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let context = AnalysisContext()
        if !vocabulary.isEmpty {
            context.contextualStrings = [.general: vocabulary]
        }

        let analyzer = SpeechAnalyzer(
            inputSequence: inputStream,
            modules: [transcriber],
            analysisContext: context
        )

        // Consume results concurrently with feeding audio: `results` only yields
        // while analysis is running, so collecting after finalize would miss it.
        let collector = Task { () -> (String, [String]) in
            var text = ""
            var alternatives: [String] = []
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
                alternatives = result.alternatives.map { String($0.characters) }
            }
            return (text, alternatives)
        }

        do {
            // Analysis begins at init when an input sequence is supplied, so we
            // only need to feed and finalize here.
            continuation.yield(AnalyzerInput(buffer: buffer))
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            continuation.finish()
            throw TranscriberError.failed(error.localizedDescription)
        }

        do {
            let (text, alternatives) = try await collector.value
            return Transcript(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                alternatives: alternatives,
                engine: identifier
            )
        } catch {
            throw TranscriberError.failed(error.localizedDescription)
        }
    }

    // MARK: - Audio packaging

    /// Wraps 16 kHz mono float samples in an `AVAudioPCMBuffer`, converting to
    /// `targetFormat` when the recogniser wants something else.
    static func makeBuffer(
        from samples: [Float],
        targetFormat: AVAudioFormat?
    ) -> AVAudioPCMBuffer? {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioConstants.sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }

        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = sourceBuffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { pointer in
            channel.update(from: pointer.baseAddress!, count: samples.count)
        }

        guard let targetFormat, targetFormat != sourceFormat else { return sourceBuffer }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return nil
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: capacity
        ) else { return nil }

        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return sourceBuffer
        }
        if error != nil { return nil }
        return converted
    }
}
