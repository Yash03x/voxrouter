import AVFoundation
import Foundation
import Testing
@testable import VoxRouterKit

/// Proves the seam is real: anything conforming to `Transcriber` drops in
/// without touching callers.
private struct StubTranscriber: Transcriber {
    let identifier = "stub"
    let result: Result<Transcript, TranscriberError>

    func transcribe(samples: [Float]) async throws -> Transcript {
        try result.get()
    }
}

private func scratchFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("voxrouter-\(UUID().uuidString)-\(name)")
}

@Suite("Transcript")
struct TranscriptTests {
    @Test("Whitespace-only text counts as empty")
    func whitespaceIsEmpty() {
        #expect(Transcript(text: "   \n ", engine: "x").isEmpty)
        #expect(Transcript(text: "", engine: "x").isEmpty)
        #expect(!Transcript(text: "run the tests", engine: "x").isEmpty)
    }

    @Test("A stub backend satisfies the protocol")
    func stubConforms() async throws {
        let stub = StubTranscriber(
            result: .success(Transcript(text: "hello", alternatives: ["hallo"], engine: "stub"))
        )
        let transcript = try await stub.transcribe(samples: [0, 0, 0])
        #expect(transcript.text == "hello")
        #expect(transcript.alternatives == ["hallo"])
        #expect(transcript.engine == "stub")
    }

    @Test("Backend errors propagate rather than yielding empty text")
    func errorsPropagate() async {
        let stub = StubTranscriber(result: .failure(.unavailable("no model")))
        await #expect(throws: TranscriberError.self) {
            _ = try await stub.transcribe(samples: [0])
        }
    }
}

@Suite("Audio file round trip")
struct AudioFileLoaderTests {
    /// The capture path and the file path must agree, or a WAV saved by
    /// `ptt`/`listen` would transcribe as garbage.
    @Test("Samples survive a write/read round trip")
    func roundTripPreservesSamples() throws {
        let url = scratchFile("round.wav")
        defer { try? FileManager.default.removeItem(at: url) }

        // A 200 Hz tone — arbitrary but distinctive.
        let count = AudioConstants.frameSampleCount * 10
        let original = (0..<count).map { index in
            sin(2 * Float.pi * 200 * Float(index) / Float(AudioConstants.sampleRate)) * 0.5
        }

        try WavWriter.write(samples: original, to: url)
        let loaded = try AudioFileLoader.loadMono16k(url: url)

        #expect(loaded.count == original.count)
        // 16-bit quantisation, so compare with tolerance rather than exactly.
        var maxError: Float = 0
        for (a, b) in zip(original, loaded) { maxError = max(maxError, abs(a - b)) }
        #expect(maxError < 0.001, "max sample error \(maxError)")
    }

    @Test("A missing file reports a readable error")
    func missingFileErrors() {
        #expect(throws: AudioFileError.self) {
            _ = try AudioFileLoader.loadMono16k(url: scratchFile("nope.wav"))
        }
    }

    @Test("An empty sample array writes and reads back as empty")
    func emptyRoundTrip() throws {
        let url = scratchFile("empty.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try WavWriter.write(samples: [], to: url)
        #expect(try AudioFileLoader.loadMono16k(url: url).isEmpty)
    }

    @Test("Samples beyond full scale are clamped rather than wrapped")
    func clampsOverflow() throws {
        let url = scratchFile("loud.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        // Without clamping these wrap to large negative values and click.
        try WavWriter.write(samples: [2.0, -2.0, 1.5, -1.5], to: url)
        let loaded = try AudioFileLoader.loadMono16k(url: url)
        #expect(loaded.allSatisfy { $0 <= 1.0 && $0 >= -1.0 })
        #expect(loaded[0] > 0.9)
        #expect(loaded[1] < -0.9)
    }
}

/// swift-testing's macros reject `@available`, so availability is checked at
/// runtime inside each test instead.
@Suite("Apple transcriber audio packaging")
struct AppleTranscriberBufferTests {
    @Test("Matching format passes through without conversion")
    func passThroughWhenFormatsMatch() throws {
        guard #available(macOS 26, *) else { return }
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioConstants.sampleRate,
            channels: 1,
            interleaved: false
        ))
        let samples = [Float](repeating: 0.25, count: 480)
        let buffer = try #require(
            AppleTranscriber.makeBuffer(from: samples, targetFormat: format)
        )
        #expect(buffer.frameLength == 480)
        #expect(buffer.format.sampleRate == AudioConstants.sampleRate)
        #expect(buffer.floatChannelData?[0][0] == 0.25)
    }

    @Test("A nil target format still yields the source buffer")
    func nilTargetFormat() throws {
        guard #available(macOS 26, *) else { return }
        let samples = [Float](repeating: 0.1, count: 960)
        let buffer = try #require(
            AppleTranscriber.makeBuffer(from: samples, targetFormat: nil)
        )
        #expect(buffer.frameLength == 960)
    }

    /// The recogniser picks its own preferred rate, which need not be ours.
    @Test("A differing sample rate is resampled")
    func resamplesToTargetRate() throws {
        guard #available(macOS 26, *) else { return }
        let target = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let samples = [Float](repeating: 0.2, count: 1600)  // 100 ms at 16 kHz
        let buffer = try #require(
            AppleTranscriber.makeBuffer(from: samples, targetFormat: target)
        )
        #expect(buffer.format.sampleRate == 48_000)
        // 100 ms at 48 kHz ≈ 4800 frames; allow converter slack.
        #expect(buffer.frameLength > 4000)
    }
}

@Suite("Technical vocabulary")
struct TechnicalVocabularyTests {
    @Test("The default list is non-empty and free of duplicates")
    func listIsSane() {
        let list = TechnicalVocabulary.default
        #expect(!list.isEmpty)
        #expect(Set(list).count == list.count, "duplicates dilute the bias")
        #expect(list.allSatisfy { !$0.isEmpty })
    }

    @Test("Terms that were mis-transcribed are present")
    func coversObservedFailures() {
        let list = Set(TechnicalVocabulary.default)
        // Each of these was mangled in measurement; see TechnicalVocabulary.
        for term in ["git", "OAuth", "hysteresis", "dereference", "Kubernetes"] {
            #expect(list.contains(term), "\(term) should be hinted")
        }
    }
}
