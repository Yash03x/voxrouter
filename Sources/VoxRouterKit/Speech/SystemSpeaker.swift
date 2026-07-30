import AVFoundation
import Foundation

/// Text-to-speech through `AVSpeechSynthesizer`.
///
/// Uses the same system voices as the `say` command but stays in-process:
/// no fork/exec per utterance, and `stopSpeaking(at: .immediate)` cuts off
/// mid-word instantly. Barge-in with the `say` binary would mean killing a
/// process and hoping the audio device is released in time.
public final class SystemSpeaker: NSObject, Speaker, @unchecked Sendable {
    public let identifier = "avspeechsynthesizer"

    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private let voice: AVSpeechSynthesisVoice?
    private let rate: Float

    /// - Parameters:
    ///   - voiceIdentifier: an `AVSpeechSynthesisVoice` identifier or a name
    ///     like "Samantha". Nil uses the system default.
    ///   - rate: `AVSpeechUtteranceDefaultSpeechRate` is deliberately slow for
    ///     accessibility; a little faster suits short status updates better.
    public init(voiceIdentifier: String? = nil, rate: Float = 0.52) {
        self.voice = Self.resolveVoice(voiceIdentifier)
        self.rate = rate
        super.init()
        synthesizer.delegate = self
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Primes the synthesizer so the first real reply isn't slow.
    ///
    /// Measured: the first utterance in a process costs roughly 700 ms of
    /// warm-up on top of the audio itself (voice asset loading and audio-path
    /// setup), while later ones don't. In an always-on daemon that cost should
    /// be paid at launch, not the first time the user asks for something.
    ///
    /// Silent by construction — zero volume and maximum rate.
    public func prewarm() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let utterance = AVSpeechUtterance(string: "a")
            utterance.volume = 0
            utterance.rate = AVSpeechUtteranceMaximumSpeechRate
            if let voice { utterance.voice = voice }
            synthesizer.speak(utterance)
        }
    }

    public func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Only one utterance at a time: overlapping speech is unintelligible,
        // and status updates are short enough that queueing them would fall
        // behind reality anyway.
        stop()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let utterance = AVSpeechUtterance(string: trimmed)
            utterance.rate = rate
            if let voice { utterance.voice = voice }
            synthesizer.speak(utterance)
        }
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        resume()
    }

    private func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }

    // MARK: - Voices

    public static func availableVoices() -> [(name: String, identifier: String, language: String)] {
        AVSpeechSynthesisVoice.speechVoices().map {
            ($0.name, $0.identifier, $0.language)
        }
    }

    /// Accepts either a full voice identifier or a human name, because nobody
    /// remembers `com.apple.voice.compact.en-US.Samantha`.
    static func resolveVoice(_ wanted: String?) -> AVSpeechSynthesisVoice? {
        guard let wanted, !wanted.isEmpty else { return nil }
        if let exact = AVSpeechSynthesisVoice(identifier: wanted) { return exact }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let byName = voices.first(where: {
            $0.name.caseInsensitiveCompare(wanted) == .orderedSame
        }) {
            return byName
        }
        return voices.first { $0.name.localizedCaseInsensitiveContains(wanted) }
    }
}

extension SystemSpeaker: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        resume()
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        resume()
    }
}
