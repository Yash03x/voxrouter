import Foundation
import Testing
@testable import VoxRouterKit

// MARK: - Test doubles

/// An engine whose output is scripted. `arguments(for:)` passes the prompt
/// through verbatim as argv[0] so tests can assert on exactly what the engine
/// was asked to do — which is how the handoff contract gets verified.
private struct FakeEngine: Engine {
    let id: String
    let displayName: String
    let installHint = "n/a"
    let configuredModel: String? = "fake-model"
    var binaryPath: URL? { URL(fileURLWithPath: "/usr/bin/true") }

    func arguments(for task: String, resuming sessionId: String?) -> [String] { [task] }

    func parse(line: String) -> EngineEvent {
        // Deliberately reuses the real classifier so the test exercises
        // production detection rather than a test-only shortcut.
        if let classified = RateLimitSniffer.classify(line) { return classified }
        if line.hasPrefix("ACTION ") { return .action(String(line.dropFirst(7))) }
        if line.hasPrefix("TEXT ") { return .text(String(line.dropFirst(5))) }
        if line.hasPrefix("FAIL ") { return .failed(String(line.dropFirst(5))) }
        return .raw(line)
    }
}

/// Records every prompt each engine was launched with, and replays scripted
/// output for it.
private final class LaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [String] = []
    /// binary path is identical across fakes, so scripts are keyed by call order.
    private var scripts: [[String]]
    private var exitCodes: [Int32]

    init(scripts: [[String]], exitCodes: [Int32]) {
        self.scripts = scripts
        self.exitCodes = exitCodes
    }

    var recordedPrompts: [String] {
        lock.lock(); defer { lock.unlock() }
        return prompts
    }

    func launcher() -> EngineLauncher {
        EngineLauncher { [self] _, arguments, _ in
            lock.lock()
            let index = prompts.count
            prompts.append(arguments.first ?? "")
            let script = index < scripts.count ? scripts[index] : []
            let code = index < exitCodes.count ? exitCodes[index] : 0
            lock.unlock()

            return AsyncStream { continuation in
                for line in script { continuation.yield(.stdout(line)) }
                continuation.yield(.exited(code))
                continuation.finish()
            }
        }
    }
}

private func makeRouter(claude: Double, codex: Double) async throws -> EngineRouter {
    let json = """
    [{"providerId":"claude","lines":[{"limit":100,"type":"progress","label":"Weekly",
      "used":\(claude),"format":{"kind":"percent"},"resetsAt":"2026-08-05T06:26:45.000Z"}]},
     {"providerId":"codex","lines":[{"limit":100,"type":"progress","label":"Weekly",
      "used":\(codex),"format":{"kind":"percent"},"resetsAt":"2026-08-05T06:26:45.000Z"}]}]
    """
    let snapshot = QuotaSnapshot(
        providers: try JSONDecoder.openUsage().decode([ProviderUsage].self, from: Data(json.utf8))
    )
    let monitor = QuotaMonitor { snapshot }
    _ = try await monitor.refresh()
    return EngineRouter(policy: RoutingPolicy(), monitor: monitor)
}

private func testConfig() -> Config {
    var config = Config.default
    config.workingDirectory = FileManager.default.temporaryDirectory.path
    return config
}

/// Journals go to a throwaway root so tests never touch real run history.
private func scratchRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("voxrouter-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

// MARK: - Tests

@Suite("Failover and handoff")
struct FailoverTests {
    private let claude = FakeEngine(id: "claude", displayName: "Claude Code")
    private let codex = FakeEngine(id: "codex", displayName: "Codex")

    /// The headline requirement: a task that dies on one engine finishes on the
    /// other, without the user re-issuing it.
    @Test("A rate-limited engine hands the task to the other and it completes")
    func handsOffAndCompletes() async throws {
        let recorder = LaunchRecorder(
            scripts: [
                ["ACTION Read src/main.swift", "You have hit your usage limit."],
                ["ACTION Edit src/main.swift", "TEXT Fixed the parser."],
            ],
            exitCodes: [1, 0]
        )
        let dispatcher = Dispatcher(
            config: testConfig(),
            router: try await makeRouter(claude: 10, codex: 20),
            engines: [claude, codex],
            launcher: recorder.launcher()
        )

        let updates = UpdateLog()
        let result = try await dispatcher.run(task: "fix the parser") { updates.append($0) }

        #expect(result.succeeded)
        #expect(result.engineHistory == ["claude", "codex"])
        #expect(result.summary == "Fixed the parser.")
        #expect(updates.handoffs.count == 1)
        #expect(updates.handoffs.first?.from == "claude")
        #expect(updates.handoffs.first?.to == "codex")
    }

    /// The handoff is only meaningful if the replacement is told what already
    /// happened — otherwise it silently redoes or corrupts partial work.
    @Test("The replacement engine receives the original task plus prior progress")
    func handoffCarriesContext() async throws {
        let recorder = LaunchRecorder(
            scripts: [
                ["ACTION Read config.swift", "TEXT Halfway done.", "rate limit exceeded"],
                ["TEXT Finished."],
            ],
            exitCodes: [1, 0]
        )
        let dispatcher = Dispatcher(
            config: testConfig(),
            router: try await makeRouter(claude: 10, codex: 20),
            engines: [claude, codex],
            launcher: recorder.launcher()
        )

        _ = try await dispatcher.run(task: "refactor the config loader") { _ in }

        let prompts = recorder.recordedPrompts
        #expect(prompts.count == 2)
        // First engine gets the bare task.
        #expect(prompts[0] == "refactor the config loader")

        // Second gets the task restated plus what the first actually did.
        let handoff = prompts[1]
        #expect(handoff.contains("refactor the config loader"))
        #expect(handoff.contains("Read config.swift"), "prior actions must carry over")
        #expect(handoff.contains("Halfway done."), "prior findings must carry over")
        #expect(handoff.lowercased().contains("resuming"))
        // Guards against the replacement trusting a stale log over the filesystem.
        #expect(handoff.contains("inspect the"))
    }

    /// A broken build is not a quota problem. Retrying it elsewhere just burns
    /// the other engine's quota to fail again.
    @Test("A genuine task failure does not trigger failover")
    func realFailureDoesNotFailOver() async throws {
        let recorder = LaunchRecorder(
            scripts: [["FAIL compile error in main.swift"]],
            exitCodes: [1]
        )
        let dispatcher = Dispatcher(
            config: testConfig(),
            router: try await makeRouter(claude: 10, codex: 20),
            engines: [claude, codex],
            launcher: recorder.launcher()
        )

        let updates = UpdateLog()
        let result = try await dispatcher.run(task: "build it") { updates.append($0) }

        #expect(!result.succeeded)
        #expect(result.engineHistory == ["claude"], "must not spend the other engine's quota")
        #expect(updates.handoffs.isEmpty)
    }

    /// Found live: `claude` was installed but its OAuth session had expired, so
    /// it printed "Failed to authenticate" and exited 1. That was being treated
    /// as a task failure, which meant no failover — leaving the user blocked
    /// while a perfectly healthy Codex sat idle.
    @Test("An engine that can't authenticate hands off instead of failing")
    func unauthenticatedEngineFailsOver() async throws {
        let recorder = LaunchRecorder(
            scripts: [
                ["Failed to authenticate: OAuth session expired and could not be refreshed"],
                ["TEXT The tree is clean."],
            ],
            exitCodes: [1, 0]
        )
        let dispatcher = Dispatcher(
            config: testConfig(),
            router: try await makeRouter(claude: 5, codex: 50),
            engines: [claude, codex],
            launcher: recorder.launcher()
        )

        let updates = UpdateLog()
        let result = try await dispatcher.run(task: "check the tree") { updates.append($0) }

        #expect(result.succeeded, "the healthy engine should have finished the job")
        #expect(result.engineHistory == ["claude", "codex"])
        #expect(updates.handoffs.count == 1)
    }

    @Test("Other auth phrasings also trigger failover")
    func variousAuthFailures() async throws {
        for phrasing in ["Not logged in.", "401 Unauthorized", "Invalid API key provided"] {
            let recorder = LaunchRecorder(
                scripts: [[phrasing], ["TEXT done"]],
                exitCodes: [1, 0]
            )
            let dispatcher = Dispatcher(
                config: testConfig(),
                router: try await makeRouter(claude: 5, codex: 50),
                engines: [claude, codex],
                launcher: recorder.launcher()
            )
            let result = try await dispatcher.run(task: "t") { _ in }
            #expect(result.engineHistory == ["claude", "codex"], "failed for: \(phrasing)")
        }
    }

    /// The distinction that makes this safe: a broken build is not an unusable
    /// engine, and must still not be retried elsewhere.
    @Test("A task failure is still not confused with an unusable engine")
    func taskFailureStillDoesNotFailOver() async throws {
        let recorder = LaunchRecorder(
            scripts: [["FAIL syntax error at line 12"]],
            exitCodes: [1]
        )
        let dispatcher = Dispatcher(
            config: testConfig(),
            router: try await makeRouter(claude: 5, codex: 50),
            engines: [claude, codex],
            launcher: recorder.launcher()
        )
        let result = try await dispatcher.run(task: "build") { _ in }
        #expect(result.engineHistory == ["claude"])
    }

    @Test("When both engines are rate limited the run reports blocked, not failed")
    func bothExhausted() async throws {
        let recorder = LaunchRecorder(
            scripts: [
                ["usage limit reached"],
                ["usage limit reached"],
            ],
            exitCodes: [1, 1]
        )
        let dispatcher = Dispatcher(
            config: testConfig(),
            router: try await makeRouter(claude: 10, codex: 20),
            engines: [claude, codex],
            launcher: recorder.launcher()
        )

        let updates = UpdateLog()
        let result = try await dispatcher.run(task: "do the thing") { updates.append($0) }

        #expect(!result.succeeded)
        #expect(updates.blockedCount == 1, "the user should be told to wait, not that it broke")
    }

    @Test("Handoff loops are bounded")
    func boundedAttempts() async throws {
        let recorder = LaunchRecorder(
            scripts: Array(repeating: ["rate limit"], count: 10),
            exitCodes: Array(repeating: 1, count: 10)
        )
        let dispatcher = Dispatcher(
            config: testConfig(),
            router: try await makeRouter(claude: 10, codex: 20),
            engines: [claude, codex],
            launcher: recorder.launcher(),
            maxAttempts: 3
        )

        _ = try await dispatcher.run(task: "spin") { _ in }
        #expect(recorder.recordedPrompts.count <= 3)
    }

    @Test("A successful run needs no handoff and records one engine")
    func happyPath() async throws {
        let recorder = LaunchRecorder(
            scripts: [["ACTION Edit a.swift", "TEXT Done."]],
            exitCodes: [0]
        )
        let dispatcher = Dispatcher(
            config: testConfig(),
            router: try await makeRouter(claude: 5, codex: 5),
            engines: [claude, codex],
            launcher: recorder.launcher()
        )

        let updates = UpdateLog()
        let result = try await dispatcher.run(task: "tidy up") { updates.append($0) }

        #expect(result.succeeded)
        #expect(result.engineHistory == ["claude"])
        #expect(updates.handoffs.isEmpty)
        #expect(result.summary == "Done.")
    }
}

@Suite("Run journal")
struct RunJournalTests {
    @Test("A fresh journal writes a readable record immediately")
    func writesOnCreation() async throws {
        let root = try scratchRoot()
        let journal = try RunJournal(
            task: "do a thing",
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            root: root
        )
        let markdown = try String(
            contentsOf: journal.directory.appendingPathComponent("journal.md"), encoding: .utf8
        )
        #expect(markdown.contains("do a thing"))
        #expect(FileManager.default.fileExists(
            atPath: journal.directory.appendingPathComponent("manifest.json").path
        ))
    }

    @Test("Run ids are filesystem-safe regardless of locale")
    func runIdIsPathSafe() async throws {
        let root = try scratchRoot()
        let journal = try RunJournal(
            task: "t", workingDirectory: URL(fileURLWithPath: "/tmp"), root: root
        )
        #expect(!journal.runId.contains(" "), "a space in the run id breaks path handling")
        #expect(!journal.runId.contains("/"))
        #expect(!journal.runId.lowercased().contains("am"))
        #expect(!journal.runId.lowercased().contains("pm"))
    }

    @Test("Protocol chatter is excluded so a resuming engine sees only signal")
    func rawEventsAreNotJournalled() async throws {
        let root = try scratchRoot()
        let journal = try RunJournal(
            task: "t", workingDirectory: URL(fileURLWithPath: "/tmp"), root: root
        )
        try await journal.record(engine: "codex", event: .raw("{\"noise\":true}"))
        try await journal.record(engine: "codex", event: .action("swift build"))

        let prompt = await journal.continuationPrompt()
        #expect(prompt.contains("swift build"))
        #expect(!prompt.contains("noise"))
    }

    @Test("An empty journal still yields a usable prompt")
    func emptyJournalDegradesGracefully() async throws {
        let root = try scratchRoot()
        let journal = try RunJournal(
            task: "build the thing", workingDirectory: URL(fileURLWithPath: "/tmp"), root: root
        )
        let prompt = await journal.continuationPrompt()
        #expect(prompt.contains("build the thing"))
        #expect(prompt.contains("fresh start"))
    }

    @Test("Session ids are tracked per engine for same-engine resume")
    func tracksSessionIds() async throws {
        let root = try scratchRoot()
        let journal = try RunJournal(
            task: "t", workingDirectory: URL(fileURLWithPath: "/tmp"), root: root
        )
        try await journal.record(engine: "codex", event: .session("thread-1"))
        try await journal.record(engine: "claude", event: .session("session-2"))
        #expect(await journal.sessionId(for: "codex") == "thread-1")
        #expect(await journal.sessionId(for: "claude") == "session-2")
    }
}

// MARK: - Helpers

private final class UpdateLog: @unchecked Sendable {
    struct Handoff { let from: String; let to: String }

    private let lock = NSLock()
    private var storage: [DispatchUpdate] = []

    func append(_ update: DispatchUpdate) {
        lock.lock(); storage.append(update); lock.unlock()
    }

    private var all: [DispatchUpdate] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    var handoffs: [Handoff] {
        all.compactMap {
            if case .handoff(let from, let to, _) = $0 { return Handoff(from: from, to: to) }
            return nil
        }
    }

    var blockedCount: Int {
        all.filter { if case .blocked = $0 { return true } else { return false } }.count
    }
}
