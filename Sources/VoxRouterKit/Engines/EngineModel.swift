import Foundation

/// Best-effort answer to "which model will this actually use?"
///
/// Read from each CLI's own configuration rather than guessed, because that's
/// the value the CLI will act on. Where nothing is pinned, the CLI follows the
/// account default and this says so rather than inventing a name — claiming a
/// specific model that isn't the one running would be worse than admitting
/// uncertainty.
public enum EngineModel {
    /// `~/.codex/config.toml` → `model = "…"`.
    public static func codexModel() -> String? {
        codexConfig().flatMap { tomlValue(key: "model", in: $0) }
    }

    public static func codexEffort() -> String? {
        codexConfig().flatMap { tomlValue(key: "model_reasoning_effort", in: $0) }
    }

    private static func codexConfig() -> String? {
        let path = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/config.toml")
        return try? String(contentsOf: path, encoding: .utf8)
    }

    /// `~/.claude/settings.json` → `model`, else the account default.
    public static func claudeModel() -> String? {
        claudeSettings()?["model"] as? String ?? "account default"
    }

    public static func claudeEffort() -> String? {
        claudeSettings()?["effortLevel"] as? String
    }

    private static func claudeSettings() -> [String: Any]? {
        let path = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Minimal TOML scalar lookup at top level.
    ///
    /// Deliberately not a TOML parser: only two top-level keys are needed, and a
    /// dependency (or a hand-rolled parser) would be far more surface than the
    /// job justifies. Stops at the first table header so a `model` key nested
    /// under `[profiles.x]` isn't mistaken for the global one.
    static func tomlValue(key: String, in text: String) -> String? {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            guard line.hasPrefix(key) else { continue }
            let remainder = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard remainder.hasPrefix("=") else { continue }
            let value = remainder.dropFirst()
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
