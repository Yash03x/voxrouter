import AVFoundation
import Foundation

public enum AudioFileError: Error, LocalizedError {
    case unreadable(String)
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return "Could not read audio file: \(detail)"
        case .conversionFailed(let detail): return "Could not convert audio: \(detail)"
        }
    }
}

/// Loads any audio file the system can decode as 16 kHz mono float samples —
/// the same shape the microphone path produces.
///
/// Built on `AVAudioFile` rather than a hand-rolled WAV parser so it handles
/// AIFF, m4a, differing bit depths and sample rates for free. That matters for
/// testing: `say` can synthesise a known phrase, and transcribing it verifies the
/// recogniser end to end without anyone speaking.
public enum AudioFileLoader {
    public static func loadMono16k(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioFileError.unreadable(error.localizedDescription)
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioConstants.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioFileError.conversionFailed("could not build 16 kHz mono format")
        }

        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: frameCount
        ) else {
            throw AudioFileError.conversionFailed("could not allocate a read buffer")
        }
        do {
            try file.read(into: sourceBuffer)
        } catch {
            throw AudioFileError.unreadable(error.localizedDescription)
        }

        if sourceFormat == targetFormat {
            return samples(from: sourceBuffer)
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioFileError.conversionFailed("no converter from \(sourceFormat) to 16 kHz mono")
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: capacity
        ) else {
            throw AudioFileError.conversionFailed("could not allocate a conversion buffer")
        }

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
        if let error {
            throw AudioFileError.conversionFailed(error.localizedDescription)
        }
        return samples(from: converted)
    }

    private static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
