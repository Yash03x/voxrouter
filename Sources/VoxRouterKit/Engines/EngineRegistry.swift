import Foundation

public enum EngineRegistry {
    /// Every engine we know how to drive, in a stable order. Availability is a
    /// separate question — ask `isInstalled`.
    public static func all(config: Config) -> [any Engine] {
        [
            ClaudeEngine(
                extraArgs: config.engineArgs["claude"] ?? [],
                modelOverride: config.engineModels["claude"],
                effortOverride: config.engineEfforts["claude"]
            ),
            CodexEngine(
                extraArgs: config.engineArgs["codex"] ?? [],
                modelOverride: config.engineModels["codex"],
                effortOverride: config.engineEfforts["codex"]
            ),
        ]
    }

    /// Effort levels an engine accepts, ascending.
    public static func effortChoices(for engineId: String) -> [String] {
        switch engineId {
        case "claude": return ClaudeEngine.effortChoices
        case "codex": return CodexEngine.effortChoices
        default: return []
        }
    }

    /// Models offered in the app's picker for an engine: its built-in choices,
    /// plus whatever the CLI is currently configured with, plus any the user
    /// added to `engineModelChoices`. Deduplicated, order preserved.
    public static func modelChoices(for engineId: String, config: Config) -> [String] {
        var choices: [String] = []
        switch engineId {
        case "claude": choices = ClaudeEngine.modelChoices
        case "codex": choices = CodexEngine.modelChoices
        default: break
        }
        // The CLI's own configured model is always a valid option.
        if let current = EngineRegistry.all(config: config)
            .first(where: { $0.id == engineId })?.configuredModel {
            // Strip any " · effort" suffix — that's display detail, not a name.
            let bare = current.components(separatedBy: " · ").first ?? current
            if bare != "account default" { choices.append(bare) }
        }
        choices += config.engineModelChoices[engineId] ?? []

        var seen = Set<String>()
        return choices.filter { seen.insert($0).inserted }
    }

    public static func engine(id: String, config: Config) -> (any Engine)? {
        all(config: config).first { $0.id == id }
    }

    public static func installedIds(config: Config) -> Set<String> {
        Set(all(config: config).filter(\.isInstalled).map(\.id))
    }
}
