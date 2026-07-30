import Foundation
import Testing
@testable import VoxRouterKit

/// What the commands *say*, driven through the router with a stub context.
///
/// Matching was tested first because a mis-claimed utterance loses a task, but
/// the replies matter too: they're the only signal the user gets that they were
/// understood, and several of these paths only happen when something is broken.
@Suite("Local command replies")
struct LocalCommandBehaviourTests {
    private func context(
        quota: @escaping @Sendable () async -> [ProviderUsage] = { [] },
        lastReply: @escaping @Sendable () async -> String? = { nil },
        notes: URL? = nil
    ) -> LocalContext {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxrouter-beh-\(UUID().uuidString)")
        return LocalContext(
            notesFile: notes ?? scratch.appendingPathComponent("notes.md"),
            quota: quota,
            lastReply: lastReply,
            timers: TimerStore(file: scratch.appendingPathComponent("timers.json"))
        )
    }

    private func reply(_ text: String, _ context: LocalContext) async -> String? {
        guard case .handled(let reply) = await LocalCommandRouter().handle(text, context: context)
        else { return nil }
        return reply
    }

    /// The dashboard being down is the case that actually happens — OpenUsage
    /// not running at all is the default state on a fresh Mac.
    @Test("No quota data says so, rather than reporting nothing used")
    func quotaUnavailable() async {
        let said = await reply("what's my quota", context())
        #expect(said == "I can't reach the quota dashboard.")
    }

    @Test("Quota reads out each provider's binding window")
    func quotaReportsPercentages() async throws {
        let json = """
        [{"providerId":"claude","displayName":"Claude","plan":"max",
          "lines":[{"type":"progress","label":"5 hour","used":42,"limit":100}]}]
        """
        let usage = try JSONDecoder().decode([ProviderUsage].self, from: Data(json.utf8))
        let said = try #require(await reply("what's my quota", context(quota: { usage })))
        #expect(said.contains("Claude"))
        #expect(said.contains("42"))
    }

    @Test("Nothing said yet is admitted, not faked")
    func repeatWithNothingToRepeat() async {
        #expect(await reply("say that again", context()) == "I haven't said anything yet.")
    }

    @Test("Repeat says the last reply back")
    func repeatsLastReply() async {
        let said = await reply("say that again", context(lastReply: { "The tests pass." }))
        #expect(said == "The tests pass.")
    }

    @Test("Reading notes with none taken says so")
    func noNotesYet() async {
        #expect(await reply("what are my notes", context()) == "You haven't noted anything yet.")
    }

    @Test("A note is saved and can be read straight back")
    func noteRoundTrip() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxrouter-beh-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }
        let shared = context(notes: file)

        #expect(await reply("note down the lease renews in March", shared) == "Noted.")
        let read = try #require(await reply("what are my notes", shared))
        #expect(read.contains("lease renews in March"))
    }

    @Test("A timer without a duration asks for one instead of guessing")
    func timerNeedsDuration() async {
        #expect(await reply("set a timer", context()) == "How long for?")
    }

    @Test("Setting, listing and cancelling a timer agree with each other")
    func timerLifecycle() async throws {
        let shared = context()

        let set = try #require(await reply("set a timer for 10 minutes", shared))
        #expect(set == "Timer set for 10 minutes.")

        let listed = try #require(await reply("what timers do i have", shared))
        #expect(listed.contains("minutes left"), "got \(listed)")

        #expect(await reply("cancel the timer", shared) == "Timer cancelled.")
        #expect(await reply("what timers do i have", shared) == "No timers running.")
        #expect(await reply("cancel the timer", shared) == "There's no timer running.")
    }

    @Test("Several timers are summarised rather than listed one by one")
    func manyTimers() async throws {
        let shared = context()
        _ = await reply("set a timer for 20 minutes", shared)
        _ = await reply("set a timer for 5 minutes", shared)

        let listed = try #require(await reply("what timers do i have", shared))
        #expect(listed.hasPrefix("2 timers"))
        // The soonest one is the one you care about.
        #expect(listed.contains("4 minutes") || listed.contains("5 minutes"), "got \(listed)")

        #expect(await reply("cancel my timers", shared) == "Cancelled 2 timers.")
    }

    /// Volume and app launching change something you can see or hear, so an
    /// announcement is pure noise.
    @Test("Commands with visible effects stay silent")
    func silentWhereObvious() async {
        #expect(await reply("mute", context()) == nil)
        #expect(await reply("volume up", context()) == nil)
    }

    @Test("Help lists what's actually available")
    func helpMentionsTheCommands() async throws {
        let said = try #require(await reply("what can you do", context()))
        for topic in ["shortcut", "timer", "volume", "note", "quota"] {
            #expect(said.lowercased().contains(topic), "help never mentions \(topic)")
        }
    }
}
