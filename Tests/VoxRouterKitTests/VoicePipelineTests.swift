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
    return config
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

