import Foundation

/// Speaks text aloud.
///
/// The mirror of `Transcriber`: a seam so the voice can be swapped (Kokoro,
/// ElevenLabs) without touching callers.
public protocol Speaker: Sendable {
    var identifier: String { get }

    /// Speaks `text`, returning when it has finished or been interrupted.
    func speak(_ text: String) async

    /// Stops immediately, discarding anything queued. Used for barge-in: when
    /// the user starts talking, the assistant must shut up at once.
    func stop()

    var isSpeaking: Bool { get }
}

/// Discards everything. Used when speech is disabled, and in tests.
public struct SilentSpeaker: Speaker {
    public let identifier = "silent"
    public init() {}
    public func speak(_ text: String) async {}
    public func stop() {}
    public var isSpeaking: Bool { false }
}
