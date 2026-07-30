import Foundation

public struct SpeechSegment: Sendable {
    public let samples: [Float]
    public let startedAt: Date
    public let duration: TimeInterval
    public let peakDb: Float
    /// Whether the gate closed on trailing silence (normal) or hit the cap.
    public let endReason: SpeechEndReason

    public var sampleCount: Int { samples.count }
}

public struct SegmenterConfig: Sendable {
    /// Audio retained ahead of the trigger.
    ///
    /// This is the whole reason the segmenter exists rather than just handing the
    /// gate's output to a recogniser. The gate needs ~90 ms of speech before it
    /// opens, and a wake word's first phoneme is exactly what got it there — so
    /// without preroll the recogniser receives "ey router" instead of "hey
    /// router" and the match fails.
    public var prerollFrames: Int
    public var gate: VoiceGateConfig

    public init(
        prerollFrames: Int = AudioConstants.frames(forMilliseconds: 500),
        gate: VoiceGateConfig = VoiceGateConfig()
    ) {
        self.prerollFrames = prerollFrames
        self.gate = gate
    }
}

/// Turns a stream of frames into discrete utterances, with preroll.
///
/// Kept `final class` + explicit lock rather than an actor: frames arrive from
/// the audio callback thread every 30 ms and must not hop an executor to be
/// gated. The lock is uncontended in practice — one producer, and the consumer
/// only touches the continuation.
public final class SpeechSegmenter: @unchecked Sendable {
    public struct Meter: Sendable {
        public let db: Float
        public let noiseFloorDb: Float
        public let isCapturing: Bool
    }

    private let source: any AudioSource
    private let config: SegmenterConfig
    private let lock = NSLock()

    private var gate: VoiceGate
    /// Circular preroll of recent frames, only meaningful while the gate is shut.
    private var preroll: [[Float]] = []
    private var capturing: [Float] = []
    private var segmentStart: Date?
    private var peakDb: Float = -120
    private var meterHandler: (@Sendable (Meter) -> Void)?

    public init(source: any AudioSource, config: SegmenterConfig = SegmenterConfig()) {
        self.source = source
        self.config = config
        self.gate = VoiceGate(config: config.gate)
        self.preroll.reserveCapacity(config.prerollFrames + 1)
    }

    /// Called for every frame with current levels, for a UI meter. Kept separate
    /// from the segment stream so metering can't backpressure segmentation.
    public func onMeter(_ handler: @escaping @Sendable (Meter) -> Void) {
        lock.lock()
        meterHandler = handler
        lock.unlock()
    }

    public func segments() throws -> AsyncStream<SpeechSegment> {
        let (stream, continuation) = AsyncStream<SpeechSegment>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )

        try source.start(
            onFrame: { [weak self] frame in
                self?.handle(frame: frame, continuation: continuation)
            },
            onEnd: { [weak self] in
                // Flush a segment still open when the source ran out, then close
                // the stream so finite sources terminate their consumer.
                if let trailing = self?.flushOpenSegment() {
                    continuation.yield(trailing)
                }
                continuation.finish()
            }
        )

        continuation.onTermination = { [weak self] _ in
            self?.source.stop()
        }

        return stream
    }

    public func stop() {
        source.stop()
    }

    /// Emits whatever is mid-capture when input ends, so a trailing utterance
    /// isn't silently dropped. Returns nil if nothing was open or it was too
    /// short to be speech.
    private func flushOpenSegment() -> SpeechSegment? {
        lock.lock()
        defer { lock.unlock() }

        guard let started = segmentStart, !capturing.isEmpty else { return nil }
        let frameCount = capturing.count / AudioConstants.frameSampleCount
        defer {
            capturing.removeAll(keepingCapacity: true)
            segmentStart = nil
            peakDb = -120
            gate.reset()
        }
        guard frameCount >= config.gate.minSegmentFrames,
              peakDb >= config.gate.minPeakDb else { return nil }

        return SpeechSegment(
            samples: capturing,
            startedAt: started,
            duration: Double(capturing.count) / AudioConstants.sampleRate,
            peakDb: peakDb,
            endReason: .trailingSilence
        )
    }

    // MARK: - Frame handling

    private func handle(frame: [Float], continuation: AsyncStream<SpeechSegment>.Continuation) {
        lock.lock()

        let decision = gate.process(frame: frame)
        let analysis = gate.lastAnalysis
        let meter = Meter(
            db: analysis?.db ?? -120,
            noiseFloorDb: gate.noiseFloorDb,
            isCapturing: gate.isInSpeech
        )
        let handler = meterHandler

        var finished: SpeechSegment?

        switch decision {
        case .silence:
            // Keep the rolling preroll topped up while we're not capturing.
            preroll.append(frame)
            if preroll.count > config.prerollFrames {
                preroll.removeFirst(preroll.count - config.prerollFrames)
            }

        case .speechStarted:
            segmentStart = Date()
            peakDb = analysis?.db ?? -120
            capturing.removeAll(keepingCapacity: true)
            capturing.reserveCapacity(
                (config.prerollFrames + 64) * AudioConstants.frameSampleCount
            )
            // Seed with everything we held back, then the triggering frame.
            for buffered in preroll { capturing.append(contentsOf: buffered) }
            capturing.append(contentsOf: frame)
            preroll.removeAll(keepingCapacity: true)

        case .speechContinuing:
            capturing.append(contentsOf: frame)
            peakDb = max(peakDb, analysis?.db ?? -120)

        case .speechEnded(let reason):
            capturing.append(contentsOf: frame)
            // Reject anything that never got loud enough to be someone talking.
            let loudEnough = peakDb >= config.gate.minPeakDb
            if reason != .tooShort, loudEnough, let started = segmentStart {
                finished = SpeechSegment(
                    samples: capturing,
                    startedAt: started,
                    duration: Double(capturing.count) / AudioConstants.sampleRate,
                    peakDb: peakDb,
                    endReason: reason
                )
            }
            capturing.removeAll(keepingCapacity: true)
            segmentStart = nil
            peakDb = -120
            // The tail we just closed on is the next utterance's preroll.
            preroll.removeAll(keepingCapacity: true)
            preroll.append(frame)
        }

        lock.unlock()

        handler?(meter)
        if let finished {
            continuation.yield(finished)
        }
    }
}
