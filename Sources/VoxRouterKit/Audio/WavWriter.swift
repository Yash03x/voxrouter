import Foundation

/// Minimal 16-bit PCM WAV writer.
///
/// Exists so captured segments can be listened to before any recogniser is
/// wired up — the fastest way to confirm the preroll really is capturing the
/// start of a word rather than clipping it.
public enum WavWriter {
    public static func write(
        samples: [Float],
        to url: URL,
        sampleRate: Double = AudioConstants.sampleRate
    ) throws {
        let byteRate = Int(sampleRate) * 2  // mono, 16-bit
        var data = Data(capacity: 44 + samples.count * 2)

        func appendASCII(_ string: String) { data.append(contentsOf: string.utf8) }
        func appendUInt32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendUInt16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + samples.count * 2))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)                      // PCM
        appendUInt16(1)                      // mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(2)                      // block align
        appendUInt16(16)                     // bits per sample
        appendASCII("data")
        appendUInt32(UInt32(samples.count * 2))

        for sample in samples {
            // Clamp before scaling: a float overshoot would wrap and click.
            let clamped = sample.clamped(to: -1...1)
            appendUInt16(UInt16(bitPattern: Int16(clamped * 32767)))
        }

        try data.write(to: url, options: .atomic)
    }
}
