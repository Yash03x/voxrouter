import Foundation
import Testing
@testable import VoxRouterKit

private func scratchRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("voxrouter-conv-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func store(
    timeout: TimeInterval = 1800,
    directory: String = "/tmp/project-a"
) throws -> ConversationStore {
    ConversationStore(
        workingDirectory: URL(fileURLWithPath: directory),
        root: try scratchRoot(),
        timeout: timeout
    )
}

@Suite("Conversation continuity")
struct ConversationStoreTests {
    @Test("A first command has nothing to continue from")
    func firstCommandIsFresh() async throws {
        let conversation = try store()
        #expect(await conversation.continuity(for: "claude") == .fresh)
        #expect(await conversation.activeTurns().isEmpty)
    }

    /// The stronger form of continuity: same engine, so its own session is
    /// resumed and the model keeps its full context.
    @Test("A follow-up on the same engine resumes its session")
    func sameEngineResumesSession() async throws {
        let conversation = try store()
        await conversation.record(
            task: "run the tests", engineId: "claude", sessionId: "sess-1",
            runId: "r1", summary: "Three tests failed.", succeeded: true
        )
        #expect(
            await conversation.continuity(for: "claude")
                == .resumeSession(engineId: "claude", sessionId: "sess-1")
        )
    }

    /// Across an engine boundary no session can be resumed, so history is
    /// restated instead — the whole reason "fix those failures" resolves.
    @Test("A follow-up on a different engine gets a context preamble")
    func differentEngineGetsPreamble() async throws {
        let conversation = try store()
        await conversation.record(
            task: "run the tests", engineId: "claude", sessionId: "sess-1",
            runId: "r1", summary: "Three tests failed in the parser.", succeeded: true
        )
        guard case .preamble(let digest) = await conversation.continuity(for: "codex") else {
            Issue.record("expected a preamble")
            return
        }
        #expect(digest.contains("run the tests"))
        #expect(digest.contains("Three tests failed in the parser"))
    }

    @Test("Without a session id, the same engine still gets a preamble")
    func missingSessionFallsBackToPreamble() async throws {
        let conversation = try store()
        await conversation.record(
            task: "do a thing", engineId: "claude", sessionId: nil,
            runId: "r1", summary: "done", succeeded: true
        )
        guard case .preamble = await conversation.continuity(for: "claude") else {
            Issue.record("expected a preamble when there's no session to resume")
            return
        }
    }

    /// Regression: continuity looked only at the literal last turn, so one
    /// quick on-device answer after an engine command permanently downgraded
    /// every follow-up from a full-context resume to the digest preamble.
    @Test("A quick on-device answer doesn't sever the engine session")
    func onDeviceTurnKeepsSessionResume() async throws {
        let conversation = try store()
        await conversation.record(
            task: "run the tests", engineId: "claude", sessionId: "sess-1",
            runId: "r1", summary: "Three tests failed.", succeeded: true
        )
        await conversation.record(
            task: "what's 17 times 23", engineId: VoicePipeline.onDeviceEngineId,
            sessionId: nil, runId: "r2", summary: "391.", succeeded: true
        )
        #expect(
            await conversation.continuity(for: "claude")
                == .resumeSession(engineId: "claude", sessionId: "sess-1")
        )
    }

    /// When the preamble is the answer — engine changed — the quick Q&A is
    /// real conversation the follow-up may refer back to, so it stays in.
    @Test("The preamble still includes on-device turns")
    func preambleIncludesOnDeviceTurns() async throws {
        let conversation = try store()
        await conversation.record(
            task: "run the tests", engineId: "claude", sessionId: "sess-1",
            runId: "r1", summary: "Three tests failed.", succeeded: true
        )
        await conversation.record(
            task: "what's 17 times 23", engineId: VoicePipeline.onDeviceEngineId,
            sessionId: nil, runId: "r2", summary: "391.", succeeded: true
        )
        guard case .preamble(let digest) = await conversation.continuity(for: "codex") else {
            Issue.record("expected a preamble")
            return
        }
        #expect(digest.contains("run the tests"))
        #expect(digest.contains("what's 17 times 23"))
    }

    /// A conversation that is only quick questions holds no session anywhere,
    /// so the best available continuity is the digest.
    @Test("All on-device turns fall back to a preamble")
    func allOnDeviceTurnsGivePreamble() async throws {
        let conversation = try store()
        await conversation.record(
            task: "what's the capital of Peru", engineId: VoicePipeline.onDeviceEngineId,
            sessionId: nil, runId: "r1", summary: "Lima.", succeeded: true
        )
        guard case .preamble(let digest) = await conversation.continuity(for: "claude") else {
            Issue.record("expected a preamble, not a resume or fresh start")
            return
        }
        #expect(digest.contains("capital of Peru"))
    }

    /// Regression: on-device turns consumed the turn window, so a run of
    /// quick questions evicted the engine turn holding the recovery point and
    /// "undo" went blind.
    @Test("Quick questions don't evict the turn undo needs")
    func recoveryPointSurvivesQuickQuestions() async throws {
        let conversation = try store()
        // A whole second: the archive round-trips through ISO 8601, which
        // drops fractional seconds, and the comparison below is exact.
        let recovery = RecoveryPoint(
            runId: "r0", directory: "/tmp/project-a", head: "abcdef1234567890",
            branch: "main", dirtyRef: nil,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await conversation.record(
            task: "refactor the parser", engineId: "claude", sessionId: "sess-1",
            runId: "r0", summary: "done", succeeded: true, recovery: recovery
        )
        for index in 1...12 {
            await conversation.record(
                task: "quick question \(index)", engineId: VoicePipeline.onDeviceEngineId,
                sessionId: nil, runId: "r\(index)", summary: "answered", succeeded: true
            )
        }
        let recoverable = await conversation.mostRecentRecoverable()
        #expect(recoverable?.runId == "r0")
        #expect(recoverable?.recovery == recovery)
        // The window cap itself still holds.
        #expect(await conversation.activeTurns().count == 12)
        // And the engine session survives alongside the recovery point.
        #expect(
            await conversation.continuity(for: "claude")
                == .resumeSession(engineId: "claude", sessionId: "sess-1")
        )
    }

    /// A long silence means the user moved on; inheriting yesterday's task is
    /// worse than starting clean.
    @Test("An idle gap ends the conversation")
    func idleGapStartsFresh() async throws {
        let conversation = try store(timeout: 60)
        let old = Date().addingTimeInterval(-600)
        await conversation.record(
            task: "old task", engineId: "claude", sessionId: "sess-1",
            runId: "r1", summary: "done", succeeded: true, now: old
        )
        #expect(await conversation.continuity(for: "claude") == .fresh)
        #expect(await conversation.activeTurns().isEmpty)
    }

    @Test("Recording after a long gap begins a new conversation")
    func recordAfterGapResetsHistory() async throws {
        let conversation = try store(timeout: 60)
        await conversation.record(
            task: "old", engineId: "claude", sessionId: "s1", runId: "r1",
            summary: "x", succeeded: true, now: Date().addingTimeInterval(-600)
        )
        await conversation.record(
            task: "new", engineId: "claude", sessionId: "s2", runId: "r2",
            summary: "y", succeeded: true
        )
        let turns = await conversation.activeTurns()
        #expect(turns.count == 1)
        #expect(turns.first?.task == "new")
    }

    @Test("Turns accumulate within the window")
    func accumulatesTurns() async throws {
        let conversation = try store()
        for index in 1...3 {
            await conversation.record(
                task: "task \(index)", engineId: "claude", sessionId: "s\(index)",
                runId: "r\(index)", summary: "done \(index)", succeeded: true
            )
        }
        #expect(await conversation.activeTurns().count == 3)
        // The most recent session is the one worth resuming.
        #expect(
            await conversation.continuity(for: "claude")
                == .resumeSession(engineId: "claude", sessionId: "s3")
        )
    }

    @Test("History is capped so the preamble can't grow without bound")
    func historyIsCapped() async throws {
        let conversation = ConversationStore(
            workingDirectory: URL(fileURLWithPath: "/tmp/p"),
            root: try scratchRoot(),
            timeout: 1800,
            maxTurns: 4
        )
        for index in 1...10 {
            await conversation.record(
                task: "t\(index)", engineId: "claude", sessionId: "s\(index)",
                runId: "r\(index)", summary: nil, succeeded: true
            )
        }
        #expect(await conversation.activeTurns().count == 4)
    }

    @Test("reset clears the conversation")
    func resetClears() async throws {
        let conversation = try store()
        await conversation.record(
            task: "t", engineId: "claude", sessionId: "s", runId: "r",
            summary: "x", succeeded: true
        )
        await conversation.reset()
        #expect(await conversation.continuity(for: "claude") == .fresh)
    }

    /// Two projects are two conversations; a follow-up in one must not inherit
    /// the other's context.
    @Test("Separate directories keep separate conversations")
    func directoriesAreIsolated() async throws {
        let root = try scratchRoot()
        let projectA = ConversationStore(
            workingDirectory: URL(fileURLWithPath: "/tmp/project-a"), root: root
        )
        let projectB = ConversationStore(
            workingDirectory: URL(fileURLWithPath: "/tmp/project-b"), root: root
        )
        await projectA.record(
            task: "in A", engineId: "claude", sessionId: "sa", runId: "r",
            summary: "x", succeeded: true
        )
        #expect(await projectB.continuity(for: "claude") == .fresh)
        #expect(await projectA.activeTurns().count == 1)
    }

    @Test("A conversation survives a restart")
    func persistsAcrossInstances() async throws {
        let root = try scratchRoot()
        let path = URL(fileURLWithPath: "/tmp/persist-me")
        let first = ConversationStore(workingDirectory: path, root: root)
        await first.record(
            task: "remember me", engineId: "codex", sessionId: "thread-9",
            runId: "r1", summary: "ok", succeeded: true
        )

        let second = ConversationStore(workingDirectory: path, root: root)
        #expect(
            await second.continuity(for: "codex")
                == .resumeSession(engineId: "codex", sessionId: "thread-9")
        )
    }

    @Test("A failed turn is recorded as not completed")
    func failedTurnInDigest() async throws {
        let conversation = try store()
        await conversation.record(
            task: "build it", engineId: "claude", sessionId: nil, runId: "r",
            summary: nil, succeeded: false
        )
        guard case .preamble(let digest) = await conversation.continuity(for: "codex") else {
            Issue.record("expected a preamble")
            return
        }
        #expect(digest.contains("did not complete"))
    }
}

@Suite("Spoken conversation reset")
struct ResetPhraseTests {
    @Test("Bare reset phrases clear the conversation")
    func recognisesResetPhrases() {
        for phrase in ["start over", "New task", "forget that.", "never mind", "Nevermind!"] {
            #expect(VoicePipeline.isResetCommand(phrase), "should reset on: \(phrase)")
        }
    }

    /// A reset phrase inside a longer sentence is part of a request, not a
    /// command to forget everything.
    @Test("A reset phrase inside a real request is not a reset")
    func doesNotResetOnLongerRequests() {
        for phrase in [
            "start over from the top of the file",
            "new task list in the readme",
            "forget that flag and use the other one",
        ] {
            #expect(!VoicePipeline.isResetCommand(phrase), "should not reset on: \(phrase)")
        }
    }
}

@Suite("Configured model reporting")
struct EngineModelTests {
    @Test("Reads a top-level TOML scalar")
    func readsTomlScalar() {
        let toml = """
        model = "gpt-5.6-sol"
        model_reasoning_effort = "max"
        """
        #expect(EngineModel.tomlValue(key: "model", in: toml) == "gpt-5.6-sol")
        #expect(EngineModel.tomlValue(key: "model_reasoning_effort", in: toml) == "max")
    }

    /// A `model` nested under a profile table is not the global one, and
    /// reporting it would name a model that isn't going to run.
    @Test("Stops at the first table header")
    func ignoresNestedTables() {
        let toml = """
        model = "global-model"

        [profiles.other]
        model = "nested-model"
        """
        #expect(EngineModel.tomlValue(key: "model", in: toml) == "global-model")
    }

    @Test("A missing key reports nil rather than guessing")
    func missingKeyIsNil() {
        #expect(EngineModel.tomlValue(key: "model", in: "other = \"x\"") == nil)
        #expect(EngineModel.tomlValue(key: "model", in: "") == nil)
    }

    @Test("Quotes are stripped, whitespace tolerated")
    func handlesFormatting() {
        #expect(EngineModel.tomlValue(key: "model", in: "  model   =   'abc'  ") == "abc")
    }

    /// Values read out of the CLI binaries. A wrong one fails at launch, so
    /// these pin what we believe each engine accepts.
    @Test("Effort levels match what each CLI accepts")
    func effortChoices() {
        #expect(EngineRegistry.effortChoices(for: "claude")
            == ["minimal", "low", "medium", "high", "xhigh", "max"])
        // Codex accepts one more level than Claude.
        #expect(EngineRegistry.effortChoices(for: "codex").contains("ultra"))
        #expect(EngineRegistry.effortChoices(for: "nope").isEmpty)
    }

    @Test("An effort override reaches the command line")
    func effortReachesArguments() {
        let claude = ClaudeEngine(effortOverride: "xhigh")
        let claudeArgs = claude.arguments(for: "t", resuming: nil)
        #expect(claudeArgs.contains("--effort"))
        #expect(claudeArgs.contains("xhigh"))

        // Codex has no dedicated flag; it takes a config override.
        let codex = CodexEngine(effortOverride: "ultra")
        let codexArgs = codex.arguments(for: "t", resuming: nil)
        #expect(codexArgs.contains("-c"))
        #expect(codexArgs.contains(#"model_reasoning_effort="ultra""#))
    }

    @Test("No override leaves the CLI's own config alone")
    func noOverrideAddsNothing() {
        #expect(!ClaudeEngine().arguments(for: "t", resuming: nil).contains("--effort"))
        #expect(!CodexEngine().arguments(for: "t", resuming: nil).contains("-c"))
    }

    @Test("An override is reported in preference to the CLI's configured value")
    func overrideWins() {
        #expect(ClaudeEngine(effortOverride: "low").configuredEffort == "low")
        #expect(CodexEngine(modelOverride: "gpt-5.4").configuredModel == "gpt-5.4")
    }

    @Test("The codex task stays last, after any injected flags")
    func codexTaskRemainsLast() {
        let args = CodexEngine(modelOverride: "gpt-5.4", effortOverride: "high")
            .arguments(for: "do the thing", resuming: nil)
        #expect(args.last == "do the thing")
    }

    /// Regression: the list was taken from `claude --help`, which gives
    /// "'fable', 'opus', or 'sonnet'" as *examples* — so haiku was silently
    /// missing from the picker. All four families are valid aliases.
    @Test("Every Claude model family is offered")
    func claudeOffersEveryFamily() {
        let choices = ClaudeEngine.modelChoices
        for family in ["opus", "sonnet", "haiku", "fable"] {
            #expect(choices.contains(family), "\(family) should be selectable")
        }
    }

    /// Which model to use is the user's call, so pinned versions are offered
    /// rather than only the newest of each family.
    @Test("Pinned versions are offered, not just family aliases")
    func offersPinnedVersions() {
        let claude = ClaudeEngine.modelChoices
        #expect(claude.contains("opus-4-5"))
        #expect(claude.contains("sonnet-4-5"))
        #expect(claude.contains("haiku35"))
        #expect(claude.contains("opusplan"), "Claude Code's mixed planning mode")

        let codex = CodexEngine.modelChoices
        #expect(codex.contains("gpt-5.6-pro"))
        #expect(codex.contains("gpt-5.4-mini"))
        #expect(codex.count > 10)
    }

    /// The same model reachable by two spellings would just double the menu.
    @Test("No duplicate entries in either list")
    func noDuplicateChoices() {
        for list in [ClaudeEngine.modelChoices, CodexEngine.modelChoices] {
            #expect(Set(list).count == list.count)
        }
    }

    /// Regression: only the four family aliases were mapped, so a menu of
    /// twenty mixed "Opus" with "opus-4-8", "sonnet37" and "opusplan".
    @Test("Every alias renders in the same style")
    func displayNamesAreConsistent() {
        // Family, dash-versioned, compact-versioned, and the mixed mode.
        #expect(EngineDisplay.model("opus") == "Opus (latest)")
        #expect(EngineDisplay.model("opus-5") == "Opus 5")
        #expect(EngineDisplay.model("opus-4-8") == "Opus 4.8")
        #expect(EngineDisplay.model("opus41") == "Opus 4.1")
        #expect(EngineDisplay.model("opusplan") == "Opus Plan")
        #expect(EngineDisplay.model("sonnet-4-5") == "Sonnet 4.5")
        #expect(EngineDisplay.model("sonnet37") == "Sonnet 3.7")
        #expect(EngineDisplay.model("haiku45") == "Haiku 4.5")
        #expect(EngineDisplay.model("fable-5") == "Fable 5")
    }

    @Test("Nothing in the menu is left lowercase")
    func everyChoiceIsPresentable() {
        for choice in ClaudeEngine.modelChoices + CodexEngine.modelChoices {
            let label = EngineDisplay.model(choice)
            #expect(
                label.first?.isUppercase == true,
                "\(choice) renders as \"\(label)\" — inconsistent with the rest"
            )
        }
    }

    /// A trailing 8-digit group is a release date, not a version component —
    /// "Sonnet 4.5.20250929" reads like a broken version number.
    @Test("Date-pinned aliases render the date as a date")
    func datePinnedAliases() {
        #expect(EngineDisplay.model("sonnet-4-5-20250929") == "Sonnet 4.5 (2025-09-29)")
    }

    /// Discovery finds `opus-4-5` and `opus45`, two spellings of one model.
    /// Deduping on the display name is what keeps both out of the menu.
    @Test("Alternate spellings collapse to one label")
    func spellingsCollapse() {
        #expect(EngineDisplay.model("opus45") == EngineDisplay.model("opus-4-5"))
        #expect(EngineDisplay.model("sonnet46") == EngineDisplay.model("sonnet-4-6"))
        #expect(EngineDisplay.model("fable5") == EngineDisplay.model("fable-5"))
    }

    @Test("OpenAI names render consistently too")
    func openAIDisplayNames() {
        #expect(EngineDisplay.model("gpt-5.6") == "GPT-5.6")
        #expect(EngineDisplay.model("gpt-5.6-sol") == "GPT-5.6 Sol")
        #expect(EngineDisplay.model("gpt-5.1-codex-max") == "GPT-5.1 Codex Max")
        #expect(EngineDisplay.model("gpt-4.1-nano") == "GPT-4.1 Nano")
    }

    /// A bare alias and the newest pinned version resolve to the same model
    /// today, so without a label the menu looks like it's repeating itself.
    /// They diverge when a new release ships.
    @Test("Version-tracking aliases are distinguishable from pinned ones")
    func latestAliasesAreLabelled() {
        for family in ["opus", "sonnet", "haiku", "fable"] {
            #expect(
                EngineDisplay.model(family).hasSuffix("(latest)"),
                "\(family) tracks new releases and should say so"
            )
        }
        // Pinned versions must not claim to track anything.
        #expect(!EngineDisplay.model("opus-5").contains("latest"))
        #expect(!EngineDisplay.model("haiku45").contains("latest"))
        #expect(!EngineDisplay.model("opusplan").contains("latest"))
    }

    @Test("Effort labels are presentable")
    func effortDisplayNames() {
        #expect(EngineDisplay.effort("max") == "Max")
        // Spelled out — "Xhigh" reads like a mistake.
        #expect(EngineDisplay.effort("xhigh") == "Extra High")
    }

    /// Grouping by family is what lets the menu be one list rather than two
    /// sections.
    @Test("Choices are grouped by family")
    func choicesGroupedByFamily() {
        let families = ClaudeEngine.modelChoices.map { choice -> String in
            for family in ["opus", "sonnet", "haiku", "fable"]
            where choice.hasPrefix(family) { return family }
            return choice
        }
        // Each family appears as one contiguous run.
        var seen: [String] = []
        for family in families where seen.last != family {
            #expect(!seen.contains(family), "\(family) is split across the list")
            seen.append(family)
        }
    }

    @Test("Unset values read as Default, not as an internal string")
    func displayDefaults() {
        #expect(EngineDisplay.model(nil) == "Default")
        #expect(EngineDisplay.model("") == "Default")
        #expect(EngineDisplay.model("account default") == "Default")
        #expect(EngineDisplay.effort(nil) == "Default")
    }

    /// Full ids are identifiers; reformatting one would make it look like a
    /// typo, and it still has to match what the CLI accepts. Aliases like
    /// `opus-4-8` are *not* ids and do get formatted.
    @Test("Full model ids are shown verbatim")
    func displayLeavesIdsAlone() {
        #expect(EngineDisplay.model("claude-haiku-4-5-20251001") == "claude-haiku-4-5-20251001")
        #expect(EngineDisplay.model("claude-opus-4-1-20250805") == "claude-opus-4-1-20250805")
    }

    /// The label must never be mistaken for the value: `--model Sonnet` is not
    /// what the CLI wants.
    @Test("Every offered choice keeps its canonical value")
    func choicesStayCanonical() {
        for choice in ClaudeEngine.modelChoices + CodexEngine.modelChoices {
            #expect(choice == choice.lowercased(), "\(choice) must stay as the CLI expects")
        }
        for choice in EngineRegistry.effortChoices(for: "codex") {
            #expect(choice == choice.lowercased())
        }
    }

    @Test("Both engines report something rather than crashing")
    func enginesReportAModel() {
        // Values depend on the machine's config; the contract is only that
        // asking is safe and never returns an empty string.
        for engine in EngineRegistry.all(config: .default) {
            if let model = engine.configuredModel {
                #expect(!model.isEmpty)
            }
        }
    }
}

@Suite("Claude tool descriptions")
struct ToolDescriptionTests {
    /// The journal used to record bare tool names, so a replacement agent read
    /// "it used Bash three times" — useless for continuing the work.
    @Test("A Bash call records the command, not just the tool name")
    func bashRecordsCommand() {
        let description = ClaudeEngine.describeToolUse(
            name: "Bash", input: ["command": "swift test --filter Routing"]
        )
        #expect(description == "Bash: swift test --filter Routing")
    }

    @Test("File tools record which file")
    func fileToolsRecordPath() {
        #expect(ClaudeEngine.describeToolUse(
            name: "Edit", input: ["file_path": "/Users/x/proj/Sources/App/Main.swift"]
        ) == "Edit: App/Main.swift")
        #expect(ClaudeEngine.describeToolUse(
            name: "Read", input: ["file_path": "README.md"]
        ) == "Read: README.md")
    }

    @Test("Bulk content is not copied into the journal")
    func omitsBulkContent() {
        let huge = String(repeating: "x", count: 5000)
        let description = ClaudeEngine.describeToolUse(
            name: "Edit", input: ["file_path": "a.swift", "old_string": huge, "new_string": huge]
        )
        #expect(description == "Edit: a.swift")
        #expect(description.count < 100)
    }

    @Test("Long commands are truncated")
    func truncatesLongCommands() {
        let description = ClaudeEngine.describeToolUse(
            name: "Bash", input: ["command": String(repeating: "echo hello; ", count: 50)]
        )
        #expect(description.count < 140)
        #expect(description.hasSuffix("…"))
    }

    @Test("Newlines are flattened so the journal stays one line per entry")
    func flattensNewlines() {
        let description = ClaudeEngine.describeToolUse(
            name: "Bash", input: ["command": "cd /tmp\nls -la\necho done"]
        )
        #expect(!description.contains("\n"))
    }

    @Test("Search tools record what was searched for")
    func searchTools() {
        #expect(ClaudeEngine.describeToolUse(
            name: "Grep", input: ["pattern": "TODO", "path": "src/app"]
        ).contains("TODO"))
        #expect(ClaudeEngine.describeToolUse(
            name: "WebSearch", input: ["query": "swift concurrency"]
        ) == "WebSearch: swift concurrency")
    }

    @Test("An unknown tool falls back to a common argument")
    func unknownToolFallback() {
        #expect(ClaudeEngine.describeToolUse(
            name: "SomeNewTool", input: ["file_path": "x/y/z.txt"]
        ) == "SomeNewTool: x/y/z.txt")
    }

    @Test("Missing input degrades to the tool name rather than crashing")
    func noInput() {
        #expect(ClaudeEngine.describeToolUse(name: "Bash", input: nil) == "Bash")
        #expect(ClaudeEngine.describeToolUse(name: "Bash", input: [:]) == "Bash")
    }

    @Test("End to end, a tool_use event carries its arguments")
    func parsesToolUseWithArguments() throws {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status --short"}}]}}"#
        guard case .action(let detail) = ClaudeEngine().parse(line: line) else {
            Issue.record("expected action")
            return
        }
        #expect(detail == "Bash: git status --short")
    }
}

/// The app and the CLI both record turns into the same per-directory file.
@Suite("Conversation across processes")
struct ConversationConcurrencyTests {
    private func scratchRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voxrouter-conv-\(UUID().uuidString)")
    }

    private func store(root: URL) -> ConversationStore {
        ConversationStore(
            workingDirectory: URL(fileURLWithPath: "/tmp/project"), root: root
        )
    }

    /// The store held its archive from process start and wrote it back whole,
    /// so a turn recorded by the CLI was invisible to the running app — and
    /// then overwritten by it.
    @Test("A turn recorded by another process isn't overwritten")
    func keepsOtherProcessesTurns() async {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let app = store(root: root)
        await app.record(
            task: "first", engineId: "claude", sessionId: "a", runId: "1",
            summary: nil, succeeded: true, now: now
        )

        // A separate process, as `voxrouter run` would be.
        let cli = store(root: root)
        await cli.record(
            task: "second", engineId: "claude", sessionId: "b", runId: "2",
            summary: nil, succeeded: true, now: now.addingTimeInterval(10)
        )

        // The app records again from what was, before the fix, a stale copy.
        await app.record(
            task: "third", engineId: "claude", sessionId: "c", runId: "3",
            summary: nil, succeeded: true, now: now.addingTimeInterval(20)
        )

        let tasks = await store(root: root).activeTurns(now: now.addingTimeInterval(21)).map(\.task)
        #expect(tasks == ["first", "second", "third"])
    }

    @Test("A read sees what another process just wrote")
    func readsAreFresh() async {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let reader = store(root: root)
        #expect(await reader.activeTurns(now: now).isEmpty)

        await store(root: root).record(
            task: "written elsewhere", engineId: "codex", sessionId: nil, runId: "1",
            summary: nil, succeeded: true, now: now
        )

        #expect(await reader.activeTurns(now: now).count == 1)
    }

    @Test("Concurrent writers all land")
    func concurrentWritersAllLand() async {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask { [self] in
                    await store(root: root).record(
                        task: "task \(index)", engineId: "claude", sessionId: nil,
                        runId: "\(index)", summary: nil, succeeded: true,
                        now: now.addingTimeInterval(Double(index))
                    )
                }
            }
        }

        let turns = await store(root: root).activeTurns(now: now.addingTimeInterval(11))
        #expect(turns.count == 10, "\(10 - turns.count) turns were lost")
    }
}
