import Combine
import Foundation
import SwiftUI
import VoxRouterKit

/// What the menu bar icon is currently showing.
enum ActivityState: Equatable {
    case idle
    case listening
    case thinking        // transcribing
    case working(String) // dispatched to an engine
    case blocked
    case error(String)

    var symbol: String {
        switch self {
        case .idle: return "waveform"
        case .listening: return "waveform.badge.mic"
        case .thinking: return "waveform.badge.magnifyingglass"
        case .working: return "gearshape.2"
        case .blocked: return "hourglass"
        case .error: return "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .idle: return .primary
        case .listening: return .red
        case .thinking: return .orange
        case .working: return .accentColor
        case .blocked: return .orange
        case .error: return .red
        }
    }

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .thinking: return "Transcribing…"
        case .working(let engine): return "Working with \(engine)…"
        case .blocked: return "Out of quota"
        case .error(let message): return message
        }
    }

    /// Only live states animate. A permanently pulsing menu bar icon is the
    /// kind of thing people uninstall software over.
    var isAnimating: Bool {
        switch self {
        case .listening, .thinking, .working: return true
        default: return false
        }
    }
}

struct ActivityLine: Identifiable {
    let id = UUID()
    let at: Date
    let text: String
    let isUser: Bool
}

/// Deliberately the pre-macro `ObservableObject` API rather than `@Observable`:
/// only Command Line Tools are installed, and `libSwiftUIMacros.dylib` ships
/// with full Xcode, so `@State`/`@Bindable`/`@Observable` cannot expand here.
@MainActor
final class AppModel: ObservableObject {
    @Published var state: ActivityState = .idle
    @Published var transcript: String = ""
    @Published var activity: [ActivityLine] = []
    @Published var history: [ConversationStore.Conversation] = []
    @Published var quota: [ProviderUsage] = []
    @Published var selectedConversation: String?
    @Published var speechEnabled = true
    /// Whether the "what you can say" list is expanded.
    ///
    /// Collapsed by default: it's for the first week, not every glance at the
    /// menu. Lives here rather than in the view because `@State` needs the
    /// SwiftUI macros, which don't ship with Command Line Tools.
    @Published var showsCommands = false
    @Published var permissionDenied = false
    @Published var startupError: String?
    /// Set when the only thing missing is the on-device model, which the app can
    /// fix itself. Distinct from `startupError`, which the user must resolve.
    @Published var needsModelDownload = false
    @Published var downloadProgress: Double?

    /// Notifies the AppKit status item when the animation should start or stop.
    var onActivityChange: ((Bool) -> Void)?

    /// Mutable so a model change from the picker takes effect on the next
    /// dispatch without restarting the app.
    private var config: Config
    private var recorder: PushToTalkRecorder?
    private var monitor: HotkeyMonitor?
    private var pipeline: VoicePipeline?
    /// Re-pointed on project switch, so history follows the directory.
    private var conversation: ConversationStore
    private let quotaClient: QuotaClient
    private var refreshTask: Task<Void, Never>?
    private var speaker: SystemSpeaker?

    /// The chord actually bound. May differ from the preference if another
    /// app owns it.
    @Published var hotkey = HotkeyCombo.controlOptionSpace

    var hotkeyChoices: [HotkeyCombo] { HotkeyCombo.presets }

    func setHotkey(_ combo: HotkeyCombo) {
        config.hotkey = combo
        try? config.write()
        objectWillChange.send()
        monitor?.unregister()
        bindHotkey()
    }

    init(config: Config = .load()) {
        self.config = config
        self.quotaClient = QuotaClient(baseURL: config.openUsageBaseURL)
        self.conversation = ConversationStore(
            workingDirectory: URL(fileURLWithPath: config.effectiveWorkingDirectory),
            timeout: config.conversationTimeout
        )
    }

    private func reloadConversationStore() async {
        conversation = ConversationStore(
            workingDirectory: URL(fileURLWithPath: config.effectiveWorkingDirectory),
            timeout: config.conversationTimeout
        )
        selectedConversation = nil
    }

    var workingDirectoryName: String { config.activeProject.name }

    var projects: [Project] { config.resolvedProjects }
    var activeProject: Project { config.activeProject }
    /// Fresh install: nowhere real to run a task yet.
    var needsProjectSetup: Bool { config.needsProjectSetup }
    var installedEngineCount: Int { EngineRegistry.installedIds(config: config).count }

    func setActiveProject(_ project: Project) {
        config.activeProjectID = project.id
        try? config.write()
        objectWillChange.send()
        let updated = config
        Task {
            await pipeline?.updateConfig(updated)
            await reloadConversationStore()
            await refresh()
        }
    }

    func addProject(path: String) {
        let url = URL(fileURLWithPath: path)
        let project = Project(name: url.lastPathComponent, path: url.standardizedFileURL.path)
        guard project.exists,
              !config.resolvedProjects.contains(where: { $0.path == project.path }) else { return }
        config.projects.append(project)
        setActiveProject(project)
    }

    /// Opens a directory picker. Uses NSOpenPanel rather than a typed path so
    /// there's no chance of registering a directory that doesn't exist.
    func chooseProjectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose a directory for VoxRouter to work in."
        // An .accessory app doesn't come forward on its own, so the panel would
        // otherwise open behind whatever is in front.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(path: url.path)
    }

    /// Switches to the unscoped Anywhere project, registering it if needed.
    func useAnywhere() {
        let anywhere = config.resolvedProjects.first(where: \.isAnywhere) ?? .anywhere()
        setActiveProject(anywhere)
    }

    func removeProject(_ project: Project) {
        guard !project.isAnywhere else { return }
        config.projects.removeAll { $0.id == project.id }
        if config.activeProjectID == project.id { config.activeProjectID = nil }
        try? config.write()
        objectWillChange.send()
        let updated = config
        Task { await pipeline?.updateConfig(updated) }
    }

    var engines: [(id: String, name: String, model: String?, effort: String?, installed: Bool)] {
        EngineRegistry.all(config: config).map {
            (
                id: $0.id,
                name: $0.displayName,
                model: $0.configuredModel,
                effort: $0.configuredEffort,
                installed: $0.isInstalled
            )
        }
    }

    func effortChoices(for engineId: String) -> [String] {
        EngineRegistry.effortChoices(for: engineId)
    }

    func setEffort(_ effort: String?, for engineId: String) {
        if let effort, !effort.isEmpty {
            config.engineEfforts[engineId] = effort
        } else {
            config.engineEfforts.removeValue(forKey: engineId)
        }
        persistAndApply()
    }

    /// True when any engine is configured to skip its approval prompts.
    var unrestricted: Bool {
        config.engineArgs.values.contains { args in
            args.contains { $0.contains("dangerously") || $0.contains("bypass") }
        }
    }

    func modelChoices(for engineId: String) -> [String] {
        EngineRegistry.modelChoices(for: engineId, config: config)
    }

    /// Persists the choice, so it survives a restart and matches what the CLI
    /// would do.
    func setModel(_ model: String?, for engineId: String) {
        if let model, !model.isEmpty {
            config.engineModels[engineId] = model
        } else {
            config.engineModels.removeValue(forKey: engineId)
        }
        persistAndApply()
    }

    /// Saves the config and pushes it to the running pipeline, so a change
    /// applies to the next dispatch without a restart.
    private func persistAndApply() {
        try? config.write()
        objectWillChange.send()
        let updated = config
        Task {
            await pipeline?.updateConfig(updated)
            await refresh()
        }
    }

    private func setState(_ newState: ActivityState) {
        let wasAnimating = state.isAnimating
        state = newState
        if wasAnimating != newState.isAnimating {
            onActivityChange?(newState.isAnimating)
        }
    }

    // MARK: - Lifecycle

    func start() async {
        Log.audio.notice("app start: begin")
        await refresh()
        Log.audio.notice("app start: quota+history refreshed")

        guard await MicrophoneSource.requestPermission() else {
            permissionDenied = true
            startupError = "Microphone access denied."
            setState(.error("Microphone denied"))
            return
        }

        guard #available(macOS 26, *) else {
            startupError = "Speech recognition needs macOS 26 or later."
            setState(.error("Unsupported macOS"))
            return
        }
        Log.audio.notice("app start: mic ok, resolving locale")
        guard let locale = await AppleTranscriber.resolvedLocale(for: Locale.current) else {
            startupError = "No speech model supports \(Locale.current.identifier)."
            setState(.error("No speech model"))
            return
        }
        Log.audio.notice("app start: locale \(locale.identifier, privacy: .public), checking model")
        // The model asset is scoped to the *app's* identity, so a copy installed
        // by the CLI does not count here — the app has to fetch its own. Telling
        // the user to run a CLI command would be actively wrong.
        guard await AppleTranscriber.modelStatus(for: locale) == "installed" else {
            needsModelDownload = true
            setState(.error("Speech model needed"))
            return
        }

        await finishStartup(locale: locale)
    }

    /// Downloads the on-device model for this app, then completes startup.
    func installSpeechModel() async {
        guard #available(macOS 26, *),
              let locale = await AppleTranscriber.resolvedLocale(for: Locale.current) else { return }

        downloadProgress = 0
        setState(.thinking)
        do {
            try await AppleTranscriber.installModel(for: locale) { [weak self] fraction in
                Task { @MainActor in self?.downloadProgress = fraction }
            }
            downloadProgress = nil
            needsModelDownload = false
            await finishStartup(locale: locale)
        } catch {
            downloadProgress = nil
            startupError = "Model download failed: \(error.localizedDescription)"
            setState(.error("Download failed"))
        }
    }

    @available(macOS 26, *)
    private func finishStartup(locale: Locale) async {
        Log.audio.notice("app start: model ok, building speaker")
        let speaker = SystemSpeaker(voiceIdentifier: config.voice)
        await speaker.prewarm()  // absorb the ~555 ms warm-up before first use
        Log.audio.notice("app start: speaker prewarmed")
        self.speaker = speaker

        let pipeline = VoicePipeline(
            config: config,
            transcriber: AppleTranscriber(locale: locale),
            speaker: speaker,
            emit: { [weak self] line in
                Task { @MainActor in self?.append(line) }
            }
        )
        self.pipeline = pipeline
        await pipeline.start()
        // A spoken project switch must move the UI too, not just the dispatcher.
        await pipeline.setProjectChangeHandler { [weak self] project in
            Task { @MainActor in
                guard let self else { return }
                self.config.activeProjectID = project.id
                await self.reloadConversationStore()
                self.objectWillChange.send()
                await self.refresh()
            }
        }

        let recorder = PushToTalkRecorder(source: MicrophoneSource())
        recorder.onStateChange { [weak self] recorderState in
            Task { @MainActor in
                guard let self else { return }
                if recorderState == .recording {
                    self.pipeline?.bargeIn()
                    self.transcript = ""
                    self.setState(.listening)
                } else {
                    self.setState(.thinking)
                }
            }
        }
        recorder.onClip { [weak self] clip in
            Task { @MainActor in self?.handle(clip) }
        }

        do {
            try recorder.warmUp()
            self.recorder = recorder
        } catch {
            startupError = error.localizedDescription
            setState(.error("Microphone unavailable"))
            return
        }

        bindHotkey()

        setState(.idle)
        startRefreshLoop()

        // Detached and low priority: a scan takes seconds per binary, and its
        // only job is to notice models added by a CLI update. Results land in
        // the picker on the next refresh.
        let currentConfig = config
        Task.detached(priority: .background) {
            EngineRegistry.refreshCatalog(config: currentConfig)
            await MainActor.run { self.objectWillChange.send() }
        }
    }

    /// Binds the preferred chord, falling back through the presets if another
    /// app owns it — reporting a chord the user can't change would leave them
    /// with no way to talk to the app at all.
    private func bindHotkey() {
        let monitor = HotkeyMonitor()
        do {
            let bound = try monitor.startWithFallback(
                preferred: config.preferredHotkey
            ) { [weak self] event in
                Task { @MainActor in
                    switch event {
                    case .pressed: self?.recorder?.beginRecording()
                    case .released: self?.recorder?.endRecording()
                    }
                }
            }
            self.monitor = monitor
            self.hotkey = bound
            if bound != config.preferredHotkey {
                startupError = "\(config.preferredHotkey.label) is taken by another app — using \(bound.label)."
            }
        } catch {
            startupError = "No shortcut could be registered: \(error.localizedDescription)"
        }
    }

    func stop() {
        refreshTask?.cancel()
        monitor?.unregister()
        recorder?.shutDown()
        speaker?.stop()
    }

    // MARK: - Handling

    private func handle(_ clip: PushToTalkClip) {
        guard let pipeline else { return }
        Task { @MainActor in
            await pipeline.handle(clip)
            if case .error = state {} else { setState(.idle) }
            await refresh()
        }
    }

    private func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // The pipeline wraps the heard text in curly quotes.
        if trimmed.hasPrefix("“") {
            transcript = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "“”"))
            activity.append(ActivityLine(at: Date(), text: transcript, isUser: true))
        } else {
            if trimmed.hasPrefix("→") {
                setState(.working(trimmed.contains("claude") ? "Claude" : "Codex"))
            } else if trimmed.hasPrefix("⏸") {
                setState(.blocked)
            } else if trimmed.hasPrefix("✗") {
                setState(.error(String(trimmed.dropFirst(2))))
            }
            activity.append(ActivityLine(at: Date(), text: trimmed, isUser: false))
        }
        if activity.count > 200 { activity.removeFirst(activity.count - 200) }
    }

    // MARK: - Refresh

    func refresh() async {
        if let snapshot = try? await quotaClient.fetchAll() {
            quota = snapshot.providers
        }
        history = await conversation.history()
        if selectedConversation == nil { selectedConversation = history.first?.id }
    }

    func newConversation() {
        Task { @MainActor in
            await conversation.reset()
            activity.append(
                ActivityLine(at: Date(), text: "Started a new conversation.", isUser: false)
            )
            await refresh()
        }
    }

    func toggleSpeech() {
        speechEnabled.toggle()
        // The pipeline decides what gets spoken, so the flag has to reach it —
        // stopping the current utterance here silenced nothing after it.
        let enabled = speechEnabled
        Task { await pipeline?.setSpeechEnabled(enabled) }
        if !enabled { speaker?.stop() }
    }

    private func startRefreshLoop() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.refresh()
            }
        }
    }
}
