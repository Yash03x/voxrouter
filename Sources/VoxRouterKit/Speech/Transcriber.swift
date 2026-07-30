import Foundation

public struct Transcript: Sendable, Equatable {
    public let text: String
    /// Runner-up hypotheses, when the backend reports them. Useful for wake-word
    /// matching, where the best hypothesis may mis-hear a made-up word.
    public let alternatives: [String]
    public let engine: String

    public init(text: String, alternatives: [String] = [], engine: String) {
        self.text = text
        self.alternatives = alternatives
        self.engine = engine
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public enum TranscriberError: Error, LocalizedError {
    case unavailable(String)
    case localeUnsupported(String)
    case modelNotInstalled(String)
    case audioConversionFailed
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return "Speech recognition unavailable: \(detail)"
        case .localeUnsupported(let identifier):
            return "No on-device speech model supports \(identifier)."
        case .modelNotInstalled(let identifier):
            return """
            The speech model for \(identifier) isn't installed yet. \
            Run `voxrouter transcribe --install` to download it.
            """
        case .audioConversionFailed:
            return "Could not convert captured audio into the recogniser's format."
        case .failed(let detail):
            return "Transcription failed: \(detail)"
        }
    }
}

/// Turns captured audio into text.
///
/// The seam that keeps the recogniser replaceable. Everything upstream produces
/// 16 kHz mono float samples and everything downstream consumes a `Transcript`,
/// so swapping Apple's on-device recogniser for Parakeet-MLX or whisper.cpp is a
/// new conformance and a config change — not a rewrite.
public protocol Transcriber: Sendable {
    /// Stable identifier, recorded on the transcript so it's clear after the
    /// fact which backend produced a given result.
    var identifier: String { get }

    /// Transcribe a complete utterance.
    ///
    /// One-shot rather than streaming: push-to-talk and wake-word capture both
    /// hand over a finished clip, and a partial-results API would add complexity
    /// no current caller can use.
    func transcribe(samples: [Float]) async throws -> Transcript
}
