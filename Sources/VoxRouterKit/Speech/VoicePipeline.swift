import Foundation

/// Joins the two halves: captured audio → text → dispatched task.
///
/// Kept in the library rather than the CLI so the menu-bar app can reuse it
/// unchanged.
public actor VoicePipeline {
    private var config: Config
    private let transcriber: any Transcriber
    private let speaker: any Speaker
    private let dryRun: Bool
    private let monitor: QuotaMonitor
    private let router: EngineRouter
    private let emit: @Sendable (String) -> Void

    public init(
        config: Config,
        transcriber: any Transcriber,
        speaker: any Speaker = SilentSpeaker(),
        dryRun: Bool = false,
        emit: @escaping @Sendable (String) -> Void = { line in
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
    ) {
        self.config = config
        self.transcriber = transcriber
        self.speaker = speaker
        self.dryRun = dryRun
        self.emit = emit
        let client = QuotaClient(baseURL: config.openUsageBaseURL)
        self.monitor = QuotaMonitor(client: client, interval: config.quotaRefreshInterval)
        self.router = EngineRouter(policy: config.routing, monitor: monitor)
        self.conversation = ConversationStore(
            workingDirectory: URL(fileURLWithPath: config.effectiveWorkingDirectory),
            timeout: config.conversationTimeout
        )
        self.conversationDirectory = config.effectiveWorkingDirectory
    }

    /// Re-pointed when the project changes, so history follows the directory.
    private var conversation: ConversationStore
    /// Which directory conversation memory is currently keyed to. Exposed so a
    /// test can assert the store actually moved with the project.
    private(set) var conversationDirectory: String

    var currentConversationDirectory: String { conversationDirectory }

    /// Spoken phrases that clear the conversation. Without an explicit way to
    /// say "forget that", an unrelated new request inherits stale context.
    static let resetPhrases = [
        "start over", "new task", "forget that", "never mind", "nevermind",
        "clear that", "fresh start",
    ]

    static func isResetCommand(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
        // Only when that's the whole utterance — "start over from the top" is a
        // task, not a reset.
        return resetPhrases.contains(normalized)
    }

    /// Starts background quota polling, so the first command doesn't wait on an
    /// HTTP round trip before it can be routed.
    public func start() async {
        await monitor.start()
    }

    /// Applies a settings change (e.g. a model switch) to subsequent dispatches
    /// without restarting the app.
    public func updateConfig(_ newConfig: Config) {
        let previousDirectory = config.effectiveWorkingDirectory
        config = newConfig

        // Conversation memory is keyed by directory, so a project switch made
        // from the menu (rather than by voice) has to re-point the store too.
        // Without this the next task runs in the new project while reading and
        // writing the old project's history.
        if newConfig.effectiveWorkingDirectory != previousDirectory {
            conversation = ConversationStore(
                workingDirectory: URL(fileURLWithPath: newConfig.effectiveWorkingDirectory),
                timeout: newConfig.conversationTimeout
            )
            conversationDirectory = newConfig.effectiveWorkingDirectory
        }
    }

    /// Mutes or unmutes spoken replies for subsequent updates.
    ///
    /// Needs to live here rather than in the UI: the pipeline decides what gets
    /// spoken, so a flag held only by the app silences the current utterance and
    /// nothing after it.
    public func setSpeechEnabled(_ enabled: Bool) {
        speechMuted = !enabled
        if !enabled { speaker.stop() }
    }

    private var speechMuted = false

    /// Single point where speech is suppressed, so every call site honours the
    /// mute without having to remember to check.
    private func say(_ text: String) async {
        guard !speechMuted else { return }
        await speaker.speak(text)
    }

    /// Silences any in-progress speech. Call the moment the user starts talking
    /// — an assistant that talks over you is worse than one that says nothing.
    public nonisolated func bargeIn() {
        speaker.stop()
    }

    public func handle(_ clip: PushToTalkClip) async {
        let transcript: Transcript
        do {
            transcript = try await transcriber.transcribe(samples: clip.samples)
        } catch {
            emit("  ✗ transcription failed: \(error.localizedDescription)")
            await say("Sorry, I couldn't make that out.")
            return
        }

        guard !transcript.isEmpty else {
            emit("  (heard nothing)")
            return
        }

        emit("  “\(transcript.text)”")

        // A pending confirmation takes priority over everything: the next thing
        // said is an answer, not a new request.
        if let pending = pendingUndo {
            pendingUndo = nil
            switch DestructiveIntent.interpretReply(transcript.text) {
            case .affirm:
                await performUndo(pending)
            case .decline, .unclear:
                emit("  cancelled")
                await say("Left it as it is.")
            }
            return
        }

        if let pending = pendingConfirmation {
            pendingConfirmation = nil
            switch DestructiveIntent.interpretReply(transcript.text) {
            case .affirm:
                emit("  confirmed")
                await dispatch(task: pending.task)
            case .decline, .unclear:
                emit("  cancelled")
                await say("Cancelled.")
            }
            return
        }

        if Self.isUndoCommand(transcript.text) {
            await handleUndo()
            return
        }

        // Switching project before anything else: the rest of this turn should
        // be interpreted against the new scope.
        if let spoken = ProjectCommand.parse(transcript.text) {
            await switchProject(named: spoken)
            return
        }

        if Self.isResetCommand(transcript.text) {
            await conversation.reset()
            emit("  (conversation cleared)")
            await say("Starting fresh.")
            return
        }

        guard !dryRun else {
            let installed = EngineRegistry.installedIds(config: config)
            switch await router.decide(installed: installed) {
            case .dispatch(let decision):
                emit("  → would dispatch to \(decision.engineId): \(decision.reason)")
            case .exhausted(let retryAfter):
                let when = retryAfter.map { "\($0)" } ?? "unknown"
                emit("  → all engines out of quota until \(when)")
            case .noEnginesAvailable:
                emit("  → no engines installed")
            }
            return
        }

        // Speech recognition mishears, and with approval prompts disabled the
        // engine acts immediately and irreversibly. This is the only gate
        // between a mishearing and something unrecoverable.
        if let risk = DestructiveIntent.assess(transcript.text) {
            pendingConfirmation = Pending(task: transcript.text, at: Date())
            emit("  ⚠︎ needs confirmation: \(risk.reason)")
            await say(
                "That would \(risk.reason). Hold the key and say yes to confirm."
            )
            return
        }

        await dispatch(task: transcript.text)
    }

    struct Pending: Sendable {
        let task: String
        let at: Date
    }

    private var pendingConfirmation: Pending? {
        didSet {
            // A stale confirmation is dangerous: answering "yes" to something
            // else minutes later must not run a forgotten destructive task.
            guard pendingConfirmation != nil else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                await self?.expireConfirmation()
            }
        }
    }

    private func expireConfirmation() {
        guard let pending = pendingConfirmation,
              Date().timeIntervalSince(pending.at) >= 60 else { return }
        pendingConfirmation = nil
        emit("  (confirmation timed out)")
    }

    /// Exposed for the UI: something is waiting on a yes/no.
    public var awaitingConfirmation: Bool { pendingConfirmation != nil }

    /// Called when the project changes, so the app can update and re-point its
    /// conversation store.
    public var onProjectChange: (@Sendable (Project) -> Void)?

    public func setProjectChangeHandler(_ handler: @escaping @Sendable (Project) -> Void) {
        onProjectChange = handler
    }

    /// Phrases that mean "put it back how it was".
    ///
    /// Matched as a whole utterance only — "undo that change to the parser" is a
    /// task for the engine, not a request to reset the repository.
    static let undoPhrases = [
        "undo that", "undo it", "undo", "revert that", "revert it",
        "roll that back", "roll it back", "put it back", "take that back",
    ]

    static func isUndoCommand(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
        return undoPhrases.contains(normalized)
    }

    private func handleUndo() async {
        guard let turn = await conversation.mostRecentRecoverable(),
              let point = turn.recovery else {
            emit("  nothing to undo")
            await say("I don't have anything to undo.")
            return
        }

        // Undo throws away whatever the agent did, so it goes through the same
        // gate as any other destructive request.
        pendingUndo = point
        let changes = point.hadUncommittedChanges ? ", including your uncommitted changes" : ""
        emit("  ⚠︎ undo would reset to \(point.shortHead)\(changes) — “\(turn.task)”")
        await say(
            "That would undo \(SpokenNarration.speakable(turn.task, maxCharacters: 80)) "
            + "and reset to commit \(point.shortHead). Say yes to confirm."
        )
    }

    private var pendingUndo: RecoveryPoint?

    private func performUndo(_ point: RecoveryPoint) async {
        do {
            let result = try GitRecovery.restore(point)
            var line = "  ↩︎ reset to \(point.shortHead)"
            if result.restoredUncommitted { line += " and restored your uncommitted changes" }
            if let undoneRef = result.undoneRef {
                // The undone work is recoverable — an undo you can't reverse is
                // just a different way to lose work.
                line += "\n  (undone work kept at \(undoneRef))"
            }
            emit(line)
            await say("Undone. Back at commit \(point.shortHead).")
        } catch {
            emit("  ✗ undo failed: \(error.localizedDescription)")
            await say("I couldn't undo that.")
        }
    }

    private func switchProject(named spoken: String) async {
        guard let match = config.resolvedProjects.first(where: { $0.matches(spoken: spoken) }) else {
            let names = config.resolvedProjects.map(\.name).joined(separator: ", ")
            emit("  no project matching “\(spoken)” — have: \(names)")
            await say("I don't have a project called \(spoken).")
            return
        }

        guard match.exists else {
            emit("  \(match.name) no longer exists at \(match.path)")
            await say("\(match.name) isn't there any more.")
            return
        }

        config.activeProjectID = match.id
        try? config.write()
        // Conversation memory is per-directory, so this also swaps history.
        conversation = ConversationStore(
            workingDirectory: match.url,
            timeout: config.conversationTimeout
        )
        conversationDirectory = match.path
        onProjectChange?(match)

        emit("  → project: \(match.name) (\(match.path))")
        if match.isAnywhere {
            await say("Working anywhere. Nothing is scoped now.")
        } else {
            await say("Switched to \(match.name).")
        }
    }

    private func dispatch(task: String) async {
        let dispatcher = Dispatcher(config: config, router: router, conversation: conversation)
        let emit = self.emit

        // Updates arrive from the dispatcher's own context while the run is in
        // flight, so speech is fired off rather than awaited — blocking the
        // dispatch loop on the audio device would stall the actual work.
        //
        // Routed back through the actor rather than capturing the speaker, so a
        // mute toggled *during* a run takes effect for the rest of it.
        let verbosity = config.speechVerbosity
        let narrate: @Sendable (DispatchUpdate) -> Void = { [weak self] update in
            guard let line = SpokenNarration.line(for: update, verbosity: verbosity) else { return }
            Task { await self?.say(line) }
        }

        do {
            let result = try await dispatcher.run(task: task) { update in
                narrate(update)
                switch update {
                case .routed(let engine, let reason):
                    emit("  → \(engine): \(reason)")
                case .action(let engine, let detail):
                    emit("    [\(engine)] \(detail)")
                case .text(_, let detail):
                    emit("    \(detail)")
                case .handoff(let from, let to, let reason):
                    emit("  ⇄ \(from) → \(to): \(reason)")
                case .succeeded(let engine, _):
                    emit("  ✓ done on \(engine)")
                case .failed(let reason):
                    emit("  ✗ \(reason)")
                case .blocked(let retryAfter):
                    let when = retryAfter.map { "\($0)" } ?? "unknown"
                    emit("  ⏸ all engines out of quota; earliest reset \(when)")
                }
            }
            emit("  journal: \(result.journalDirectory.path)")
        } catch {
            emit("  ✗ dispatch failed: \(error.localizedDescription)")
            await say("The task failed to start.")
        }
    }
}
