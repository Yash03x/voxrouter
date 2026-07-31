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
    /// The fast-answer tier: a local Ollama server behind the
    /// `QuickAnswerer` seam. Built once here rather than per utterance, but
    /// nothing about availability is baked in: whether the backend is
    /// actually *there* is its own per-question business — absence comes
    /// back as a fast `.unavailable` the chain skips past, so stopping
    /// Ollama mid-session routes the next question correctly with no state
    /// held here to go stale.
    private var quickAnswerer: any QuickAnswerer

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
        self.quickAnswerer = ChainedAnswerer.standard(config: config)
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

    /// Test seam: swaps in a conversation store rooted somewhere disposable.
    ///
    /// The store this actor builds for itself lives under the real state
    /// directory, and the fast-tier gate reads history through it — so
    /// without this seam a test of the gate's input would read whatever the
    /// person running the suite last said to their own assistant, and could
    /// never seed a deterministic history without corrupting real state.
    func useConversationStore(_ store: ConversationStore, directory: String) {
        conversation = store
        conversationDirectory = directory
    }

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
        await restoreTimersIfNeeded()
        // Nearly every utterance is checked against the shortcut list, so fill
        // it now rather than making the first spoken command wait on it.
        Shortcuts.warm()
        // Same reasoning for the fast-tier model: pay its cold start at
        // launch rather than inside someone's first answer — Ollama's is
        // 11.4 s measured. Fired off, not awaited: start() must not wait on
        // model loading.
        Task { [quickAnswerer] in await quickAnswerer.prewarm() }
    }

    /// Applies a settings change (e.g. a model switch) to subsequent dispatches
    /// without restarting the app.
    public func updateConfig(_ newConfig: Config) {
        let previousDirectory = config.effectiveWorkingDirectory
        let previousOllamaModel = config.ollamaModel
        let previousOllamaBaseURL = config.ollamaBaseURL
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

        // The fast-answer chain bakes in the Ollama knobs, so a change to
        // them needs a rebuild here — otherwise updateConfig's promise of
        // "no restart needed" would silently exclude exactly these settings.
        // The fresh backend gets its own prewarm: the residency bought for
        // the old model does nothing for the new one.
        if newConfig.ollamaModel != previousOllamaModel
            || newConfig.ollamaBaseURL != previousOllamaBaseURL {
            quickAnswerer = ChainedAnswerer.standard(config: newConfig)
            Task { [quickAnswerer] in await quickAnswerer.prewarm() }
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

    private let localCommands = LocalCommandRouter()
    /// Kept for "say that again".
    private var lastSpokenReply: String?

    /// Engine id recorded for turns the fast tier answered — whichever local
    /// backend produced the words. One id for the whole tier on purpose:
    /// `codingConversationIsActive` and the resume logic both read "not this
    /// id" as "a real engine worked here", so labelling Ollama turns
    /// per-backend would make a run of trivia look like a coding
    /// conversation. Which backend spoke is a logging concern, not a routing
    /// one.
    public static let onDeviceEngineId = "on-device"

    /// Whether the active conversation still counts as *coding* for the
    /// evidence gate: any active turn ran on a real engine.
    ///
    /// Deliberately any turn, not the latest. Judging by the last turn alone
    /// was a live defect: a single on-device answer after an engine turn
    /// flipped this false, so the next "make it faster" — aimed at the
    /// engine's work two turns back — was allowed to try the fast tier, which
    /// is the misroute that loses work. The reverse error stays cheap: a run
    /// of pure trivia is all on-device turns, so it still reads false and
    /// costs the user no fast answers.
    public static func codingConversationIsActive(_ turns: [ConversationStore.Turn]) -> Bool {
        turns.contains { $0.engineId != onDeviceEngineId }
    }

    /// One store for the whole session — a timer set by one utterance has to
    /// still be there when a later one cancels or asks about it.
    private let timers = TimerStore.default
    private var timersRestored = false

    /// Reloads timers left over from a previous run, once per session.
    ///
    /// Called from `start()`, not from the first utterance: a pending timer has
    /// to re-arm whether or not you ever speak again, which is the entire point
    /// of persisting it. Constructing a pipeline stays side-effect-free, so the
    /// CLI can build one just to inspect routing without announcing anything.
    private func restoreTimersIfNeeded() async {
        guard !timersRestored else { return }
        timersRestored = true
        await timers.setNotifier { [weak self] line in
            await self?.say(line)
            await self?.emitLine(line)
        }
        await timers.restore()
        // The CLI can add a timer while this process is running, and its own
        // process exits before the timer is due — so somebody long-lived has to
        // pick it up.
        await timers.startWatching()
    }

    private func localContext() -> LocalContext {
        LocalContext(
            notesFile: Config.stateDirectory.appendingPathComponent("notes.md"),
            quota: { [weak self] in
                guard let self else { return [] }
                return await self.monitor.current().snapshot?.providers ?? []
            },
            lastReply: { [weak self] in await self?.lastSpokenReply },
            // A timer firing must speak even though nobody asked just then.
            notify: { [weak self] line in
                await self?.say(line)
                await self?.emitLine(line)
            },
            timers: timers
        )
    }

    private func emitLine(_ line: String) {
        emit("  \(line)")
    }

    /// Single point where speech is suppressed, so every call site honours the
    /// mute without having to remember to check.
    private func say(_ text: String) async {
        lastSpokenReply = text
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
        if let pending = pendingConfirmation {
            pendingConfirmation = nil
            switch DestructiveIntent.interpretReply(transcript.text) {
            case .affirm:
                switch pending.action {
                case .task(let task):
                    emit("  confirmed")
                    await dispatch(task: task)
                case .undo(let point):
                    await performUndo(point)
                }
            case .decline, .unclear:
                emit("  cancelled")
                await say(
                    { if case .undo = pending.action { return "Left it as it is." }
                      else { return "Cancelled." } }()
                )
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

        // Anything the app can do itself is done here, before an engine is
        // involved: instant, and it costs no quota.
        switch await localCommands.handle(transcript.text, context: localContext()) {
        case .handled(let reply):
            if let reply {
                emit("  \(reply)")
                lastSpokenReply = reply
                await say(reply)
            }
            return
        case .notMine:
            break
        }

        // The fast-answer tier: a quick general question gets one shot at a
        // small local model instead of a twenty-second engine round trip.
        // Gated twice — task-evidence heuristics here, then the model's own
        // structured hand-off — because the two misroutes are not equal: a
        // question sent to an engine is merely slow, while a task swallowed
        // by the small model is work silently lost. Anything short of a clean
        // answer falls through to the dispatch path unchanged.
        if config.fastAnswers {
            let activeTurns = await conversation.activeTurns()
            let activeCoding = Self.codingConversationIsActive(activeTurns)

            switch TaskEvidenceGate.classify(transcript.text, activeCodingConversation: activeCoding) {
            case .engine(let reason):
                // Surfaced only in dry run: during real use the dispatch path
                // prints its own routing lines, and the gate reason would be
                // noise on every single task.
                if dryRun { emit("  → task evidence: \(reason) — engine only") }
            case .tryFast:
                if dryRun {
                    // The tier decision without the model call, so `voxrouter
                    // voice --dry-run` shows routing headlessly and offline.
                    emit("  → would try the fast tier first")
                    break
                }
                // Reuse the cross-engine digest for continuity, so "how tall
                // is that in metres" can follow "how tall is Everest".
                let context = activeTurns.isEmpty ? nil : ConversationStore.digest(of: activeTurns)
                switch await quickAnswerer.answer(transcript.text, context: context) {
                case .answered(let answer):
                    emit("  \(answer)")
                    lastSpokenReply = answer
                    await say(answer)
                    // Recorded like any other turn, so a follow-up — on this
                    // tier or an engine — knows what was just asked.
                    await conversation.record(
                        task: transcript.text,
                        engineId: Self.onDeviceEngineId,
                        sessionId: nil,
                        runId: UUID().uuidString,
                        summary: answer,
                        succeeded: true
                    )
                    return
                case .escalated(let why):
                    // A log line only, never spoken: escalation is the boring,
                    // safe default, and narrating internal tier decisions
                    // would train the user to tune the assistant out.
                    emit("  (fast tier passed — \(why); dispatching)")
                }
            }
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
            pendingConfirmation = Pending(action: .task(transcript.text), at: Date())
            emit("  ⚠︎ needs confirmation: \(risk.reason)")
            await say(
                "That would \(risk.reason). Hold the key and say yes to confirm."
            )
            return
        }

        await dispatch(task: transcript.text)
    }

    /// Something waiting on a spoken yes/no.
    ///
    /// One mechanism for both kinds, because having two was how the undo path
    /// ended up with no expiry while the task path had one — the hazard is
    /// identical and so is the handling.
    enum PendingAction: Sendable {
        case task(String)
        case undo(RecoveryPoint)
    }

    struct Pending: Sendable {
        let action: PendingAction
        let at: Date
    }

    /// How long a confirmation stays answerable. A stale one is dangerous:
    /// answering "yes" to something else minutes later must not run a forgotten
    /// destructive task or reset a repository.
    static let confirmationTimeout: TimeInterval = 60

    private var pendingConfirmation: Pending? {
        didSet {
            guard pendingConfirmation != nil else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.confirmationTimeout))
                await self?.expireConfirmation()
            }
        }
    }

    private func expireConfirmation() {
        guard let pending = pendingConfirmation,
              Date().timeIntervalSince(pending.at) >= Self.confirmationTimeout else { return }
        pendingConfirmation = nil
        emit("  (confirmation timed out)")
    }

    /// Exposed for the UI, and for tests: something is waiting on a yes/no.
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
        pendingConfirmation = Pending(action: .undo(point), at: Date())
        let changes = point.hadUncommittedChanges ? ", including your uncommitted changes" : ""
        emit("  ⚠︎ undo would reset to \(point.shortHead)\(changes) — “\(turn.task)”")
        await say(
            "That would undo \(SpokenNarration.speakable(turn.task, maxCharacters: 80)) "
            + "and reset to commit \(point.shortHead). Say yes to confirm."
        )
    }

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
