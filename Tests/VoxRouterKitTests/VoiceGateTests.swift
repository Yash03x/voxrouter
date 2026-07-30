import Foundation
import Testing
@testable import VoxRouterKit

// MARK: - Synthetic signal generators

private let frameSize = AudioConstants.frameSampleCount

/// Low-amplitude white-ish noise: a quiet room.
private func silenceFrame(amplitude: Float = 0.0005, seed: inout UInt64) -> [Float] {
    (0..<frameSize).map { _ in (nextUnit(&seed) * 2 - 1) * amplitude }
}

/// A voiced-speech stand-in: a low-frequency tone (well inside the voiced ZCR
/// band) with a little noise so it isn't a pathologically pure signal.
private func speechFrame(
    amplitude: Float = 0.2,
    frequency: Float = 200,
    phase: inout Float,
    seed: inout UInt64
) -> [Float] {
    var frame = [Float](repeating: 0, count: frameSize)
    let step = 2 * Float.pi * frequency / Float(AudioConstants.sampleRate)
    for index in 0..<frameSize {
        frame[index] = sin(phase) * amplitude + (nextUnit(&seed) * 2 - 1) * amplitude * 0.05
        phase += step
        if phase > 2 * .pi { phase -= 2 * .pi }
    }
    return frame
}

/// Loud broadband noise — a keyboard clatter. Loud enough to clear the energy
/// gate, but its zero-crossing rate should keep it out.
private func broadbandFrame(amplitude: Float = 0.3, seed: inout UInt64) -> [Float] {
    (0..<frameSize).map { _ in (nextUnit(&seed) * 2 - 1) * amplitude }
}

/// Deterministic PRNG: `Math.random` equivalents make audio tests flaky.
private func nextUnit(_ seed: inout UInt64) -> Float {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Float((seed >> 33) % 1_000_000) / 1_000_000
}

// MARK: - Gate

@Suite("Voice activity gate")
struct VoiceGateTests {
    @Test("A quiet room never opens the gate")
    func silenceStaysClosed() {
        var gate = VoiceGate()
        var seed: UInt64 = 1
        for _ in 0..<200 {
            #expect(gate.process(frame: silenceFrame(seed: &seed)) == .silence)
        }
        #expect(!gate.isInSpeech)
    }

    @Test("The noise floor adapts down in a quiet room")
    func noiseFloorAdapts() {
        var gate = VoiceGate()
        var seed: UInt64 = 2
        let initial = gate.noiseFloorDb
        for _ in 0..<300 { _ = gate.process(frame: silenceFrame(seed: &seed)) }
        #expect(gate.noiseFloorDb < initial, "floor should track down toward the real room level")
        #expect(gate.noiseFloorDb >= gate.config.minNoiseFloorDb)
    }

    @Test("Speech opens the gate, but only after the trigger run")
    func speechOpensAfterTriggerRun() {
        var gate = VoiceGate()
        var seed: UInt64 = 3
        var phase: Float = 0
        for _ in 0..<100 { _ = gate.process(frame: silenceFrame(seed: &seed)) }

        var decisions: [GateDecision] = []
        for _ in 0..<5 {
            decisions.append(gate.process(frame: speechFrame(phase: &phase, seed: &seed)))
        }
        // triggerFrames defaults to 3: two held back, then open.
        #expect(decisions[0] == .silence)
        #expect(decisions[1] == .silence)
        #expect(decisions[2] == .speechStarted)
        #expect(decisions[3] == .speechContinuing)
        #expect(gate.isInSpeech)
    }

    @Test("A single loud click does not open the gate")
    func singleClickRejected() {
        var gate = VoiceGate()
        var seed: UInt64 = 4
        var phase: Float = 0
        for _ in 0..<100 { _ = gate.process(frame: silenceFrame(seed: &seed)) }

        _ = gate.process(frame: speechFrame(amplitude: 0.5, phase: &phase, seed: &seed))
        _ = gate.process(frame: silenceFrame(seed: &seed))
        #expect(!gate.isInSpeech, "one frame is not a trigger run")
    }

    @Test("Keyboard-like broadband noise is rejected on zero-crossing rate")
    func broadbandNoiseRejected() {
        var gate = VoiceGate()
        var seed: UInt64 = 5
        for _ in 0..<100 { _ = gate.process(frame: silenceFrame(seed: &seed)) }

        for _ in 0..<10 { _ = gate.process(frame: broadbandFrame(seed: &seed)) }
        #expect(!gate.isInSpeech, "loud but broadband — should not read as voice")
    }

    @Test("The gate closes after trailing silence, not at the first pause")
    func closesOnTrailingSilence() {
        var gate = VoiceGate()
        var seed: UInt64 = 6
        var phase: Float = 0
        for _ in 0..<100 { _ = gate.process(frame: silenceFrame(seed: &seed)) }
        for _ in 0..<20 { _ = gate.process(frame: speechFrame(phase: &phase, seed: &seed)) }
        #expect(gate.isInSpeech)

        // A short mid-sentence breath must not end the utterance.
        for _ in 0..<5 { _ = gate.process(frame: silenceFrame(seed: &seed)) }
        #expect(gate.isInSpeech, "a brief pause is part of the sentence")

        var ended: SpeechEndReason?
        for _ in 0..<gate.config.releaseFrames + 5 {
            if case .speechEnded(let reason) = gate.process(frame: silenceFrame(seed: &seed)) {
                ended = reason
                break
            }
        }
        #expect(ended == .trailingSilence)
        #expect(!gate.isInSpeech)
    }

    @Test("Hysteresis keeps one utterance from splitting into several")
    func hysteresisPreventsChopping() {
        // Amplitude chosen to sit just above the continue margin but flirt with
        // the start margin — the case that chops without hysteresis.
        var gate = VoiceGate()
        var seed: UInt64 = 7
        var phase: Float = 0
        for _ in 0..<150 { _ = gate.process(frame: silenceFrame(seed: &seed)) }
        for _ in 0..<5 { _ = gate.process(frame: speechFrame(amplitude: 0.2, phase: &phase, seed: &seed)) }

        var restarts = 0
        for index in 0..<60 {
            // Alternate loud and marginal frames.
            let amplitude: Float = index.isMultiple(of: 2) ? 0.2 : 0.02
            if gate.process(frame: speechFrame(amplitude: amplitude, phase: &phase, seed: &seed))
                == .speechStarted {
                restarts += 1
            }
        }
        #expect(restarts == 0, "a wavering level must stay one segment")
        #expect(gate.isInSpeech)
    }

    @Test("A runaway segment is capped rather than buffered forever")
    func maxDurationCap() {
        var config = VoiceGateConfig()
        config.maxSegmentFrames = 20
        var gate = VoiceGate(config: config)
        var seed: UInt64 = 8
        var phase: Float = 0
        // Let warmup measure a real floor first, as it would in a quiet room.
        for _ in 0..<config.warmupFrames + 10 {
            _ = gate.process(frame: silenceFrame(seed: &seed))
        }

        var ended: SpeechEndReason?
        for _ in 0..<60 {
            if case .speechEnded(let reason) = gate.process(
                frame: speechFrame(phase: &phase, seed: &seed)
            ) {
                ended = reason
                break
            }
        }
        #expect(ended == .maxDuration)
    }

    @Test("A brief burst that opens the gate is discarded as too short")
    func tooShortIsRejected() {
        var config = VoiceGateConfig()
        config.minSegmentFrames = 15
        config.releaseFrames = 4
        var gate = VoiceGate(config: config)
        var seed: UInt64 = 9
        var phase: Float = 0
        for _ in 0..<100 { _ = gate.process(frame: silenceFrame(seed: &seed)) }

        // Just enough to trigger, then stop.
        for _ in 0..<config.triggerFrames {
            _ = gate.process(frame: speechFrame(phase: &phase, seed: &seed))
        }
        var ended: SpeechEndReason?
        for _ in 0..<20 {
            if case .speechEnded(let reason) = gate.process(frame: silenceFrame(seed: &seed)) {
                ended = reason
                break
            }
        }
        #expect(ended == .tooShort)
    }

    @Test("The noise floor does not drift up during speech")
    func floorDoesNotChaseSpeech() {
        var gate = VoiceGate()
        var seed: UInt64 = 10
        var phase: Float = 0
        for _ in 0..<200 { _ = gate.process(frame: silenceFrame(seed: &seed)) }
        let floorBefore = gate.noiseFloorDb

        for _ in 0..<100 { _ = gate.process(frame: speechFrame(phase: &phase, seed: &seed)) }

        // The few frames before the gate opened are legitimately sampled, so a
        // small shift is expected. What must not happen is the floor climbing
        // toward the speaker's own level (~-17 dBFS here), which would latch the
        // gate shut mid-sentence.
        #expect(
            abs(gate.noiseFloorDb - floorBefore) < 3,
            "floor moved \(gate.noiseFloorDb - floorBefore) dB — should barely budge"
        )
        #expect(gate.noiseFloorDb < -50, "floor must stay far below the speech level")
    }

    @Test("Zero-crossing rate separates a tone from broadband noise")
    func zeroCrossingRateDiscriminates() {
        var seed: UInt64 = 11
        var phase: Float = 0
        let tone = VoiceGate.zeroCrossingRate(speechFrame(phase: &phase, seed: &seed))
        let noise = VoiceGate.zeroCrossingRate(broadbandFrame(seed: &seed))
        #expect(tone < 0.1)
        #expect(noise > 0.3)
    }

    @Test("An empty frame is handled without dividing by zero")
    func emptyFrameIsSafe() {
        var gate = VoiceGate()
        #expect(gate.process(frame: []) == .silence)
        #expect(VoiceGate.zeroCrossingRate([]) == 0)
        #expect(VoiceGate.zeroCrossingRate([1]) == 0)
    }

    @Test("reset() returns the gate to a closed state")
    func resetClosesGate() {
        var gate = VoiceGate()
        var seed: UInt64 = 12
        var phase: Float = 0
        for _ in 0..<100 { _ = gate.process(frame: silenceFrame(seed: &seed)) }
        for _ in 0..<20 { _ = gate.process(frame: speechFrame(phase: &phase, seed: &seed)) }
        #expect(gate.isInSpeech)
        gate.reset()
        #expect(!gate.isInSpeech)
    }

    /// Regression for the failure that showed up only on live audio: the floor
    /// estimator used to latch, so a gate that opened spuriously could never
    /// recalibrate and stayed open forever.
    @Test("The gate cannot latch open permanently")
    func gateCannotLatchOpen() {
        var config = VoiceGateConfig()
        config.maxSegmentFrames = 30
        var gate = VoiceGate(config: config)
        var seed: UInt64 = 13

        // Continuous moderately loud room noise — the condition that latched.
        var opens = 0
        var closes = 0
        for _ in 0..<400 {
            switch gate.process(frame: broadbandFrame(amplitude: 0.05, seed: &seed)) {
            case .speechStarted: opens += 1
            case .speechEnded: closes += 1
            default: break
            }
        }
        // Either it never opened, or every opening eventually closed.
        #expect(closes >= opens - 1, "an opened gate must always come back down")
        #expect(!gate.isInSpeech || closes > 0)
    }

    /// If the process starts mid-sentence the whole window is speech, so the
    /// percentile estimate lands on the speaker. The clamp is what keeps the
    /// gate usable anyway.
    @Test("Starting up during speech does not make the gate deaf")
    func startupDuringSpeechStillDetects() {
        var gate = VoiceGate()
        var seed: UInt64 = 14
        var phase: Float = 0

        var opened = false
        for _ in 0..<120 {
            if gate.process(frame: speechFrame(phase: &phase, seed: &seed)) == .speechStarted {
                opened = true
                break
            }
        }
        #expect(opened, "the noise-floor clamp should keep speech detectable")
        #expect(gate.noiseFloorDb <= gate.config.maxNoiseFloorDb)
    }
}

// MARK: - Segmenter

/// Replays a scripted frame list, so the full segmenter path is testable with no
/// microphone and no TCC consent.
private final class ScriptedSource: AudioSource, @unchecked Sendable {
    private let frames: [[Float]]
    private var stopped = false

    init(frames: [[Float]]) { self.frames = frames }

    func start(
        onFrame: @escaping @Sendable ([Float]) -> Void,
        onEnd: @escaping @Sendable () -> Void
    ) throws {
        for frame in frames {
            if stopped { return }
            onFrame(frame)
        }
        onEnd()
    }

    func stop() { stopped = true }
}

@Suite("Speech segmenter")
struct SpeechSegmenterTests {
    /// The headline property: the audio handed to a recogniser must include what
    /// was said *before* the gate opened, or the wake word's first phoneme is
    /// missing and the match fails.
    @Test("A segment includes preroll captured before the trigger")
    func segmentIncludesPreroll() async throws {
        var seed: UInt64 = 20
        var phase: Float = 0

        var frames: [[Float]] = []
        for _ in 0..<150 { frames.append(silenceFrame(seed: &seed)) }
        let speechFrames = 40
        for _ in 0..<speechFrames {
            frames.append(speechFrame(phase: &phase, seed: &seed))
        }
        for _ in 0..<60 { frames.append(silenceFrame(seed: &seed)) }

        var config = SegmenterConfig()
        config.prerollFrames = 10
        let segmenter = SpeechSegmenter(source: ScriptedSource(frames: frames), config: config)

        var captured: [SpeechSegment] = []
        for await segment in try segmenter.segments() { captured.append(segment) }

        #expect(captured.count == 1)
        let segment = try #require(captured.first)

        // Without preroll the segment could only contain the voiced frames that
        // followed the trigger. It must be materially longer than that.
        let voicedOnly = Double(speechFrames) * AudioConstants.frameDuration
        #expect(
            segment.duration > voicedOnly,
            "segment (\(segment.duration)s) should exceed the voiced part alone (\(voicedOnly)s)"
        )
        #expect(segment.sampleCount % frameSize == 0)
        #expect(segment.endReason == .trailingSilence)
        #expect(segment.peakDb > -30)
    }

    @Test("Two utterances separated by a real pause become two segments")
    func twoUtterancesTwoSegments() async throws {
        var seed: UInt64 = 21
        var phase: Float = 0
        let gapFrames = VoiceGateConfig().releaseFrames + 20

        var frames: [[Float]] = []
        for _ in 0..<150 { frames.append(silenceFrame(seed: &seed)) }
        for _ in 0..<30 { frames.append(speechFrame(phase: &phase, seed: &seed)) }
        for _ in 0..<gapFrames { frames.append(silenceFrame(seed: &seed)) }
        for _ in 0..<30 { frames.append(speechFrame(phase: &phase, seed: &seed)) }
        for _ in 0..<gapFrames { frames.append(silenceFrame(seed: &seed)) }

        let segmenter = SpeechSegmenter(source: ScriptedSource(frames: frames))
        var captured: [SpeechSegment] = []
        for await segment in try segmenter.segments() { captured.append(segment) }

        #expect(captured.count == 2)
    }

    /// Regression for the live finding: in a quiet room the adaptive floor drops
    /// low enough that faint rustles clear `floor + startMargin`. Six such false
    /// positives appeared in 40 s of real silence, all peaking under -38 dBFS.
    @Test("A faint noise that clears the relative threshold is still rejected on peak")
    func faintNoiseRejectedOnPeak() async throws {
        var seed: UInt64 = 24
        var phase: Float = 0

        var frames: [[Float]] = []
        for _ in 0..<200 { frames.append(silenceFrame(seed: &seed)) }
        // ~-46 dBFS: well above a very low floor, far below real speech.
        for _ in 0..<30 {
            frames.append(speechFrame(amplitude: 0.007, phase: &phase, seed: &seed))
        }
        for _ in 0..<80 { frames.append(silenceFrame(seed: &seed)) }

        let segmenter = SpeechSegmenter(source: ScriptedSource(frames: frames))
        var captured: [SpeechSegment] = []
        for await segment in try segmenter.segments() { captured.append(segment) }

        #expect(captured.isEmpty, "a -46 dBFS rustle is not someone talking")
    }

    @Test("Speech at a normal level still passes the peak requirement")
    func normalSpeechPassesPeakCheck() async throws {
        var seed: UInt64 = 25
        var phase: Float = 0

        var frames: [[Float]] = []
        for _ in 0..<200 { frames.append(silenceFrame(seed: &seed)) }
        // ~-24 dBFS: a quiet-but-normal speaking level.
        for _ in 0..<40 {
            frames.append(speechFrame(amplitude: 0.09, phase: &phase, seed: &seed))
        }
        for _ in 0..<80 { frames.append(silenceFrame(seed: &seed)) }

        let segmenter = SpeechSegmenter(source: ScriptedSource(frames: frames))
        var captured: [SpeechSegment] = []
        for await segment in try segmenter.segments() { captured.append(segment) }

        #expect(captured.count == 1, "quiet speech must not be filtered out")
    }

    @Test("A silent room produces no segments at all")
    func silenceProducesNothing() async throws {
        var seed: UInt64 = 22
        let frames = (0..<400).map { _ in silenceFrame(seed: &seed) }
        let segmenter = SpeechSegmenter(source: ScriptedSource(frames: frames))

        var captured: [SpeechSegment] = []
        for await segment in try segmenter.segments() { captured.append(segment) }
        #expect(captured.isEmpty)
    }

    @Test("Metering reports levels for every frame without gating them")
    func meterReportsLevels() async throws {
        var seed: UInt64 = 23
        var phase: Float = 0
        var frames: [[Float]] = []
        for _ in 0..<120 { frames.append(silenceFrame(seed: &seed)) }
        for _ in 0..<30 { frames.append(speechFrame(phase: &phase, seed: &seed)) }
        for _ in 0..<60 { frames.append(silenceFrame(seed: &seed)) }

        let counter = MeterCounter()
        let segmenter = SpeechSegmenter(source: ScriptedSource(frames: frames))
        segmenter.onMeter { counter.record($0) }

        for await _ in try segmenter.segments() {}

        #expect(counter.count == frames.count, "every frame should meter")
        #expect(counter.sawCapturing, "meter should reflect the capturing state")
    }

    @Test("Frame re-chunking emits only exact-sized frames")
    func accumulatorEmitsExactFrames() {
        let accumulator = FrameAccumulator(frameSize: 480)
        let sizes = Sizes()

        // 1024-sample buffers, as a 48 kHz tap would deliver.
        for _ in 0..<10 {
            let chunk = [Float](repeating: 0.1, count: 1024)
            chunk.withUnsafeBufferPointer { pointer in
                accumulator.append(pointer) { sizes.record($0.count) }
            }
        }
        #expect(!sizes.recorded.isEmpty)
        #expect(sizes.recorded.allSatisfy { $0 == 480 })
        // 10240 samples in → 21 whole frames, remainder held back.
        #expect(sizes.recorded.count == 21)
    }
}

// MARK: - Helpers

private final class MeterCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var capturing = false

    func record(_ meter: SpeechSegmenter.Meter) {
        lock.lock()
        frames += 1
        if meter.isCapturing { capturing = true }
        lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return frames }
    var sawCapturing: Bool { lock.lock(); defer { lock.unlock() }; return capturing }
}

private final class Sizes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    func record(_ size: Int) { lock.lock(); storage.append(size); lock.unlock() }
    var recorded: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
}
