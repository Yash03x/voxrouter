import Foundation

/// A tiny ring of the most recent output lines, kept so a non-zero exit can
/// report *why* rather than just the code. Bounded because an engine can emit
/// megabytes and only the tail matters for diagnosis.
struct RecentLines {
    private var lines: [String] = []
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    mutating func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append(trimmed)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }

    func joined() -> String { lines.joined(separator: " / ") }
}

/// What the caller (menu bar, CLI, voice layer) sees while a task runs.
public enum DispatchUpdate: Sendable {
    case routed(engine: String, reason: String)
    case action(engine: String, detail: String)
    case text(engine: String, detail: String)
    /// A failover is happening. The task continues on `to`.
    case handoff(from: String, to: String, reason: String)
    case succeeded(engine: String, summary: String?)
    case failed(reason: String)
    /// Every engine is out of quota; nothing more can be attempted.
    case blocked(retryAfter: Date?)
}

public struct DispatchResult: Sendable {
    public let runId: String
    public let journalDirectory: URL
    public let engineHistory: [String]
    public let succeeded: Bool
    public let summary: String?
}

/// How an engine's process gets started. Injectable so failover can be tested
/// against scripted engine output instead of burning real quota to provoke a
/// real rate limit.
public struct EngineLauncher: Sendable {
    let launch: @Sendable (URL, [String], URL) -> AsyncStream<ProcessLine>

    public init(launch: @escaping @Sendable (URL, [String], URL) -> AsyncStream<ProcessLine>) {
        self.launch = launch
    }

    public static let process = EngineLauncher { binary, arguments, workingDirectory in
        ProcessRunner.stream(
            executable: binary,
            arguments: arguments,
            workingDirectory: workingDirectory
        )
    }
}

/// Runs one task to completion, moving it between engines as quota requires.
public actor Dispatcher {
    private let config: Config
    private let router: EngineRouter
    private let engines: [any Engine]
    private let launcher: EngineLauncher
    /// Guard against a pathological loop where engines keep bouncing a task.
    private let maxAttempts: Int

    /// Nil disables conversation memory (each task stands alone).
    private let conversation: ConversationStore?

    public init(
        config: Config,
        router: EngineRouter,
        engines: [any Engine]? = nil,
        launcher: EngineLauncher = .process,
        conversation: ConversationStore? = nil,
        maxAttempts: Int = 4
    ) {
        self.config = config
        self.router = router
        self.engines = engines ?? EngineRegistry.all(config: config)
        self.launcher = launcher
        self.conversation = conversation
        self.maxAttempts = maxAttempts
    }

    public func run(
        task: String,
        onUpdate: @escaping @Sendable (DispatchUpdate) -> Void
    ) async throws -> DispatchResult {
        let workingDirectory = URL(fileURLWithPath: config.effectiveWorkingDirectory)
        let journal = try RunJournal(task: task, workingDirectory: workingDirectory)

        // Captured before the engine touches anything. With approval prompts
        // disabled a misheard instruction changes files immediately, so the
        // point has to exist beforehand rather than be wished for afterwards.
        let recovery = GitRecovery.capture(in: workingDirectory, runId: journal.runId)
        if let recovery {
            let extra = recovery.hadUncommittedChanges ? " (+ uncommitted changes)" : ""
            Log.dispatch.notice(
                "recovery point at \(recovery.shortHead, privacy: .public)\(extra, privacy: .public)"
            )
        }

        var prompt = task
        var attempt = 0
        var lastEngine: String?
        var summary: String?

        while attempt < maxAttempts {
            attempt += 1
            // Derived from this dispatcher's own engine list, not the global
            // registry, so an injected set is actually honoured.
            let installed = Set(engines.filter(\.isInstalled).map(\.id))

            let outcome: RoutingOutcome
            if let failed = lastEngine {
                outcome = await router.handleRateLimit(engineId: failed, installed: installed)
            } else {
                outcome = await router.decide(installed: installed)
            }

            let decision: RoutingDecision
            switch outcome {
            case .dispatch(let d):
                decision = d
            case .exhausted(let retryAfter):
                onUpdate(.blocked(retryAfter: retryAfter))
                try await journal.finish(outcome: "blocked — all engines out of quota")
                return DispatchResult(
                    runId: journal.runId,
                    journalDirectory: journal.directory,
                    engineHistory: await journal.currentManifest().engineHistory,
                    succeeded: false,
                    summary: nil
                )
            case .noEnginesAvailable:
                let missing = engines.map { "\($0.displayName): \($0.installHint)" }
                    .joined(separator: "; ")
                onUpdate(.failed(reason: "no engines installed — \(missing)"))
                try await journal.finish(outcome: "no engines installed")
                return DispatchResult(
                    runId: journal.runId,
                    journalDirectory: journal.directory,
                    engineHistory: [],
                    succeeded: false,
                    summary: nil
                )
            }

            guard let engine = engines.first(where: { $0.id == decision.engineId }),
                  let binary = engine.binaryPath else {
                onUpdate(.failed(reason: "engine \(decision.engineId) vanished between routing and launch"))
                try await journal.finish(outcome: "engine unavailable")
                break
            }

            var resumeSessionId: String?

            if let previous = lastEngine {
                onUpdate(.handoff(from: previous, to: engine.id, reason: decision.reason))
                // Hand over the journal, not the raw task: the replacement must
                // know what has already been done.
                prompt = await journal.continuationPrompt()
            } else {
                onUpdate(.routed(engine: engine.id, reason: decision.reason))

                // First attempt: carry over the previous conversation turn, so
                // "now fix those failures" resolves to something.
                switch await conversation?.continuity(for: engine.id) ?? .fresh {
                case .fresh:
                    break
                case .resumeSession(_, let sessionId):
                    // Same engine — resume its own session. Full fidelity, and
                    // far cheaper than restating history in the prompt.
                    resumeSessionId = sessionId
                case .preamble(let digest):
                    prompt = "\(digest)\n\n## New request\n\(task)"
                }
            }

            try await journal.beginEngine(engine.id, reason: decision.reason)

            let attemptOutcome = await execute(
                engine: engine,
                binary: binary,
                prompt: prompt,
                resuming: resumeSessionId,
                workingDirectory: workingDirectory,
                journal: journal,
                onUpdate: onUpdate
            )

            switch attemptOutcome {
            case .succeeded(let text):
                summary = text
                onUpdate(.succeeded(engine: engine.id, summary: text))
                try await journal.finish(outcome: "succeeded on \(engine.id)")
                await conversation?.record(
                    task: task,
                    engineId: engine.id,
                    sessionId: await journal.sessionId(for: engine.id),
                    runId: journal.runId,
                    summary: text,
                    succeeded: true,
                    recovery: recovery
                )
                return DispatchResult(
                    runId: journal.runId,
                    journalDirectory: journal.directory,
                    engineHistory: await journal.currentManifest().engineHistory,
                    succeeded: true,
                    summary: summary
                )

            case .rateLimited:
                // Loop: routing will sideline this engine and pick another.
                lastEngine = engine.id
                continue

            case .unavailable(let reason):
                // Same handling as a rate limit — sideline and move on. The
                // user shouldn't be blocked because one CLI needs a re-login
                // when the other engine is ready to work.
                onUpdate(.text(engine: engine.id, detail: "unavailable: \(reason)"))
                lastEngine = engine.id
                continue

            case .failed(let reason):
                // A genuine task failure is not a quota problem — retrying on
                // another engine would just fail again, more slowly.
                onUpdate(.failed(reason: reason))
                try await journal.finish(outcome: "failed on \(engine.id): \(reason)")
                return DispatchResult(
                    runId: journal.runId,
                    journalDirectory: journal.directory,
                    engineHistory: await journal.currentManifest().engineHistory,
                    succeeded: false,
                    summary: nil
                )
            }
        }

        onUpdate(.failed(reason: "gave up after \(maxAttempts) attempts"))
        try await journal.finish(outcome: "exhausted attempts")
        return DispatchResult(
            runId: journal.runId,
            journalDirectory: journal.directory,
            engineHistory: await journal.currentManifest().engineHistory,
            succeeded: false,
            summary: summary
        )
    }

    // MARK: - One engine attempt

    private enum AttemptOutcome {
        case succeeded(String?)
        case rateLimited
        /// The engine itself can't run. Fails over like a rate limit, because
        /// the other engine can still do the job.
        case unavailable(String)
        case failed(String)
    }

    private func execute(
        engine: any Engine,
        binary: URL,
        prompt: String,
        resuming sessionId: String?,
        workingDirectory: URL,
        journal: RunJournal,
        onUpdate: @escaping @Sendable (DispatchUpdate) -> Void
    ) async -> AttemptOutcome {
        let stream = launcher.launch(
            binary,
            engine.arguments(for: prompt, resuming: sessionId),
            workingDirectory
        )

        var lastText: String?
        var failure: String?
        var sawRateLimit = false
        var unavailableReason: String?
        // Engines report some failures as plain text, not protocol JSON — e.g.
        // codex refusing to run outside a trusted git directory. Without this,
        // any such error surfaces as a bare "exited 1" with no cause.
        var recentOutput = RecentLines(capacity: 5)

        for await line in stream {
            switch line {
            case .exited(let code):
                if sawRateLimit { return .rateLimited }
                if let unavailableReason { return .unavailable(unavailableReason) }
                if let failure { return .failed(failure) }
                if code != 0 {
                    let context = recentOutput.joined()
                    return .failed(
                        context.isEmpty
                            ? "\(engine.displayName) exited \(code)"
                            : "\(engine.displayName) exited \(code): \(context)"
                    )
                }
                return .succeeded(lastText)

            case .stdout(let text), .stderr(let text):
                let event = engine.parse(line: text)

                // Claude reports its closing message twice — once streamed as an
                // assistant block, once in the final `result`. Drop the repeat
                // before journalling, or a handoff prompt carries it twice.
                if case .text(let detail) = event, detail == lastText {
                    continue
                }

                try? await journal.record(engine: engine.id, event: event)

                switch event {
                case .rateLimited(let detail, let retryAfter):
                    // Don't return yet — let the process wind down so the
                    // journal captures whatever it managed to finish.
                    sawRateLimit = true
                    Log.dispatch.notice(
                        "\(engine.id, privacy: .public) rate limited: \(detail, privacy: .public)"
                    )
                    if let retryAfter {
                        Log.dispatch.notice("retry after \(retryAfter, privacy: .public)")
                    }
                case .unavailable(let reason):
                    // Don't return yet — let the process finish so the journal
                    // captures everything it managed to say.
                    unavailableReason = reason
                    Log.dispatch.notice(
                        "\(engine.id, privacy: .public) unavailable: \(reason, privacy: .public)"
                    )
                case .failed(let reason):
                    failure = reason
                case .action(let detail):
                    onUpdate(.action(engine: engine.id, detail: detail))
                case .text(let detail):
                    lastText = detail
                    onUpdate(.text(engine: engine.id, detail: detail))
                case .raw(let detail):
                    recentOutput.append(detail)
                case .session, .status, .finished:
                    break
                }
            }
        }

        if sawRateLimit { return .rateLimited }
        if let unavailableReason { return .unavailable(unavailableReason) }
        if let failure { return .failed(failure) }
        return .succeeded(lastText)
    }
}
