import Foundation

/// Vocabulary hints handed to the recogniser via `AnalysisContext`.
///
/// A general-purpose speech model is tuned for ordinary English and confidently
/// rewrites developer words into real ones. Measured on synthesised speech:
/// "git" → "get", "OAuth" → "Ooff", "dereference" → "D-reference",
/// "hysteresis" → "historesis", "Kubernetes" → "Cubernet's".
///
/// **These hints did not measurably help.** A/B runs with and against an empty
/// vocabulary produced byte-identical transcripts, including for "Kubernetes",
/// which is in the list. So either `contextualStrings` isn't consulted by
/// `SpeechTranscriber` in this configuration, or synthesised speech genuinely
/// sounds like the wrong word and no bias can rescue it. Both remain untested
/// against a real human voice — see `voxrouter transcribe --no-vocab` to A/B it.
///
/// Kept because the wiring matches the documented API and costs nothing at
/// runtime, but do not treat accurate technical transcription as a solved
/// problem on the strength of this list.
public enum TechnicalVocabulary {
    public static let `default`: [String] = versionControl + languages + tooling + concepts

    static let versionControl = [
        "git", "GitHub", "commit", "rebase", "cherry-pick", "stash", "merge",
        "branch", "pull request", "diff", "staged", "upstream", "origin",
    ]

    static let languages = [
        "Swift", "SwiftUI", "TypeScript", "JavaScript", "Python", "Rust", "Go",
        "Kotlin", "JSON", "YAML", "SQL", "HTML", "CSS", "regex",
    ]

    static let tooling = [
        "npm", "npx", "yarn", "pnpm", "Xcode", "SwiftPM", "Docker", "Kubernetes",
        "CI", "lint", "linter", "ESLint", "webpack", "Vite", "pytest", "XCTest",
        "Claude Code", "Codex", "LLM", "API", "CLI", "SDK", "MCP",
    ]

    static let concepts = [
        "OAuth", "async", "await", "actor", "closure", "enum", "struct",
        "protocol", "generic", "nullable", "dereference", "null pointer",
        "race condition", "deadlock", "hysteresis", "quota", "throttle",
        "middleware", "endpoint", "webhook", "schema", "migration", "refactor",
        "dependency", "singleton", "mutex", "idempotent", "serialize",
        "deserialize", "stack trace", "breakpoint", "unit test", "integration test",
    ]
}
