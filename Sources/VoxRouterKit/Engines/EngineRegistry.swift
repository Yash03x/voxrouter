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

    /// Rescans the engine binaries for model names if they've changed since
    /// last time. Slow on a miss (~3s per binary), so call it off the main path
    /// — at launch, not when a menu opens.
    public static func refreshCatalog(config: Config) {
        for engine in all(config: config) {
            guard let binary = engine.binaryPath else { continue }
            ModelCatalog.refresh(for: engine.id, binary: binary)
        }
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
    /// plus anything discovered in the CLI binary, plus whatever the CLI is
    /// currently configured with, plus any the user added to
    /// `engineModelChoices`. Deduplicated, order preserved.
    ///
    /// The built-in list comes first so the familiar names stay at the top and
    /// in family order; discovered names that aren't already known are appended
    /// rather than interleaved, since a new release should be visible but not
    /// reshuffle the menu.
    public static func modelChoices(for engineId: String, config: Config) -> [String] {
        var choices: [String] = []
        switch engineId {
        case "claude": choices = ClaudeEngine.modelChoices
        case "codex": choices = CodexEngine.modelChoices
        default: break
        }

        // Only the cache is read here — scanning takes seconds and must not
        // happen while a menu is opening. `refreshCatalog` does that in the
        // background.
        //
        // Deduplicated by *display name*, not by string: discovery finds both
        // `opus-4-5` and `opus45`, which are two spellings of one model. String
        // deduping would let both into the menu; comparing what the user
        // actually reads ("Opus 4.5") collapses them, so only genuinely new
        // models get appended.
        if let binary = all(config: config).first(where: { $0.id == engineId })?.binaryPath,
           let discovered = ModelCatalog.cached(for: engineId, binary: binary) {
            var known = Set(choices.map(EngineDisplay.model))
            for model in discovered where known.insert(EngineDisplay.model(model)).inserted {
                choices.append(model)
            }
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
