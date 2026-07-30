import SwiftUI
import VoxRouterKit

struct MenuContent: View {
    @ObservedObject var model: AppModel
    let openHistory: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusHeader(model: model)
            Divider()

            if model.needsModelDownload || model.downloadProgress != nil {
                ModelDownload(model: model)
                Divider()
            } else if let error = model.startupError {
                SetupProblem(message: error, permissionDenied: model.permissionDenied)
                Divider()
            }

            QuotaSection(providers: model.quota)
            Divider()

            EngineSection(model: model)
            Divider()

            ActivitySection(activity: model.activity)
            Divider()

            Footer(model: model, openHistory: openHistory, quit: quit)
        }
    }
}

// MARK: - Header

private struct StatusHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(model.state.tint.opacity(0.16))
                    .frame(width: 34, height: 34)
                    // Bound to the state rather than a timer: the ring is only
                    // ever visible when something is genuinely happening.
                    .scaleEffect(model.state.isAnimating ? 1.18 : 1)
                    .opacity(model.state.isAnimating ? 0.55 : 1)
                    .animation(
                        model.state.isAnimating
                            ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                            : .default,
                        value: model.state.isAnimating
                    )
                Image(systemName: model.state.symbol)
                    .foregroundStyle(model.state.tint)
                    .font(.system(size: 14, weight: .medium))
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.state.label)
                    .font(.system(size: 13, weight: .semibold))
                Text(model.transcript.isEmpty
                     ? "Hold \(model.hotkey.label) to speak"
                     : model.transcript)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

/// Speech model assets are scoped per app identity, so the app must fetch its
/// own even when the CLI already has one. Presented as a one-click action
/// rather than an error, because it's something the app can fix itself.
private struct ModelDownload: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.blue)
                    .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Speech model needed")
                        .font(.system(size: 12, weight: .medium))
                    Text("A one-time on-device download. Nothing is sent to a server.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let progress = model.downloadProgress {
                ProgressView(value: progress, total: 1)
                    .progressViewStyle(.linear)
            } else {
                Button("Download Speech Model") {
                    Task { await model.installSpeechModel() }
                }
                .font(.system(size: 11))
            }
        }
        .padding(12)
    }
}

private struct SetupProblem: View {
    let message: String
    let permissionDenied: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(message)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                if permissionDenied {
                    Button("Open Microphone Settings") {
                        if let url = URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                        ) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.system(size: 11))
                }
            }
        }
        .padding(12)
    }
}

// MARK: - Quota

private struct QuotaSection: View {
    let providers: [ProviderUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QUOTA")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            if providers.isEmpty {
                Text("OpenUsage not reachable")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Only the binding window per provider: it's what decides routing,
            // and listing every window turns a glance into a reading task.
            ForEach(providers, id: \.providerId) { provider in
                if let window = provider.bindingWindow {
                    HStack(spacing: 8) {
                        Text(provider.displayName ?? provider.providerId)
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 52, alignment: .leading)
                        ProgressView(value: min(window.usedPercent, 100), total: 100)
                            .progressViewStyle(.linear)
                            .tint(tint(for: window.usedPercent))
                        Text("\(Int(window.usedPercent))%")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
        }
        .padding(12)
    }

    /// Mirrors the routing thresholds, so a colour means what the router means.
    private func tint(for percent: Double) -> Color {
        if percent >= 97 { return .red }
        if percent >= 85 { return .orange }
        return .green
    }
}

// MARK: - Engines

/// Which engine would run a task, and on which model.
///
/// Models are read from each CLI's own config, so this reflects what will
/// actually run rather than a guess. Where nothing is pinned it says "account
/// default" instead of naming a model it can't verify.
private struct EngineSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ENGINES")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                if model.unrestricted {
                    // Unrestricted execution is worth a persistent, visible
                    // reminder — it's easy to forget it's on.
                    Label("unrestricted", systemImage: "lock.open")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }

            ForEach(model.engines, id: \.id) { engine in
                HStack(spacing: 6) {
                    Image(systemName: engine.installed
                          ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(engine.installed ? .green : .orange)
                        .font(.system(size: 9))
                    Text(engine.name)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 78, alignment: .leading)

                    if engine.installed {
                        OverridePicker(
                            current: engine.model,
                            choices: model.modelChoices(for: engine.id),
                            display: EngineDisplay.model,
                            onSelect: { model.setModel($0, for: engine.id) }
                        )
                        Text("·").foregroundStyle(.quaternary).font(.system(size: 9))
                        OverridePicker(
                            current: engine.effort,
                            choices: model.effortChoices(for: engine.id),
                            display: EngineDisplay.effort,
                            onSelect: { model.setEffort($0, for: engine.id) }
                        )
                        Spacer(minLength: 0)
                    } else {
                        Text("not installed")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(12)
    }
}

// MARK: - Activity

private struct ActivitySection: View {
    let activity: [ActivityLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ACTIVITY")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            if activity.isEmpty {
                Text("Nothing yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(height: 120, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(activity.suffix(40)) { line in
                                Text(line.text)
                                    .font(.system(
                                        size: 11,
                                        design: line.isUser ? .default : .monospaced
                                    ))
                                    .fontWeight(line.isUser ? .medium : .regular)
                                    .foregroundStyle(line.isUser ? .primary : .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                    }
                    .frame(height: 120)
                    .onChange(of: activity.count) { _, _ in
                        if let last = activity.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .padding(12)
    }
}

/// A dropdown that overrides one engine setting, with "Default" meaning
/// "whatever the CLI's own config says" rather than a value of ours.
private struct OverridePicker: View {
    let current: String?
    let choices: [String]
    /// Turns a raw value into its label. The values themselves stay canonical —
    /// they're CLI arguments, not display text.
    let display: (String?) -> String
    let onSelect: (String?) -> Void

    var body: some View {
        if choices.isEmpty {
            Text(display(current))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else {
            Menu {
                Button("Default (from its own config)") { onSelect(nil) }
                Divider()
                ForEach(choices, id: \.self) { choice in
                    Button(display(choice)) { onSelect(choice) }
                }
            } label: {
                Text(display(current))
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

// MARK: - Projects

/// Which directory tasks run in.
///
/// "Anywhere" is a visible entry rather than a hidden mode: whether a task can
/// touch the whole Mac should never be something you have to infer.
private struct ProjectPicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.activeProject.isAnywhere ? "globe" : "folder")
                .font(.system(size: 10))
                .foregroundStyle(model.activeProject.isAnywhere ? .orange : .secondary)

            Menu {
                ForEach(model.projects) { project in
                    Button {
                        model.setActiveProject(project)
                    } label: {
                        if project.id == model.activeProject.id {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                }
                Divider()
                Button("Add Project…") { model.chooseProjectDirectory() }
                if !model.activeProject.isAnywhere, model.projects.count > 2 {
                    Button("Remove “\(model.activeProject.name)”") {
                        model.removeProject(model.activeProject)
                    }
                }
            } label: {
                Text(model.activeProject.name)
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer(minLength: 0)

            // Codex refuses to run outside a git repo, so flag it here rather
            // than letting the task fail later.
            if !model.activeProject.isAnywhere, !model.activeProject.isGitRepository {
                Label("not a git repo", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Footer

private struct Footer: View {
    @ObservedObject var model: AppModel
    let openHistory: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ProjectPicker(model: model)

            HStack {
                Button {
                    model.toggleSpeech()
                } label: {
                    Label(
                        model.speechEnabled ? "Speaking" : "Muted",
                        systemImage: model.speechEnabled ? "speaker.wave.2" : "speaker.slash"
                    )
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))

                Spacer()
            }

            HStack(spacing: 8) {
                Button("History", action: openHistory)
                Button("New Conversation") { model.newConversation() }
                Spacer()
                Button("Quit", action: quit)
            }
            .font(.system(size: 11))
        }
        .padding(12)
    }
}
