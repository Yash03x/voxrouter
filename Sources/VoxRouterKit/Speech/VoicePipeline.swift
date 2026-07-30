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
            workingDirectory: URL(fileURLWithPath: config.workingDirectory),
            timeout: config.conversationTimeout
        )
    }

    private let conversation: ConversationStore

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
        config = newConfig
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
            await speaker.speak("Sorry, I couldn't make that out.")
            return
        }

        guard !transcript.isEmpty else {
            emit("  (heard nothing)")
            return
        }

        emit("  “\(transcript.text)”")

        if Self.isResetCommand(transcript.text) {
            await conversation.reset()
            emit("  (conversation cleared)")
            await speaker.speak("Starting fresh.")
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

        await dispatch(task: transcript.text)
    }

    private func dispatch(task: String) async {
        let dispatcher = Dispatcher(config: config, router: router, conversation: conversation)
        let emit = self.emit
        let speaker = self.speaker

        // Updates arrive from the dispatcher's own context while the run is in
        // flight, so speech is fired off rather than awaited — blocking the
        // dispatch loop on the audio device would stall the actual work.
        let verbosity = config.speechVerbosity
        let narrate: @Sendable (DispatchUpdate) -> Void = { update in
            guard let line = SpokenNarration.line(for: update, verbosity: verbosity) else { return }
            Task.detached { await speaker.speak(line) }
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
            await speaker.speak("The task failed to start.")
        }
    }
}
