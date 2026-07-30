import Foundation
import Testing
@testable import VoxRouterKit

/// A source the test drives by hand, so press/release can be interleaved with
/// specific frames.
private final class ManualSource: AudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var onFrame: (@Sendable ([Float]) -> Void)?
    private(set) var stopped = false

    func start(
        onFrame: @escaping @Sendable ([Float]) -> Void,
        onEnd: @escaping @Sendable () -> Void
    ) throws {
        lock.lock(); self.onFrame = onFrame; lock.unlock()
    }

    func stop() {
        lock.lock(); stopped = true; onFrame = nil; lock.unlock()
    }

    /// Pushes `count` frames whose samples all equal `value`, so the test can
    /// later tell which frames ended up in a clip.
    func push(count: Int, value: Float) {
        lock.lock(); let handler = onFrame; lock.unlock()
        guard let handler else { return }
        let frame = [Float](repeating: value, count: AudioConstants.frameSampleCount)
        for _ in 0..<count { handler(frame) }
    }
}

private final class ClipBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PushToTalkClip] = []
    private var states: [PushToTalkRecorder.State] = []

    func record(_ clip: PushToTalkClip) { lock.lock(); storage.append(clip); lock.unlock() }
    func record(_ state: PushToTalkRecorder.State) { lock.lock(); states.append(state); lock.unlock() }

    var clips: [PushToTalkClip] { lock.lock(); defer { lock.unlock() }; return storage }
    var stateChanges: [PushToTalkRecorder.State] {
        lock.lock(); defer { lock.unlock() }; return states
    }
}

private func makeRecorder(
    _ config: PushToTalkConfig = PushToTalkConfig()
) throws -> (PushToTalkRecorder, ManualSource, ClipBox) {
    let source = ManualSource()
    let recorder = PushToTalkRecorder(source: source, config: config)
    let box = ClipBox()
    recorder.onClip { box.record($0) }
    recorder.onStateChange { box.record($0) }
    try recorder.warmUp()
    return (recorder, source, box)
}

@Suite("Push-to-talk recorder")
struct PushToTalkTests {
    /// The point of keeping the engine warm: audio from just *before* the key
    /// registered has to be in the clip, because people start talking as they
    /// press and there's latency in the keyboard and audio buffer besides.
    @Test("A clip includes audio captured before the key was pressed")
    func includesPreroll() throws {
        var config = PushToTalkConfig()
        config.prerollFrames = 10
        config.minFrames = 1
        let (recorder, source, box) = try makeRecorder(config)

        // Pre-press audio, marked 0.5 so it's identifiable.
        source.push(count: 10, value: 0.5)
        recorder.beginRecording()
        source.push(count: 20, value: 0.25)
        recorder.endRecording()

        let clip = try #require(box.clips.first)
        // 10 preroll + 20 recorded frames.
        #expect(clip.samples.count == 30 * AudioConstants.frameSampleCount)
        #expect(clip.samples.first == 0.5, "clip must begin with pre-press audio")
    }

    @Test("Preroll is bounded to the configured window")
    func prerollIsBounded() throws {
        var config = PushToTalkConfig()
        config.prerollFrames = 5
        config.minFrames = 1
        let (recorder, source, box) = try makeRecorder(config)

        // Far more pre-press audio than the window.
        source.push(count: 200, value: 0.5)
        recorder.beginRecording()
        source.push(count: 10, value: 0.25)
        recorder.endRecording()

        let clip = try #require(box.clips.first)
        #expect(clip.samples.count == 15 * AudioConstants.frameSampleCount)
    }

    @Test("Nothing is captured while idle")
    func idleCapturesNothing() throws {
        let (_, source, box) = try makeRecorder()
        source.push(count: 100, value: 0.4)
        #expect(box.clips.isEmpty)
    }

    @Test("An accidental tap is discarded")
    func shortTapDiscarded() throws {
        var config = PushToTalkConfig()
        config.minFrames = 20
        config.prerollFrames = 0
        let (recorder, source, box) = try makeRecorder(config)

        recorder.beginRecording()
        source.push(count: 3, value: 0.3)
        recorder.endRecording()

        #expect(box.clips.isEmpty, "a 90 ms tap is not a command")
    }

    /// A stuck or forgotten key must not buffer without bound.
    @Test("A held key is capped and the clip is marked truncated")
    func heldKeyIsCapped() throws {
        var config = PushToTalkConfig()
        config.maxFrames = 20
        config.minFrames = 1
        config.prerollFrames = 0
        let (recorder, source, box) = try makeRecorder(config)

        recorder.beginRecording()
        source.push(count: 100, value: 0.3)

        let clip = try #require(box.clips.first)
        #expect(clip.truncated)
        #expect(clip.samples.count == 20 * AudioConstants.frameSampleCount)
        #expect(recorder.currentState == .idle, "the cap should return us to idle")
    }

    @Test("Frames after the cap are not appended to a new clip")
    func noRunawayAfterCap() throws {
        var config = PushToTalkConfig()
        config.maxFrames = 10
        config.minFrames = 1
        config.prerollFrames = 0
        let (recorder, source, box) = try makeRecorder(config)

        recorder.beginRecording()
        source.push(count: 500, value: 0.3)
        #expect(box.clips.count == 1, "the cap must fire once, not repeatedly")
    }

    @Test("Two presses produce two clips")
    func twoPresses() throws {
        var config = PushToTalkConfig()
        config.minFrames = 1
        config.prerollFrames = 0
        let (recorder, source, box) = try makeRecorder(config)

        recorder.beginRecording()
        source.push(count: 10, value: 0.2)
        recorder.endRecording()

        recorder.beginRecording()
        source.push(count: 15, value: 0.3)
        recorder.endRecording()

        #expect(box.clips.count == 2)
        #expect(box.clips[0].samples.count == 10 * AudioConstants.frameSampleCount)
        #expect(box.clips[1].samples.count == 15 * AudioConstants.frameSampleCount)
    }

    /// Key events can repeat or arrive out of order; the state machine must not
    /// double-start or emit a clip for a release it never started.
    @Test("Repeated press and release events are idempotent")
    func repeatedEventsAreIdempotent() throws {
        var config = PushToTalkConfig()
        config.minFrames = 1
        config.prerollFrames = 0
        let (recorder, source, box) = try makeRecorder(config)

        recorder.endRecording()  // release with no press
        #expect(box.clips.isEmpty)

        recorder.beginRecording()
        recorder.beginRecording()  // duplicate press
        source.push(count: 10, value: 0.2)
        recorder.endRecording()
        recorder.endRecording()  // duplicate release

        #expect(box.clips.count == 1)
        #expect(box.clips[0].samples.count == 10 * AudioConstants.frameSampleCount)
    }

    @Test("State transitions are reported for UI feedback")
    func reportsStateChanges() throws {
        var config = PushToTalkConfig()
        config.minFrames = 1
        config.prerollFrames = 0
        let (recorder, source, box) = try makeRecorder(config)

        recorder.beginRecording()
        source.push(count: 5, value: 0.2)
        recorder.endRecording()

        #expect(box.stateChanges == [.recording, .idle])
    }

    @Test("Peak level is measured across the whole clip")
    func measuresPeak() throws {
        var config = PushToTalkConfig()
        config.minFrames = 1
        config.prerollFrames = 0
        let (recorder, source, box) = try makeRecorder(config)

        recorder.beginRecording()
        source.push(count: 5, value: 0.01)
        source.push(count: 1, value: 0.5)   // -6 dBFS
        source.push(count: 5, value: 0.01)
        recorder.endRecording()

        let clip = try #require(box.clips.first)
        #expect(abs(clip.peakDb - (-6.02)) < 0.5, "peak was \(clip.peakDb)")
    }

    /// Push-to-talk must not consult the VAD: the user has said "record now",
    /// and a voice-activity detector can only override that decision wrongly.
    @Test("Very quiet audio is still captured when the key is held")
    func quietAudioIsNotGated() throws {
        var config = PushToTalkConfig()
        config.minFrames = 1
        config.prerollFrames = 0
        let (recorder, source, box) = try makeRecorder(config)

        recorder.beginRecording()
        // ~-80 dBFS — the VAD would reject this outright.
        source.push(count: 20, value: 0.0001)
        recorder.endRecording()

        #expect(box.clips.count == 1, "an explicit key press outranks the VAD")
    }

    @Test("shutDown stops the source and clears state")
    func shutDownIsClean() throws {
        let (recorder, source, _) = try makeRecorder()
        recorder.beginRecording()
        recorder.shutDown()
        #expect(source.stopped)
        #expect(recorder.currentState == .idle)
    }

    @Test("warmUp is idempotent")
    func warmUpIdempotent() throws {
        let (recorder, _, _) = try makeRecorder()
        try recorder.warmUp()
        try recorder.warmUp()
        #expect(recorder.currentState == .idle)
    }
}

@Suite("Hotkey configuration")
struct HotkeyTests {
    @Test("The default chord is ⌃⌥Space")
    func defaultCombo() {
        let combo = HotkeyCombo.controlOptionSpace
        #expect(combo.label == "⌃⌥Space")
        #expect(combo.keyCode == 49, "kVK_Space")
        // controlKey (0x1000) | optionKey (0x0800)
        #expect(combo.carbonModifiers == 0x1800)
    }

    @Test("Registering the same chord twice reports it as taken")
    func doubleRegistrationIsReported() throws {
        let first = HotkeyMonitor()
        let second = HotkeyMonitor()
        defer { first.unregister(); second.unregister() }

        // Something obscure, to avoid colliding with the user's real bindings.
        let combo = HotkeyCombo(
            keyCode: 50,  // kVK_ANSI_Grave
            carbonModifiers: 0x1800 | 0x0200,  // ⌃⌥⇧
            label: "⌃⌥⇧`"
        )

        do {
            try first.start(combo: combo) { _ in }
        } catch {
            // Headless CI may refuse registration entirely; nothing to assert.
            return
        }

        do {
            try second.start(combo: combo) { _ in }
            Issue.record("the second registration should have been refused")
        } catch HotkeyError.alreadyRegistered {
            // Expected.
        } catch {
            // Some macOS versions return a different status; the contract that
            // matters is that it throws rather than silently shadowing.
        }
    }
}
