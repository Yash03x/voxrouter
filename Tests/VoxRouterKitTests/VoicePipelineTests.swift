import Foundation
import Testing
@testable import VoxRouterKit

/// Records what it was asked to say, so muting can be asserted rather than
/// assumed.
private final class RecordingSpeaker: Speaker, @unchecked Sendable {
    let identifier = "recording"
    private let lock = NSLock()
    private var storage: [String] = []
    private(set) var stopCount = 0

    var spoken: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    // NSLock's lock()/unlock() are unavailable in async contexts; withLock is
    // the scoped, async-safe equivalent.
    func speak(_ text: String) async {
        lock.withLock { storage.append(text) }
    }

    func stop() {
        lock.lock(); stopCount += 1; lock.unlock()
    }

    var isSpeaking: Bool { false }
}

private struct FixedTranscriber: Transcriber {
    let identifier = "fixed"
    let text: String
    func transcribe(samples: [Float]) async throws -> Transcript {
        Transcript(text: text, engine: identifier)
    }
}

private func clip() -> PushToTalkClip {
    PushToTalkClip(samples: [0.1, 0.2], duration: 0.1, peakDb: -20, truncated: false)
}

private func configWithProjects() -> Config {
    var config = Config.default
    config.projects = [
        Project(id: "alpha", name: "alpha", path: NSTemporaryDirectory() + "alpha"),
        Project(id: "beta", name: "beta", path: NSTemporaryDirectory() + "beta"),
    ]
    config.activeProjectID = "alpha"
    // Off in tests: with the tier on, handle() reads the *real* per-user
    // conversation store to classify the utterance, and tests must never
    // touch real state. Suites that need the tier on swap in a scratch store
    // via `useConversationStore` first; everything else exercises muting and
    // confirmation, which are downstream of the tier either way.
    config.fastAnswers = false
    return config
}

/// Captures `emit` output so routing decisions can be asserted, not eyeballed.
private final class RecordingLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// A conversation store rooted entirely inside `directory` — nothing under the
/// real state directory is ever read or written.
private func scratchStore(in directory: URL) -> ConversationStore {
    ConversationStore(
        workingDirectory: directory.appendingPathComponent("project"),
        root: directory.appendingPathComponent("conversations"),
        timeout: 30 * 60
    )
}

@Suite("Voice pipeline")
struct VoicePipelineTests {
    /// Regression: the Muted toggle used to live only in the UI, so it stopped
    /// the current utterance and nothing after it — the next result spoke
    /// regardless.
    @Test("Muting actually suppresses later speech")
    func mutingSuppressesSubsequentSpeech() async throws {
        let speaker = RecordingSpeaker()
        // "switch to nowhere" matches no project, and the pipeline says so —
        // a path that speaks without dispatching anything.
        let pipeline = VoicePipeline(
            config: configWithProjects(),
            transcriber: FixedTranscriber(text: "switch to nowhere"),
            speaker: speaker,
            dryRun: true,
            emit: { _ in }
        )

        await pipeline.handle(clip())
        let beforeMute = speaker.spoken.count
        #expect(beforeMute > 0, "the test is meaningless unless this path speaks")

        await pipeline.setSpeechEnabled(false)
        await pipeline.handle(clip())

        #expect(speaker.spoken.count == beforeMute, "nothing should be spoken while muted")
    }

    @Test("Unmuting restores speech")
    func unmutingRestoresSpeech() async throws {
        let speaker = RecordingSpeaker()
        let pipeline = VoicePipeline(
            config: configWithProjects(),
            transcriber: FixedTranscriber(text: "switch to nowhere"),
            speaker: speaker,
            dryRun: true,
            emit: { _ in }
        )
        await pipeline.setSpeechEnabled(false)
        await pipeline.handle(clip())
        #expect(speaker.spoken.isEmpty)

        await pipeline.setSpeechEnabled(true)
        await pipeline.handle(clip())
        #expect(!speaker.spoken.isEmpty, "speech should resume once unmuted")
    }

    @Test("Muting stops whatever is being said right now")
    func mutingStopsCurrentUtterance() async {
        let speaker = RecordingSpeaker()
        let pipeline = VoicePipeline(
            config: configWithProjects(),
            transcriber: FixedTranscriber(text: "x"),
            speaker: speaker,
            emit: { _ in }
        )
        await pipeline.setSpeechEnabled(false)
        #expect(speaker.stopCount >= 1)
    }

    /// Regression: `updateConfig` replaced the config but left the conversation
    /// store pointing at the previous directory, so a project switch made from
    /// the menu ran in the new project while reading and writing the old
    /// project's history.
    @Test("Switching project by config re-points conversation memory")
    func configSwitchRepointsConversation() async throws {
        var config = configWithProjects()
        let pipeline = VoicePipeline(
            config: config,
            transcriber: FixedTranscriber(text: "x"),
            emit: { _ in }
        )
        #expect(await pipeline.currentConversationDirectory
                == config.resolvedProjects.first(where: { $0.id == "alpha" })?.path)

        config.activeProjectID = "beta"
        await pipeline.updateConfig(config)

        #expect(await pipeline.currentConversationDirectory
                == config.resolvedProjects.first(where: { $0.id == "beta" })?.path,
                "history must follow the active project")
    }

    /// Regression: undo used to have its own pending slot with no expiry, while
    /// the task path timed out after 60s. A "yes" said much later — or misheard
    /// — would have reset the repository. Both now share one mechanism, so the
    /// timeout can't apply to only one of them.
    @Test("Task and undo confirmations share one expiring mechanism")
    func confirmationsShareOneTimeout() async throws {
        let speaker = RecordingSpeaker()
        let pipeline = VoicePipeline(
            config: configWithProjects(),
            transcriber: FixedTranscriber(text: "delete everything in the project"),
            speaker: speaker,
            emit: { _ in }
        )

        #expect(!(await pipeline.awaitingConfirmation))
        await pipeline.handle(clip())
        #expect(await pipeline.awaitingConfirmation, "a destructive request should be held")

        // There is exactly one timeout, applied to whatever is pending.
        #expect(VoicePipeline.confirmationTimeout == 60)
    }

    /// An unclear reply must not be read as consent, for either kind.
    @Test("An ambiguous reply clears the pending action without running it")
    func ambiguousReplyCancels() async throws {
        let pipeline = VoicePipeline(
            config: configWithProjects(),
            transcriber: FixedTranscriber(text: "delete everything in the project"),
            emit: { _ in }
        )
        await pipeline.handle(clip())
        #expect(await pipeline.awaitingConfirmation)

        // The same transcriber now supplies a reply that is neither yes nor no.
        await pipeline.handle(clip())
        #expect(!(await pipeline.awaitingConfirmation), "an unclear reply must clear the gate")
    }

    /// Regression for the misroute that loses work: `activeCoding` used to be
    /// judged from the *latest* active turn only, so one on-device trivia
    /// answer after an engine turn flipped it false — and the next "make it
    /// faster", aimed at the engine's work two turns back, was handed to the
    /// fast tier and the coding request silently swallowed.
    @Test("An on-device answer between engine work and a follow-up keeps coding active")
    func onDeviceTurnDoesNotEndCodingConversation() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxrouter-pipeline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let store = scratchStore(in: scratch)
        await store.record(
            task: "fix the flaky parser test", engineId: "claude", sessionId: nil,
            runId: "r1", summary: "made the parser test deterministic", succeeded: true
        )
        await store.record(
            task: "how tall is everest", engineId: VoicePipeline.onDeviceEngineId,
            sessionId: nil, runId: "r2", summary: "8,849 metres", succeeded: true
        )

        // The gate input itself: an engine turn anywhere in the active window
        // keeps the conversation a coding one, whatever answered last.
        let turns = await store.activeTurns()
        #expect(turns.count == 2, "both seeded turns must be inside the active window")
        #expect(turns.last?.engineId == VoicePipeline.onDeviceEngineId,
                "the seed must reproduce the failing shape: on-device answered last")
        #expect(VoicePipeline.codingConversationIsActive(turns),
                "one on-device answer must not end the coding conversation")

        // And end to end: the pipeline routes the imperative to the engine.
        var config = configWithProjects()
        config.fastAnswers = true
        let lines = RecordingLines()
        let pipeline = VoicePipeline(
            config: config,
            transcriber: FixedTranscriber(text: "make it faster"),
            dryRun: true,
            emit: { lines.append($0) }
        )
        await pipeline.useConversationStore(
            store, directory: scratch.appendingPathComponent("project").path
        )
        await pipeline.handle(clip())

        #expect(lines.all.contains { $0.contains("engine only") },
                "the imperative refers to the engine's work and must go there")
        #expect(!lines.all.contains { $0.contains("would try the fast tier") },
                "trying the fast tier here is the misroute that loses work")
    }

    /// The counterweight: leaning the fix any further — say, "any turn at
    /// all" — would make a run of trivia read as a coding conversation and
    /// cost fast answers for nothing. All-on-device history must stay
    /// non-coding, and the same imperative must remain fair game for the tier.
    @Test("A conversation of only on-device answers is not a coding conversation")
    func onDeviceOnlyConversationStaysNonCoding() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxrouter-pipeline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let store = scratchStore(in: scratch)
        for (run, question) in [("r1", "how tall is everest"), ("r2", "and in feet")] {
            await store.record(
                task: question, engineId: VoicePipeline.onDeviceEngineId,
                sessionId: nil, runId: run, summary: "answered", succeeded: true
            )
        }

        let turns = await store.activeTurns()
        #expect(turns.count == 2)
        #expect(!VoicePipeline.codingConversationIsActive(turns),
                "pure trivia must not turn imperatives into coding tasks")
        #expect(!VoicePipeline.codingConversationIsActive([]),
                "no history at all is not a coding conversation either")

        var config = configWithProjects()
        config.fastAnswers = true
        let lines = RecordingLines()
        let pipeline = VoicePipeline(
            config: config,
            transcriber: FixedTranscriber(text: "make it faster"),
            dryRun: true,
            emit: { lines.append($0) }
        )
        await pipeline.useConversationStore(
            store, directory: scratch.appendingPathComponent("project").path
        )
        await pipeline.handle(clip())

        #expect(lines.all.contains { $0.contains("would try the fast tier") },
                "with no engine work in the window, the fast tier keeps its shot")
    }

    @Test("A config change that doesn't move directory keeps the store")
    func unrelatedConfigChangeKeepsStore() async throws {
        var config = configWithProjects()
        let pipeline = VoicePipeline(
            config: config,
            transcriber: FixedTranscriber(text: "x"),
            emit: { _ in }
        )
        let before = await pipeline.currentConversationDirectory

        config.engineModels["claude"] = "opus"
        await pipeline.updateConfig(config)

        #expect(await pipeline.currentConversationDirectory == before)
    }
}

