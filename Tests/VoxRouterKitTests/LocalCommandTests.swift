import Foundation
import Testing
@testable import VoxRouterKit

/// The router decides what never reaches an engine, so the failure that matters
/// isn't a command not firing — it's a command firing when it shouldn't and
/// silently eating a real task.
@Suite("Local command routing")
struct LocalCommandRoutingTests {
    /// Everything isolated — including the timer store, explicitly.
    ///
    /// `LocalContext` defaults `timers` to the real per-user file, and leaving
    /// that default in place meant the "remind me in ten minutes" test planted
    /// an actual timer on the machine running the suite: ten minutes after
    /// every test run, the running app announced a timer nobody had set.
    private func context(notes: URL? = nil) -> LocalContext {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxrouter-test-\(UUID().uuidString)")
        return LocalContext(
            notesFile: notes ?? scratch.appendingPathComponent("notes.md"),
            timers: TimerStore(file: scratch.appendingPathComponent("timers.json"))
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

    /// The menu's "what you can say" list is built from these, so a command
    /// without one would simply be missing from the only place the app
    /// advertises what it does.
    @Test("Every command carries an example phrase, and the example works")
    func examplesAreUsable() async {
        // Commands that only claim an utterance when the thing it names exists
        // — a shortcut called "Turn off the lights", an app called Safari. Their
        // examples can't be asserted here without making the suite depend on
        // what happens to be installed on the machine running it.
        let environmentDependent: Set<String> = ["shortcut.run", "system.open"]

        for command in LocalCommandRouter.standard {
            let example = command.examples.first
            #expect(example?.isEmpty == false, "\(command.id) has no example")

            guard let example, !environmentDependent.contains(command.id) else { continue }
            // The example must actually route to the command it illustrates.
            #expect(command.matches(example) != nil, "\(command.id)'s example doesn't match it")
        }
    }

    @Test("Command ids are unique, so the menu can key on them")
    func idsAreUnique() {
        let ids = LocalCommandRouter.standard.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// The menu lists example phrases keyed by the phrase itself, so two
    /// commands sharing one would collapse into a single row.
    @Test("Example phrases are distinct")
    func examplesAreDistinct() {
        let examples = LocalCommandRouter.standard.compactMap(\.examples.first)
        #expect(Set(examples).count == examples.count)
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

    /// The bug this replaced: a substring scan over an unordered dictionary.
    /// "forty five minutes" came back as 5, 40 or 45 minutes depending on the
    /// process's hash seed, so the same sentence set a different timer per
    /// launch. Compound numbers are the case that exposed it.
    @Test("Compound number words parse as one number")
    func parsesCompoundNumbers() {
        #expect(DurationParser.seconds(in: "set a timer for forty five minutes") == 45 * 60)
        #expect(DurationParser.seconds(in: "set a timer for twenty five minutes") == 25 * 60)
        #expect(DurationParser.seconds(in: "set a timer for thirty minutes") == 30 * 60)
    }

    /// "ninety" contains "nine"; "seventeen" contains "seven". Whole-token
    /// matching is what keeps those apart.
    @Test("Longer number words are not read as the shorter ones inside them")
    func doesNotMatchNumbersInsideNumbers() {
        #expect(DurationParser.seconds(in: "set a timer for ninety seconds") == 90)
        #expect(DurationParser.seconds(in: "set a timer for seventeen minutes") == 17 * 60)
    }

    @Test("The same phrase always parses the same way")
    func isDeterministic() {
        for phrase in ["forty five minutes", "ninety seconds", "seventeen minutes"] {
            let readings = Set((0..<50).map { _ in DurationParser.seconds(in: phrase) })
            #expect(readings.count == 1, "\"\(phrase)\" parsed \(readings.count) different ways")
        }
    }

    /// "Set a timer for an hour" states a duration without a number.
    @Test("A unit with no number means one of it")
    func impliedSingleUnit() {
        #expect(DurationParser.seconds(in: "set a timer for an hour") == 3600)
        #expect(DurationParser.seconds(in: "set a timer for a minute") == 60)
        #expect(DurationParser.seconds(in: "set a timer for half an hour") == 1800)
    }

    /// "An hour and a half" puts the half after the unit; it parsed as exactly
    /// one hour, and the confirmation sounded plausible enough that the missing
    /// thirty minutes went unnoticed.
    @Test("A trailing half extends the unit before it")
    func trailingHalf() {
        #expect(DurationParser.seconds(in: "set a timer for an hour and a half") == 5400)
        #expect(DurationParser.seconds(in: "set a timer for a minute and a half") == 90)
        #expect(DurationParser.seconds(in: "set a timer for two hours and a half") == 9000)
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

    /// The confirmation is the user's only check that they were heard, so a
    /// truncating division that reported a 90-second timer as "a minute" was
    /// worse than a clumsy phrasing.
    @Test("The confirmation never understates the timer that was set")
    func confirmationIsTruthful() {
        #expect(DurationParser.spoken(90) == "90 seconds")
        #expect(DurationParser.spoken(150) == "2 minutes 30 seconds")
        #expect(DurationParser.spoken(5400) == "an hour and 30 minutes")
        #expect(DurationParser.spoken(7200) == "2 hours")
    }

    /// Unit words were matched by prefix, and "minus" starts with "min" — so
    /// "minus five minutes" counted "minus" as a whole minute and set six.
    @Test("A word that merely starts like a unit is not a unit")
    func doesNotTreatWordsAsUnits() {
        #expect(DurationParser.seconds(in: "set a timer for minus five minutes") == 5 * 60)
        #expect(DurationParser.seconds(in: "set a timer for a minimum of ten minutes") == 10 * 60)
        #expect(DurationParser.seconds(in: "set a timer for 5 mins") == 5 * 60)
        #expect(DurationParser.seconds(in: "set a timer for 30 secs") == 30)
        #expect(DurationParser.seconds(in: "set a timer for 2 hrs") == 2 * 3600)
    }

    @Test("Mixed units are summed, not read as one of them")
    func sumsMixedUnits() {
        #expect(DurationParser.seconds(in: "2 minutes 30 seconds") == 150)
        #expect(DurationParser.seconds(in: "an hour and 30 minutes") == 5400)
        #expect(DurationParser.seconds(in: "one hour two minutes three seconds") == 3723)
    }

    /// Whatever the phrasing, saying it back must mean the same duration.
    @Test("Parse and read-back agree", arguments: [
        "90 seconds", "forty five minutes", "an hour", "half an hour",
        "5 minutes", "ninety seconds", "two hours", "2 minutes 30 seconds",
        "an hour and 30 minutes", "1 hour 5 minutes",
    ])
    func roundTrips(_ phrase: String) throws {
        let parsed = try #require(DurationParser.seconds(in: phrase))
        let reparsed = try #require(DurationParser.seconds(in: DurationParser.spoken(parsed)))
        #expect(reparsed == parsed, "\"\(phrase)\" → \(parsed)s → \"\(DurationParser.spoken(parsed))\"")
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
