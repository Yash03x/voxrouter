import Foundation

/// Presentation names for model and effort values.
///
/// The stored and passed-through values stay exactly as each CLI expects them —
/// `--model sonnet-4-5`, `model_reasoning_effort="xhigh"` — because they're
/// arguments, not labels. This is only what the user reads.
public enum EngineDisplay {
    public static let defaultLabel = "Default"

    private static let claudeFamilies = ["opus", "sonnet", "haiku", "fable"]

    private static let effortNames: [String: String] = [
        "minimal": "Minimal",
        "low": "Low",
        "medium": "Medium",
        "high": "High",
        // Spelled out — "Xhigh" reads like a mistake.
        "xhigh": "Extra High",
        "max": "Max",
        "ultra": "Ultra",
    ]

    // MARK: - Models

    /// Renders every alias the same way — `Family Version` — so a menu of
    /// twenty doesn't mix "Opus" with "opus-4-8" and "sonnet37".
    public static func model(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return defaultLabel }
        // What `EngineModel` reports when a CLI pins nothing itself.
        if raw == "account default" { return defaultLabel }

        let value = raw.lowercased()
        if let claude = claudeAlias(value) { return claude }
        if value.hasPrefix("gpt") { return openAIName(value) }
        // Anything unrecognised — a full id like claude-haiku-4-5-20251001 —
        // is shown verbatim: title-casing an identifier makes it look mistyped.
        return raw
    }

    /// `opus` → Opus (latest) · `opus-4-8` → Opus 4.8 · `opus41` → Opus 4.1 ·
    /// `opusplan` → Opus Plan
    ///
    /// The "(latest)" matters. Measured against the CLI, `opus` resolves to
    /// `claude-opus-5` and `opus-5` to the same thing — so today they're
    /// identical and the menu looked like it was repeating itself. They diverge
    /// the moment a new Opus ships: the bare alias follows it, the pinned one
    /// doesn't. Labelling it is the difference between a duplicate and a choice.
    private static func claudeAlias(_ value: String) -> String? {
        for family in claudeFamilies where value.hasPrefix(family) {
            let name = family.capitalized
            var suffix = String(value.dropFirst(family.count))

            if suffix.isEmpty { return "\(name) (latest)" }
            // Claude Code's mixed mode: Opus plans, Sonnet executes.
            if suffix == "plan" { return "\(name) Plan" }

            suffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard !suffix.isEmpty else { return name }

            // Dash form: "4-8" → 4.8, "5" → 5
            if suffix.contains("-") {
                var parts = suffix.split(separator: "-").map(String.init)
                guard parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }

                // A trailing 8-digit group is a release date, not a version
                // component: `sonnet-4-5-20250929` should read
                // "Sonnet 4.5 (2025-09-29)", not "Sonnet 4.5.20250929".
                var dateSuffix = ""
                if let last = parts.last, last.count == 8 {
                    parts.removeLast()
                    let year = last.prefix(4)
                    let month = last.dropFirst(4).prefix(2)
                    let day = last.suffix(2)
                    dateSuffix = " (\(year)-\(month)-\(day))"
                }
                return "\(name) \(parts.joined(separator: "."))\(dateSuffix)"
            }
            // Compact form: "45" → 4.5, "5" → 5
            guard suffix.allSatisfy(\.isNumber) else { return nil }
            if suffix.count >= 2 {
                let major = suffix.prefix(1)
                let minor = suffix.dropFirst()
                return "\(name) \(major).\(minor)"
            }
            return "\(name) \(suffix)"
        }
        return nil
    }

    /// `gpt-5.6` → GPT-5.6 · `gpt-5.1-codex-max` → GPT-5.1 Codex Max
    private static func openAIName(_ value: String) -> String {
        let parts = value.split(separator: "-").map(String.init)
        guard let version = parts.dropFirst().first else { return value.uppercased() }
        let head = "GPT-\(version)"
        let rest = parts.dropFirst(2).map { $0.capitalized }
        return ([head] + rest).joined(separator: " ")
    }

    // MARK: - Effort

    public static func effort(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return defaultLabel }
        return effortNames[raw.lowercased()] ?? raw.capitalized
    }
}
