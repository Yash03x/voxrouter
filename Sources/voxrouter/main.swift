import AppKit
import Foundation
import VoxRouterKit

/// Turns this CLI into a windowless accessory app.
///
/// `RegisterEventHotKey` only delivers to a process the window server treats as
/// an application; a plain `CFRunLoopRun()` in a command-line tool registers the
/// hotkey successfully and then never sees an event. `.accessory` gives us the
/// event loop without a Dock icon or menu bar.
@MainActor
enum Accessory {
    static func runEventLoop() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
        // NSApplication.run() does not return.
        exit(0)
    }
}

/// Saves push-to-talk clips and reports them.
final class ClipCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let saveURL: URL?

    init(saveURL: URL?) { self.saveURL = saveURL }

    func handle(_ clip: PushToTalkClip) {
        lock.lock()
        index += 1
        let current = index
        lock.unlock()

        var line = String(
            format: "  clip %d — %.2fs, peak %.0f dBFS%@",
            current, clip.duration, clip.peakDb, clip.truncated ? " (capped)" : ""
        )
        if let saveURL {
            let file = saveURL.appendingPathComponent(String(format: "ptt-%03d.wav", current))
            do {
                try WavWriter.write(samples: clip.samples, to: file)
                line += " → \(file.lastPathComponent)"
            } catch {
                line += " (save failed: \(error.localizedDescription))"
            }
        }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

@main
struct VoxRouterCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "help"
        let config = Config.load()

        switch command {
        case "quota":
            await showQuota(config)
        case "catalog":
            showCatalog(config)
        case "engines":
            showEngines(config)
        case "route":
            await showRoute(config)
        case "listen":
            await listen(config, saveDirectory: args.dropFirst().first)
        case "ptt":
            await pushToTalk(config, saveDirectory: args.dropFirst().first)
        case "transcribe":
            await transcribe(config, arguments: Array(args.dropFirst()))
        case "voice":
            await voice(config, arguments: Array(args.dropFirst()))
        case "say":
            await speak(config, arguments: Array(args.dropFirst()))
        case "undo":
            await undo(config, arguments: Array(args.dropFirst()))
        case "keys":
            await identifyKeys()
        case "run":
            let rest = Array(args.dropFirst())
            let task = rest.filter { !$0.hasPrefix("--") }.joined(separator: " ")
            guard !task.isEmpty else {
                FileHandle.standardError.write(Data("usage: voxrouter run [--new] <task>\n".utf8))
                exit(2)
            }
            await runTask(task, config, startFresh: rest.contains("--new"))
        case "help", "--help", "-h":
            printUsage()
        default:
            FileHandle.standardError.write(Data("unknown command: \(command)\n".utf8))
            printUsage()
            exit(2)
        }
    }

    // MARK: - Commands

    static func showQuota(_ config: Config) async {
        let client = QuotaClient(baseURL: config.openUsageBaseURL)
        do {
            let snapshot = try await client.fetchAll()
            if snapshot.providers.isEmpty {
                print("No providers enabled in OpenUsage.")
                return
            }
            for provider in snapshot.providers {
                let name = provider.displayName ?? provider.providerId
                let plan = provider.plan.map { " · \($0)" } ?? ""
                var header = "\(name)\(plan)"
                if let age = provider.upstreamAge() {
                    header += "  (fetched \(Format.duration(age)) ago)"
                }
                print(header)
                if provider.windows.isEmpty {
                    print("  (no quota windows reported)")
                }
                let labelWidth = provider.windows.map(\.label.count).max() ?? 0
                for window in provider.windows {
                    let label = window.label.padding(
                        toLength: labelWidth, withPad: " ", startingAt: 0
                    )
                    let percent = String(format: "%3.0f%%", window.usedPercent)
                    var line = "  \(label)  \(Format.bar(window.usedPercent)) \(percent)"
                    if let reset = window.resetsAt {
                        line += "  resets \(Format.relative(reset))"
                    }
                    print(line)
                }
                print("")
            }
            if snapshot.isDegraded {
                print("WARNING: no usable quota rows — OpenUsage schema may have changed.")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Rescans the engine binaries for model names and reports the menu that
    /// results. Slow on a cache miss (~3s per binary).
    static func showCatalog(_ config: Config) {
        EngineRegistry.refreshCatalog(config: config)
        for engine in EngineRegistry.all(config: config) where engine.isInstalled {
            let choices = EngineRegistry.modelChoices(for: engine.id, config: config)
            print("\(engine.displayName) — \(choices.count) models")
            for choice in choices {
                print("  \(EngineDisplay.model(choice))")
            }
            print("")
        }
    }

    static func showEngines(_ config: Config) {
        for engine in EngineRegistry.all(config: config) {
            if let path = engine.binaryPath {
                print("✓ \(engine.displayName)  \(path.path)")
                print("    Model:  \(EngineDisplay.model(engine.configuredModel))")
                print("    Effort: \(EngineDisplay.effort(engine.configuredEffort))")
            } else {
                print("✗ \(engine.displayName)  not installed — \(engine.installHint)")
            }
        }
    }

    static func showRoute(_ config: Config) async {
        let client = QuotaClient(baseURL: config.openUsageBaseURL)
        let monitor = QuotaMonitor(client: client, interval: config.quotaRefreshInterval)
        _ = try? await monitor.refresh()

        let router = EngineRouter(policy: config.routing, monitor: monitor)
        let engines = EngineRegistry.all(config: config)
        let installed = Set(engines.filter(\.isInstalled).map(\.id))

        switch await router.decide(installed: installed) {
        case .dispatch(let decision):
            let flag = decision.isCompromise ? " [compromise]" : ""
            print("→ \(decision.engineId)\(flag)")
            print("  \(decision.reason)")
        case .exhausted(let retryAfter):
            let when = retryAfter.map(Format.relative) ?? "unknown"
            print("→ all engines exhausted; earliest reset \(when)")
        case .noEnginesAvailable:
            print("→ no engines installed. Run `voxrouter engines`.")
        }
    }

    static func runTask(_ task: String, _ config: Config, startFresh: Bool = false) async {
        let client = QuotaClient(baseURL: config.openUsageBaseURL)
        let monitor = QuotaMonitor(client: client, interval: config.quotaRefreshInterval)
        _ = try? await monitor.refresh()

        let router = EngineRouter(policy: config.routing, monitor: monitor)
        // Must follow the active project, or the CLI keeps history against a
        // directory tasks no longer run in.
        let conversation = ConversationStore(
            workingDirectory: URL(fileURLWithPath: config.effectiveWorkingDirectory),
            timeout: config.conversationTimeout
        )
        if startFresh { await conversation.reset() }
        let turns = await conversation.activeTurns().count
        if turns > 0 {
            print("(continuing — \(turns) earlier turn\(turns == 1 ? "" : "s") in this directory)")
        }
        let dispatcher = Dispatcher(config: config, router: router, conversation: conversation)

        do {
            let result = try await dispatcher.run(task: task) { update in
                switch update {
                case .routed(let engine, let reason):
                    print("→ \(engine): \(reason)")
                case .action(let engine, let detail):
                    print("  [\(engine)] \(detail)")
                case .text(_, let detail):
                    print("  \(detail)")
                case .handoff(let from, let to, let reason):
                    print("⇄ handoff \(from) → \(to): \(reason)")
                case .succeeded(let engine, _):
                    print("✓ done on \(engine)")
                case .failed(let reason):
                    print("✗ \(reason)")
                case .blocked(let retryAfter):
                    let when = retryAfter.map(Format.relative) ?? "unknown"
                    print("⏸ all engines out of quota; earliest reset \(when)")
                }
            }
            print("\njournal: \(result.journalDirectory.path)")
            print("engines: \(result.engineHistory.joined(separator: " → "))")
            if !result.succeeded { exit(1) }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Live microphone check for the VAD: shows a level meter and reports each
    /// detected utterance. Optionally dumps segments as WAV so the preroll can
    /// be verified by ear.
    static func listen(_ config: Config, saveDirectory: String?) async {
        guard await MicrophoneSource.requestPermission() else {
            FileHandle.standardError.write(Data("""
            Microphone access not granted (status: \(MicrophoneSource.permissionStatus.rawValue)).
            Grant it in System Settings ▸ Privacy & Security ▸ Microphone for your terminal,
            then run this again.

            """.utf8))
            exit(1)
        }

        var saveURL: URL?
        if let saveDirectory {
            let url = URL(fileURLWithPath: saveDirectory)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                saveURL = url
            } catch {
                FileHandle.standardError.write(
                    Data("cannot write to \(saveDirectory): \(error.localizedDescription)\n".utf8)
                )
                exit(1)
            }
        }

        let segmenter = SpeechSegmenter(source: MicrophoneSource())
        let meter = MeterPrinter()
        segmenter.onMeter { meter.render($0) }

        print("Listening. Speak, then pause. Ctrl-C to stop.")
        if let saveURL { print("Saving segments to \(saveURL.path)") }
        print("")

        do {
            var index = 0
            for await segment in try segmenter.segments() {
                index += 1
                meter.clearLine()
                var line = String(
                    format: "utterance %d — %.2fs, peak %.0f dBFS, %@",
                    index, segment.duration, segment.peakDb, "\(segment.endReason)"
                )
                if let saveURL {
                    let file = saveURL.appendingPathComponent(String(format: "utterance-%03d.wav", index))
                    do {
                        try WavWriter.write(samples: segment.samples, to: file)
                        line += " → \(file.lastPathComponent)"
                    } catch {
                        line += " (save failed: \(error.localizedDescription))"
                    }
                }
                // Written through FileHandle rather than print(): stdout is
                // block-buffered when redirected to a file, so a long-running
                // listen session that gets killed would lose every utterance
                // line while the unbuffered meter survived.
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Hold-to-talk check. Runs as an accessory app because Carbon hotkey
    /// events are only dispatched to a process with a real Cocoa event loop —
    /// a bare CLI run loop receives nothing.
    static func pushToTalk(_ config: Config, saveDirectory: String?) async {
        guard await MicrophoneSource.requestPermission() else {
            FileHandle.standardError.write(Data(
                "Microphone access not granted. Grant it in System Settings ▸ Privacy & Security ▸ Microphone.\n".utf8
            ))
            exit(1)
        }

        var saveURL: URL?
        if let saveDirectory {
            let url = URL(fileURLWithPath: saveDirectory)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                saveURL = url
            } catch {
                FileHandle.standardError.write(
                    Data("cannot write to \(saveDirectory): \(error.localizedDescription)\n".utf8)
                )
                exit(1)
            }
        }

        let combo = HotkeyCombo.controlOptionSpace
        let recorder = PushToTalkRecorder(source: MicrophoneSource())
        let counter = ClipCounter(saveURL: saveURL)

        recorder.onStateChange { state in
            let message = state == .recording ? "● recording…\n" : "  …stopped\n"
            FileHandle.standardOutput.write(Data(message.utf8))
        }
        recorder.onClip { clip in counter.handle(clip) }

        // Warm the engine up front, so the first press doesn't pay start-up
        // latency and lose the opening syllable.
        do {
            try recorder.warmUp()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }

        let monitor = HotkeyMonitor()
        do {
            try monitor.start(combo: combo) { event in
                switch event {
                case .pressed: recorder.beginRecording()
                case .released: recorder.endRecording()
                }
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            recorder.shutDown()
            exit(1)
        }

        FileHandle.standardOutput.write(Data("""
        Push-to-talk ready. Hold \(combo.label) and speak. Ctrl-C to quit.
        Mic is warm, so the start of your first word is captured.

        """.utf8))

        await Accessory.runEventLoop()
    }

    /// Speech-to-text against an audio file, plus model management.
    static func transcribe(_ config: Config, arguments: [String]) async {
        guard #available(macOS 26, *) else {
            FileHandle.standardError.write(Data(
                "On-device SpeechAnalyzer needs macOS 26 or later.\n".utf8
            ))
            exit(1)
        }

        let locale = Locale.current

        if arguments.contains("--status") {
            let resolved = await AppleTranscriber.resolvedLocale(for: locale)
            print("SpeechTranscriber available: \(AppleTranscriber.isAvailable)")
            print("requested locale:            \(locale.identifier)")
            print("resolved locale:             \(resolved?.identifier ?? "none — unsupported")")
            if let resolved {
                print("model status:                \(await AppleTranscriber.modelStatus(for: resolved))")
            }
            let installed = await AppleTranscriber.installedLocales
            print("installed models:            \(installed.map(\.identifier).sorted().joined(separator: ", "))")
            return
        }

        if arguments.contains("--install") {
            guard let resolved = await AppleTranscriber.resolvedLocale(for: locale) else {
                FileHandle.standardError.write(Data("No model supports \(locale.identifier).\n".utf8))
                exit(1)
            }
            print("Installing the speech model for \(resolved.identifier)…")
            do {
                try await AppleTranscriber.installModel(for: resolved) { fraction in
                    let line = String(format: "\r  %.0f%%", fraction * 100)
                    FileHandle.standardOutput.write(Data(line.utf8))
                }
                print("\r  done.     ")
            } catch {
                FileHandle.standardError.write(Data("\n\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }

        guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else {
            FileHandle.standardError.write(Data("""
            usage: voxrouter transcribe <audio-file>
                   voxrouter transcribe --status
                   voxrouter transcribe --install

            """.utf8))
            exit(2)
        }

        do {
            let samples = try AudioFileLoader.loadMono16k(url: URL(fileURLWithPath: path))
            let duration = Double(samples.count) / AudioConstants.sampleRate

            // --no-vocab exists to A/B the contextual-biasing hints, which are
            // otherwise impossible to attribute: an unchanged transcript could
            // mean the bias didn't apply, or that the audio genuinely sounds
            // like the wrong word.
            let vocabulary = arguments.contains("--no-vocab") ? [] : TechnicalVocabulary.default

            let started = Date()
            let transcript = try await AppleTranscriber(locale: locale, vocabulary: vocabulary)
                .transcribe(samples: samples)
            let elapsed = Date().timeIntervalSince(started)

            print("\(transcript.text)")
            print("")
            print(String(
                format: "  %.2fs audio · %.2fs transcribe · %.1f× realtime · %@",
                duration, elapsed, duration / max(elapsed, 0.001), transcript.engine
            ))
            if !transcript.alternatives.isEmpty {
                print("  alternatives: \(transcript.alternatives.joined(separator: " | "))")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Text-to-speech check, and voice listing.
    static func speak(_ config: Config, arguments: [String]) async {
        if arguments.contains("--voices") {
            let voices = SystemSpeaker.availableVoices()
                .filter { $0.language.hasPrefix("en") }
                .sorted { $0.name < $1.name }
            for voice in voices {
                print(String(format: "  %-22@ %@", voice.name as NSString, voice.language as NSString))
            }
            print("\n\(voices.count) English voices. Set one as \"voice\" in \(Config.configURL.path).")
            return
        }

        let text = arguments.filter { !$0.hasPrefix("--") }.joined(separator: " ")
        guard !text.isEmpty else {
            FileHandle.standardError.write(Data("""
            usage: voxrouter say <text>
                   voxrouter say --voices

            """.utf8))
            exit(2)
        }

        // Show what the narration filter does to it, since that's the part
        // that's easy to get wrong and hard to notice.
        let spoken = SpokenNarration.speakable(text)
        if spoken != text {
            print("spoken as: \(spoken)")
        }
        let speaker = SystemSpeaker(voiceIdentifier: config.voice)

        if arguments.contains("--bench") {
            // Demonstrates the warm-up cost the daemon pays once at launch.
            var start = Date()
            await speaker.prewarm()
            let warmup = Date().timeIntervalSince(start)

            start = Date()
            await speaker.speak(spoken)
            let first = Date().timeIntervalSince(start)

            start = Date()
            await speaker.speak(spoken)
            let second = Date().timeIntervalSince(start)

            print(String(
                format: "prewarm %.0f ms · after prewarm %.0f ms · repeat %.0f ms",
                warmup * 1000, first * 1000, second * 1000
            ))
            return
        }

        await speaker.speak(spoken)
    }

    /// The whole thing joined up: hold a key, speak, and the task is dispatched
    /// to whichever engine has quota.
    static func voice(_ config: Config, arguments: [String]) async {
        guard #available(macOS 26, *) else {
            FileHandle.standardError.write(Data("Voice mode needs macOS 26 or later.\n".utf8))
            exit(1)
        }
        guard await MicrophoneSource.requestPermission() else {
            FileHandle.standardError.write(Data("Microphone access not granted.\n".utf8))
            exit(1)
        }

        let dryRun = arguments.contains("--dry-run")
        let locale = Locale.current
        guard let resolved = await AppleTranscriber.resolvedLocale(for: locale),
              await AppleTranscriber.modelStatus(for: resolved) == "installed" else {
            FileHandle.standardError.write(Data(
                "Speech model not installed. Run `voxrouter transcribe --install` first.\n".utf8
            ))
            exit(1)
        }

        let transcriber = AppleTranscriber(locale: resolved)
        let combo = HotkeyCombo.controlOptionSpace
        let recorder = PushToTalkRecorder(source: MicrophoneSource())
        let speaker: any Speaker
        if arguments.contains("--mute") {
            speaker = SilentSpeaker()
        } else {
            let system = SystemSpeaker(voiceIdentifier: config.voice)
            // Pay the ~555 ms synthesizer warm-up now, not on the first reply.
            await system.prewarm()
            speaker = system
        }
        let pipeline = VoicePipeline(
            config: config,
            transcriber: transcriber,
            speaker: speaker,
            dryRun: dryRun
        )

        recorder.onStateChange { state in
            if state == .recording {
                // Barge-in: the instant the key goes down, stop talking. Being
                // talked over is the fastest way to make an assistant annoying.
                pipeline.bargeIn()
            }
            let message = state == .recording ? "\n● listening…\n" : "  transcribing…\n"
            FileHandle.standardOutput.write(Data(message.utf8))
        }
        recorder.onClip { clip in
            // Detached: transcription and dispatch take far longer than the
            // audio callback can be blocked for.
            Task.detached { await pipeline.handle(clip) }
        }

        do {
            try recorder.warmUp()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }

        let monitor = HotkeyMonitor()
        do {
            try monitor.start(combo: combo) { event in
                switch event {
                case .pressed: recorder.beginRecording()
                case .released: recorder.endRecording()
                }
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            recorder.shutDown()
            exit(1)
        }

        FileHandle.standardOutput.write(Data("""
        Voice mode ready\(dryRun ? " (dry run — nothing will be dispatched)" : "").
        Hold \(combo.label), say what you want done, release.
        Ctrl-C to quit.

        """.utf8))

        await Accessory.runEventLoop()
    }

    /// Puts the active project back to where it was before the last task.
    static func undo(_ config: Config, arguments: [String]) async {
        let conversation = ConversationStore(
            workingDirectory: URL(fileURLWithPath: config.effectiveWorkingDirectory),
            timeout: config.conversationTimeout
        )
        guard let turn = await conversation.mostRecentRecoverable(),
              let point = turn.recovery else {
            print("Nothing to undo in \(config.activeProject.name).")
            return
        }

        print("Would undo: “\(turn.task)”")
        print("  reset \(config.activeProject.name) to \(point.shortHead)"
              + (point.hadUncommittedChanges ? ", restoring your uncommitted changes" : ""))

        // Undo throws away whatever the agent did, so it asks unless told not
        // to — the same bar as any other destructive action.
        if !arguments.contains("--yes") {
            print("\nRun again with --yes to do it.")
            return
        }

        do {
            let result = try GitRecovery.restore(point)
            print("↩︎ reset to \(String(result.head.prefix(8)))")
            if result.restoredUncommitted { print("  restored your uncommitted changes") }
            if let undoneRef = result.undoneRef {
                print("  undone work kept at \(undoneRef)")
                print("  to get it back: git reset --hard \(undoneRef)")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Reports what hardware keys emit, so one can be bound by number rather
    /// than guessed at. The mic/dictation key isn't in the documented
    /// `NX_KEYTYPE_*` list, so observing it is the only reliable way to find it.
    static func identifyKeys() async {
        // Unbuffered: stdout is block-buffered to a pipe, so a session that
        // gets killed would lose every line.
        func say(_ text: String) {
            FileHandle.standardOutput.write(Data((text + "\n").utf8))
        }

        guard SystemKeyMonitor.isPermitted else {
            say("""
            Capturing hardware keys needs Accessibility permission.

            A prompt should appear now. If it doesn't, add your terminal in
            System Settings ▸ Privacy & Security ▸ Accessibility, then run this
            again.
            """)
            SystemKeyMonitor.requestPermission()
            return
        }

        let monitor = SystemKeyMonitor()
        do {
            // Capture nothing: this only observes, so the keys still do their
            // normal jobs while you're identifying them.
            try monitor.start(capturing: []) { event in
                switch event {
                case .pressed(let keyCode):
                    FileHandle.standardOutput.write(
                        Data("  key \(keyCode) down\n".utf8)
                    )
                case .released(let keyCode):
                    FileHandle.standardOutput.write(
                        Data("  key \(keyCode) up   ← use this number\n".utf8)
                    )
                }
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }

        say("""
        Press the key you want to use — the microphone key, for instance.
        Nothing is intercepted here, so keys still do their usual thing.
        Ctrl-C when done.
        """)
        await Accessory.runEventLoop()
    }

    static func printUsage() {
        print("""
        voxrouter — quota-aware dispatcher for Claude Code and Codex

          voxrouter quota        live quota for every enabled provider
          voxrouter engines      which engine binaries are installed
          voxrouter route        which engine would be chosen right now
          voxrouter run <task>   dispatch a task, failing over on quota limits
          voxrouter run --new <task>        ...starting a fresh conversation
          voxrouter listen [dir] live mic level meter + detected utterances,
                                 optionally saving each as a WAV in <dir>
          voxrouter ptt [dir]    hold ⌃⌥Space to record; saves clips to <dir>
          voxrouter transcribe <file>       speech-to-text on an audio file
          voxrouter transcribe --status     recogniser and model availability
          voxrouter transcribe --install    download the on-device model
          voxrouter voice        hold ⌃⌥Space, speak a task, it gets dispatched
          voxrouter voice --dry-run         transcribe and route, but don't run
          voxrouter voice --mute            no spoken replies
          voxrouter say <text>   speak text aloud (shows the narration filter)
          voxrouter say --voices            list installed English voices
          voxrouter undo [--yes] put the project back to before the last task
          voxrouter keys         identify what a hardware key emits
          voxrouter catalog      rescan the CLIs for models and list the menu
        """)
    }
}

// MARK: - Formatting

/// Redraws a one-line level meter in place. Throttled because the audio path
/// meters every 30 ms and a terminal cannot usefully repaint that fast.
final class MeterPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPaint = Date.distantPast
    private let interval: TimeInterval = 0.1
    private var width = 0

    func render(_ meter: SpeechSegmenter.Meter) {
        lock.lock()
        guard Date().timeIntervalSince(lastPaint) >= interval else {
            lock.unlock()
            return
        }
        lastPaint = Date()
        lock.unlock()

        // Map -60..0 dBFS onto the bar.
        let span: Float = 60
        let filled = Int(((meter.db + span) / span * 30).clamped(to: 0...30))
        let bar = String(repeating: "▁", count: filled)
            + String(repeating: " ", count: 30 - filled)
        let state = meter.isCapturing ? "● REC " : "      "
        let line = String(
            format: "\r%@[%@] %6.1f dB  floor %6.1f dB", state, bar, meter.db, meter.noiseFloorDb
        )
        lock.lock()
        width = line.count
        lock.unlock()
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    func clearLine() {
        lock.lock()
        let padding = max(width, 1)
        lock.unlock()
        FileHandle.standardOutput.write(Data(("\r" + String(repeating: " ", count: padding) + "\r").utf8))
    }
}

enum Format {
    static func bar(_ percent: Double, width: Int = 20) -> String {
        let filled = Int((percent / 100 * Double(width)).rounded())
            .clamped(to: 0...width)
        return String(repeating: "█", count: filled)
            + String(repeating: "░", count: width - filled)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        if total < 86_400 { return "\(total / 3600)h" }
        return "\(total / 86_400)d"
    }

    static func relative(_ date: Date) -> String {
        let delta = date.timeIntervalSinceNow
        if delta <= 0 { return "now" }
        return "in " + duration(delta)
    }
}
