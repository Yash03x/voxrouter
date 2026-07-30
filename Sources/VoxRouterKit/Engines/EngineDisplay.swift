import Foundation

/// Presentation names for model and effort values.
///
/// The stored and passed-through values stay exactly as each CLI expects them —
/// `--model sonnet`, `model_reasoning_effort="xhigh"` — because they're
/// arguments, not labels. This is only what the user reads.
public enum EngineDisplay {
    /// Family aliases get proper capitalisation. Concrete model ids are left
    /// alone: `claude-haiku-4-5-20251001` is an identifier, and title-casing it
    /// would make it look like a typo.
    private static let modelNames: [String: String] = [
        "opus": "Opus",
        "sonnet": "Sonnet",
        "haiku": "Haiku",
        "fable": "Fable",
    ]

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

    public static let defaultLabel = "Default"

    public static func model(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return defaultLabel }
        // What `EngineModel` returns when a CLI pins nothing itself.
        if raw == "account default" { return defaultLabel }
        if let known = modelNames[raw.lowercased()] { return known }
        // OpenAI ids read badly lowercased but shouldn't be otherwise reshaped.
        if raw.lowercased().hasPrefix("gpt") {
            return "GPT" + raw.dropFirst(3)
        }
        return raw
    }

    public static func effort(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return defaultLabel }
        return effortNames[raw.lowercased()] ?? raw.capitalized
    }
}
