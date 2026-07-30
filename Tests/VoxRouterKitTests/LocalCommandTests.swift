import Foundation
import Testing
@testable import VoxRouterKit

/// The router decides what never reaches an engine, so the failure that matters
/// isn't a command not firing — it's a command firing when it shouldn't and
/// silently eating a real task.
@Suite("Local command routing")
struct LocalCommandRoutingTests {
    private func context(notes: URL? = nil) -> LocalContext {
        LocalContext(
            notesFile: notes ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("voxrouter-test-\(UUID().uuidString).md")
        )
    }

    /// Every one of these was captured by an earlier version of the router.
    /// "run" and "open" are among the commonest verbs in a coding request, so
    /// matching on the verb alone quietly swallowed real work.
    @Test("Engine tasks are never claimed", arguments: [
        "run the tests and fix what breaks",
        "run the build and tell me what fails",
        "open the parser and refactor it",
        "open a pull request for this branch",
        "note the retry logic is wrong and fix it",
        "set up a timer abstraction in the scheduler",
        "turn the volume control into a slider",
    ])
    func passesTasksThrough(_ task: String) async {
        let outcome = await LocalCommandRouter().handle(task, context: context())
        #expect(outcome == .notMine, "\"\(task)\" should have gone to an engine")
    }

    @Test("Local questions are answered locally", arguments: [
        "what can you do", "what's my quota", "say that again", "my notes",
    ])
    func claimsLocalQuestions(_ phrase: String) async {
        let outcome = await LocalCommandRouter().handle(phrase, context: context())
        #expect(outcome != .notMine, "\"\(phrase)\" should have been handled locally")
    }

    /// Order dependence is the thing most likely to break when a command is
    /// added, and it fails silently — the wrong command just answers.
    @Test("A note about a timer is a note, not a timer")
    func noteBeatsTimer() async throws {
        let notes = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxrouter-note-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: notes) }

        let outcome = await LocalCommandRouter().handle(
            "note down set a timer for the standup", context: context(notes: notes)
        )
        #expect(outcome == .handled(reply: "Noted."))
        let written = try String(contentsOf: notes, encoding: .utf8)
        #expect(written.contains("set a timer for the standup"))
    }

    @Test("'remind me in ten minutes' is a timer, not a note")
    func timerBeatsNote() async throws {
        let outcome = await LocalCommandRouter().handle("remind me in ten minutes", context: context())
        let reply = try #require(outcome.reply)
        #expect(reply.contains("10 minutes"))
    }

    @Test("An empty argument doesn't fire a command")
    func ignoresBareTriggers() async {
        for bare in ["run", "open", "note"] {
            #expect(await LocalCommandRouter().handle(bare, context: context()) == .notMine)
        }
    }

    @Test("Matching ignores case and trailing punctuation")
    func toleratesSpokenPunctuation() async {
        for phrasing in ["What can you do?", "what can you do", "WHAT CAN YOU DO!"] {
            #expect(await LocalCommandRouter().handle(phrasing, context: context()) != .notMine)
        }
    }
}

extension LocalOutcome {
    var reply: String? {
        if case .handled(let reply) = self { return reply }
        return nil
    }
}

@Suite("Duration parsing")
struct DurationParserTests {
    @Test("Digits and words both work")
    func parsesBothForms() {
        #expect(DurationParser.seconds(in: "set a timer for 5 minutes") == 300)
        #expect(DurationParser.seconds(in: "set a timer for five minutes") == 300)
        #expect(DurationParser.seconds(in: "90 seconds") == 90)
        #expect(DurationParser.seconds(in: "1 hour") == 3600)
    }

    /// Speech gives no units about half the time — "remind me in ten" means
    /// minutes to everyone who says it.
    @Test("Bare numbers default to minutes")
    func defaultsToMinutes() {
        #expect(DurationParser.seconds(in: "remind me in ten") == 600)
    }

    @Test("No duration means no timer")
    func rejectsMissingDuration() {
        #expect(DurationParser.seconds(in: "set a timer") == nil)
        #expect(DurationParser.seconds(in: "set a timer for 0 minutes") == nil)
    }

    @Test("Spoken durations read naturally")
    func speaksNaturally() {
        #expect(DurationParser.spoken(60) == "a minute")
        #expect(DurationParser.spoken(300) == "5 minutes")
        #expect(DurationParser.spoken(3600) == "an hour")
        #expect(DurationParser.spoken(30) == "30 seconds")
    }
}

@Suite("Quick notes")
struct QuickNoteTests {
    private func scratchFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voxrouter-notes-\(UUID().uuidString).md")
    }

    @Test("Notes append under one heading per day")
    func groupsByDay() throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let day = Date(timeIntervalSince1970: 1_700_000_000)

        try QuickNote.append("first", to: file, now: day)
        try QuickNote.append("second", to: file, now: day.addingTimeInterval(60))
        try QuickNote.append("next day", to: file, now: day.addingTimeInterval(86_400))

        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.components(separatedBy: "## ").count == 3, "two days, two headings")
        #expect(contents.contains("first"))
        #expect(contents.contains("next day"))
    }

    @Test("Reading back drops the timestamp, keeping the words")
    func readsBackCleanly() throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }

        try QuickNote.append("the lease renews in March", to: file)
        let recent = QuickNote.recent(from: file)
        #expect(recent == ["the lease renews in March"])
    }

    @Test("Only the most recent notes are read back")
    func limitsReadback() throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }

        for index in 1...6 { try QuickNote.append("note \(index)", to: file) }
        let recent = QuickNote.recent(from: file, limit: 3)
        #expect(recent == ["note 4", "note 5", "note 6"])
    }

    @Test("A missing file reads as no notes, not an error")
    func missingFileIsEmpty() {
        #expect(QuickNote.recent(from: scratchFile()).isEmpty)
    }

    @Test("Empty notes aren't written")
    func ignoresEmpty() throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try QuickNote.append("   ", to: file)
        #expect(QuickNote.recent(from: file).isEmpty)
    }
}

@Suite("Shortcut name matching")
struct ShortcutMatchingTests {
    private let names = [
        "Turn off the lights", "Open my watchlist", "Log a film",
        "Water Eject", "Search Letterboxd",
    ]

    @Test("Spoken names match regardless of case and punctuation")
    func matchesSpokenNames() {
        #expect(Shortcuts.exactMatch("turn off the lights", in: names) == "Turn off the lights")
        #expect(Shortcuts.exactMatch("Water eject", in: names) == "Water Eject")
    }

    /// The reason exact matching exists: a sentence that merely *contains* a
    /// shortcut name is a task, not an invocation.
    @Test("A sentence containing a shortcut name is not a match")
    func rejectsContainingSentences() {
        #expect(Shortcuts.exactMatch("log a film about the trip to Japan", in: names) == nil)
        #expect(Shortcuts.exactMatch("open my watchlist and add Dune", in: names) == nil)
        #expect(Shortcuts.exactMatch("", in: names) == nil)
    }

    @Test("Explicit invocation tolerates fuzzier names")
    func resolvesFuzzily() {
        #expect(Shortcuts.resolve("watchlist", in: names) == "Open my watchlist")
        #expect(Shortcuts.resolve("no such shortcut", in: names) == nil)
    }

    /// The CLI's own message is the only useful thing it produces on failure.
    @Test("Error text is reduced to one speakable sentence")
    func extractsErrorSentence() {
        #expect(Shortcuts.firstSentence(of: "Error: This action requires Letterboxd to be installed.\n")
            == "This action requires Letterboxd to be installed.")
        #expect(Shortcuts.firstSentence(of: "   ") == nil)
    }

    @Test("A long-running shortcut reports as running, not failed")
    func stillRunningIsNotFailure() {
        let spoken = Shortcuts.spokenResult(of: .failure(.stillRunning("Water Eject")))
        #expect(spoken == "Water Eject is running.")
    }

    /// A shortcut that changed something on screen has already shown its work.
    @Test("A silent success stays silent")
    func silentSuccess() {
        #expect(Shortcuts.spokenResult(of: .success(nil)) == nil)
        #expect(Shortcuts.spokenResult(of: .success("42")) == "42")
    }
}
