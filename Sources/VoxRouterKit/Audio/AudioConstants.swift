import Foundation

public enum AudioConstants {
    /// 16 kHz mono: what every on-device ASR here wants (Apple's
    /// SpeechAnalyzer, whisper.cpp, Parakeet). Converting once at the tap means
    /// no resampling later in the hot path.
    public static let sampleRate: Double = 16_000

    /// 30 ms. Long enough for a stable energy estimate, short enough that a
    /// wake word's onset isn't smeared across the trigger decision.
    public static let frameSampleCount = 480

    public static var frameDuration: TimeInterval {
        Double(frameSampleCount) / sampleRate
    }

    public static func frames(forMilliseconds ms: Int) -> Int {
        max(1, Int((Double(ms) / 1000.0 / frameDuration).rounded()))
    }
}

/// Converts a linear amplitude to dBFS, floored so silence doesn't produce
/// -infinity and poison the noise-floor average.
@inlinable
public func amplitudeToDb(_ amplitude: Float) -> Float {
    guard amplitude > 1e-9 else { return -120 }
    return 20 * log10(amplitude)
}
