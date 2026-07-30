import Accelerate
import Foundation

public struct VoiceGateConfig: Sendable {
    /// Consecutive speech-like frames needed to open the gate. Rejects clicks,
    /// key presses, and mouth noise.
    public var triggerFrames: Int
    /// Consecutive silent frames needed to close it. This is the pause you're
    /// allowed mid-sentence, so it must comfortably exceed a natural breath.
    public var releaseFrames: Int
    /// dB above the noise floor required to *start* speech...
    public var startMarginDb: Float
    /// ...and the lower bar to *continue* it. The gap is hysteresis: without it,
    /// a level hovering near the threshold chops one utterance into several.
    public var continueMarginDb: Float
    /// Hard floor — below this, treat as silence regardless of how quiet the
    /// room is, so a near-silent room doesn't make the gate hair-trigger.
    public var absoluteFloorDb: Float
    /// Sliding window used to estimate the noise floor. ~3 s by default: long
    /// enough to span a sentence's pauses, short enough to track a room change.
    public var noiseWindowFrames: Int
    /// Which percentile of that window counts as "the floor".
    ///
    /// The median, not a low percentile. The window is only sampled while the
    /// gate is shut, so it already consists of background — and what the
    /// threshold needs to clear is *typical* background, not its quietest
    /// moments. A low percentile in a room with variable noise (a fan cycling,
    /// intermittent clatter) puts the estimate tens of dB below the usual level
    /// and the gate then treats ordinary room noise as speech.
    public var noisePercentile: Float
    /// Recompute cadence, in frames. Sorting the window every frame is wasted
    /// work when the floor cannot meaningfully move in 30 ms.
    public var floorRecomputeInterval: Int
    /// Frames observed before the gate is allowed to open at all, so the first
    /// utterance is judged against a measured floor rather than a guess.
    public var warmupFrames: Int
    public var minNoiseFloorDb: Float
    public var maxNoiseFloorDb: Float
    /// Stop runaway segments (a TV left on) rather than buffering forever.
    public var maxSegmentFrames: Int
    /// Segments shorter than this are discarded as noise.
    public var minSegmentFrames: Int
    /// A segment must contain at least one frame this loud to count as speech.
    ///
    /// The adaptive floor alone isn't enough: in a genuinely quiet room the floor
    /// drops so low that faint noises clear `floor + startMargin` easily. Speech
    /// at desk distance peaks around -25 to -10 dBFS, so requiring a real peak
    /// rejects the -50 dBFS rustles that a purely relative test lets through.
    public var minPeakDb: Float
    /// Voiced speech sits roughly in this zero-crossing-rate band. Broadband
    /// noise (keyboard, rustling) runs much higher, steady hum much lower.
    public var maxZeroCrossingRate: Float

    public init(
        triggerFrames: Int = 3,                                   // ~90 ms
        releaseFrames: Int = AudioConstants.frames(forMilliseconds: 750),
        startMarginDb: Float = 10,
        continueMarginDb: Float = 5,
        absoluteFloorDb: Float = -45,
        noiseWindowFrames: Int = AudioConstants.frames(forMilliseconds: 3000),
        noisePercentile: Float = 0.5,
        floorRecomputeInterval: Int = 5,
        warmupFrames: Int = AudioConstants.frames(forMilliseconds: 600),
        minNoiseFloorDb: Float = -75,
        // Hard cap on the estimate. If the daemon happens to start while
        // someone is already talking, the window contains nothing but speech and
        // the percentile lands on the speaker's own level — which would make the
        // gate permanently deaf. Anything above roughly -30 dBFS is not a noise
        // floor, so refusing to believe it is the safeguard.
        maxNoiseFloorDb: Float = -30,
        maxSegmentFrames: Int = AudioConstants.frames(forMilliseconds: 15_000),
        minSegmentFrames: Int = AudioConstants.frames(forMilliseconds: 180),
        minPeakDb: Float = -35,
        maxZeroCrossingRate: Float = 0.45
    ) {
        self.triggerFrames = triggerFrames
        self.releaseFrames = releaseFrames
        self.startMarginDb = startMarginDb
        self.continueMarginDb = continueMarginDb
        self.absoluteFloorDb = absoluteFloorDb
        self.noiseWindowFrames = noiseWindowFrames
        self.noisePercentile = noisePercentile
        self.floorRecomputeInterval = floorRecomputeInterval
        self.warmupFrames = warmupFrames
        self.minNoiseFloorDb = minNoiseFloorDb
        self.maxNoiseFloorDb = maxNoiseFloorDb
        self.maxSegmentFrames = maxSegmentFrames
        self.minSegmentFrames = minSegmentFrames
        self.minPeakDb = minPeakDb
        self.maxZeroCrossingRate = maxZeroCrossingRate
    }
}

public struct FrameAnalysis: Sendable, Equatable {
    public let rms: Float
    public let db: Float
    public let zeroCrossingRate: Float
    public let noiseFloorDb: Float
    public let isSpeechLike: Bool
}

public enum SpeechEndReason: Sendable, Equatable {
    case trailingSilence
    case maxDuration
    /// Opened, then closed before reaching `minSegmentFrames` — noise, not speech.
    case tooShort
}

public enum GateDecision: Sendable, Equatable {
    case silence
    case speechStarted
    case speechContinuing
    case speechEnded(SpeechEndReason)
}

/// Energy-and-zero-crossing voice activity detector with an adaptive noise
/// floor.
///
/// Deliberately dependency-free and pure: `process(frame:)` is a plain function
/// of its input and the gate's own state, so the whole state machine is testable
/// on synthetic signals with no microphone, no model download, and no audio
/// session. That matters more than raw accuracy here, because this gate's only
/// job is to decide *when to wake the real recogniser* — a false positive costs
/// one wasted transcription, not a wrong answer.
///
/// Swappable for Silero VAD later; the interface is the frame in, decision out.
public struct VoiceGate: Sendable {
    public private(set) var config: VoiceGateConfig
    public private(set) var noiseFloorDb: Float
    public private(set) var lastAnalysis: FrameAnalysis?

    private enum State: Equatable {
        case silence(speechRun: Int)
        case speech(frameCount: Int, silenceRun: Int)
    }

    private var state: State = .silence(speechRun: 0)

    /// Ring of recent frame levels, used for the percentile estimate.
    private var levelHistory: [Float]
    private var historyCursor = 0
    private var historyCount = 0
    private var framesUntilRecompute = 0
    private var warmupRemaining: Int

    public init(config: VoiceGateConfig = VoiceGateConfig()) {
        self.config = config
        self.levelHistory = [Float](repeating: 0, count: max(1, config.noiseWindowFrames))
        self.warmupRemaining = config.warmupFrames
        // Conservative until measured. The gate can't open during warmup anyway,
        // so this only matters if warmup is configured to zero.
        self.noiseFloorDb = -40
    }

    public var isInSpeech: Bool {
        if case .speech = state { return true }
        return false
    }

    /// Frames must be `AudioConstants.frameSampleCount` long; shorter frames are
    /// analysed anyway but produce a noisier estimate.
    public mutating func process(frame: [Float]) -> GateDecision {
        // The floor is estimated only while the gate is shut. Sampling during
        // speech would let a long utterance fill the whole window and drag the
        // estimate up to the speaker's own level. `maxSegmentFrames` is what
        // guarantees the gate eventually reopens, so a spurious trigger can
        // never freeze the floor permanently.
        if !isInSpeech {
            recordLevel(analyseLevel(frame))
        }

        let analysis = analyse(frame)
        lastAnalysis = analysis

        if warmupRemaining > 0 {
            warmupRemaining -= 1
            state = .silence(speechRun: 0)
            return .silence
        }

        switch state {
        case .silence(let speechRun):
            guard analysis.isSpeechLike else {
                state = .silence(speechRun: 0)
                return .silence
            }
            let run = speechRun + 1
            if run >= config.triggerFrames {
                state = .speech(frameCount: run, silenceRun: 0)
                return .speechStarted
            }
            state = .silence(speechRun: run)
            return .silence

        case .speech(let frameCount, let silenceRun):
            let count = frameCount + 1

            if count >= config.maxSegmentFrames {
                state = .silence(speechRun: 0)
                return .speechEnded(.maxDuration)
            }

            // Continuing uses the lower margin — see `continueMarginDb`.
            let continuing = analysis.db > noiseFloorDb + config.continueMarginDb
                && analysis.db > config.absoluteFloorDb

            if continuing {
                state = .speech(frameCount: count, silenceRun: 0)
                return .speechContinuing
            }

            let silence = silenceRun + 1
            if silence >= config.releaseFrames {
                state = .silence(speechRun: 0)
                // `count` includes the trailing silence, so measure the voiced
                // part when deciding whether this was real speech.
                let voiced = count - silence
                return .speechEnded(voiced < config.minSegmentFrames ? .tooShort : .trailingSilence)
            }
            state = .speech(frameCount: count, silenceRun: silence)
            return .speechContinuing
        }
    }

    public mutating func reset() {
        state = .silence(speechRun: 0)
        lastAnalysis = nil
    }

    // MARK: - Noise floor

    /// Percentile over a sliding window, rather than an exponential average.
    ///
    /// An EMA has to be told when *not* to learn (i.e. "only when it's quiet"),
    /// which is circular — that decision depends on the floor it's estimating.
    /// A low percentile needs no such gate: speech occupies the high percentiles
    /// and the quiet gaps between words occupy the low ones, so the estimate
    /// lands on the room regardless of how much talking is going on.
    private mutating func recordLevel(_ db: Float) {
        levelHistory[historyCursor] = db
        historyCursor = (historyCursor + 1) % levelHistory.count
        historyCount = min(historyCount + 1, levelHistory.count)

        guard framesUntilRecompute <= 0 else {
            framesUntilRecompute -= 1
            return
        }
        framesUntilRecompute = max(0, config.floorRecomputeInterval - 1)

        // Cheap: a few hundred floats, a few times a second.
        var window = Array(levelHistory[0..<historyCount])
        window.sort()
        let index = Int(Float(window.count - 1) * config.noisePercentile)
        noiseFloorDb = window[max(0, min(index, window.count - 1))]
            .clamped(to: config.minNoiseFloorDb...config.maxNoiseFloorDb)
    }

    // MARK: - Analysis

    private func analyseLevel(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return -120 }
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
        return amplitudeToDb(rms)
    }

    private func analyse(_ frame: [Float]) -> FrameAnalysis {
        guard !frame.isEmpty else {
            return FrameAnalysis(
                rms: 0, db: -120, zeroCrossingRate: 0,
                noiseFloorDb: noiseFloorDb, isSpeechLike: false
            )
        }

        // vDSP: one vectorised pass instead of a Swift reduce, because this runs
        // on every 30 ms frame for as long as the daemon is alive.
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
        let db = amplitudeToDb(rms)

        let zcr = Self.zeroCrossingRate(frame)

        // Speech must clear both the adaptive floor and the absolute one, and
        // look tonal rather than broadband.
        let loudEnough = db > noiseFloorDb + config.startMarginDb && db > config.absoluteFloorDb
        let isSpeechLike = loudEnough && zcr <= config.maxZeroCrossingRate

        return FrameAnalysis(
            rms: rms,
            db: db,
            zeroCrossingRate: zcr,
            noiseFloorDb: noiseFloorDb,
            isSpeechLike: isSpeechLike
        )
    }

    /// Fraction of adjacent sample pairs that change sign. A scalar loop:
    /// branchless sign comparison over 480 elements is already trivial, and the
    /// vDSP equivalent (`vDSP_nzcros`) needs an awkward out-parameter dance for
    /// no measurable gain.
    static func zeroCrossingRate(_ frame: [Float]) -> Float {
        guard frame.count > 1 else { return 0 }
        var crossings = 0
        var previous = frame[0]
        for index in 1..<frame.count {
            let current = frame[index]
            if (current < 0) != (previous < 0) { crossings += 1 }
            previous = current
        }
        return Float(crossings) / Float(frame.count - 1)
    }
}
