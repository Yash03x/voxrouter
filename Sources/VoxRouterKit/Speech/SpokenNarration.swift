import Foundation

/// Decides what the assistant says out loud.
///
/// Two jobs, both about restraint:
///
/// 1. **Most updates are not worth speaking.** An engine emits dozens of tool
///    calls per task; narrating them would be unbearable. Speech is reserved for
///    the four moments that change what the user should do: it started, it
///    switched engines, it finished, it broke.
/// 2. **Engine prose is written to be read, not heard.** It contains code
///    fences, file paths and markdown, all of which are noise aloud. `speakable`
///    strips them and truncates, because the screen already has the full text.
public enum SpokenNarration {
    public enum Verbosity: String, Codable, Sendable {
        /// Only what changes what you'd do next: the result, a failure, or
        /// being blocked. The default.
        case minimal
        /// Also announces which engine picked the task up and when it switches.
        case detailed
    }

    /// The spoken form of a dispatch update, or nil if it shouldn't be spoken.
    public static func line(
        for update: DispatchUpdate,
        verbosity: Verbosity = .minimal
    ) -> String? {
        switch update {
        case .routed(let engine, _):
            // Silent by default. Which engine took the task is the router's
            // business — announcing it defeats the point of routing
            // automatically, and you already know you just asked for something.
            guard verbosity == .detailed else { return nil }
            return "Working on it with \(spokenEngineName(engine))."

        case .handoff(_, let to, _):
            // Same reasoning: a mid-task switch is an implementation detail.
            // The panel shows it; saying it aloud is noise.
            guard verbosity == .detailed else { return nil }
            return "Switching to \(spokenEngineName(to)); the other one ran out of quota."

        case .succeeded(_, let summary):
            // Straight to the answer. "Done." in front of it is filler — the
            // answer already tells you it finished, and hearing the same word
            // before every reply gets old fast. Kept only when there's nothing
            // to say, where silence would be ambiguous.
            guard let summary, !summary.isEmpty else { return "Done." }
            let spoken = speakable(summary)
            return spoken.isEmpty ? "Done." : spoken

        case .failed(let reason):
            return "That didn't work. \(speakable(reason, maxCharacters: 160))"

        case .blocked(let retryAfter):
            guard let retryAfter else {
                return "Both engines are out of quota."
            }
            return "Both engines are out of quota. They reset \(relativePhrase(retryAfter))."

        case .action, .text:
            // Deliberately silent — this is the chatter that would make an
            // always-on assistant intolerable.
            return nil
        }
    }

    /// Converts written-for-the-screen text into something worth hearing.
    public static func speakable(_ text: String, maxCharacters: Int = 240) -> String {
        var result = text

        // Fenced code: drop entirely. Reading a diff aloud helps nobody.
        result = result.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: " ",
            options: .regularExpression
        )
        // An unterminated fence — drop to the end.
        result = result.replacingOccurrences(
            of: "```[\\s\\S]*",
            with: " ",
            options: .regularExpression
        )
        // Inline code: keep the words, lose the backticks.
        result = result.replacingOccurrences(of: "`", with: "")

        // Markdown structure that has no spoken equivalent.
        result = result.replacingOccurrences(
            of: "^\\s{0,3}#{1,6}\\s*",
            with: "",
            options: [.regularExpression]
        )
        result = result.replacingOccurrences(
            of: "(?m)^\\s*[-*+]\\s+",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "\\*{1,2}([^*]+)\\*{1,2}",
            with: "$1",
            options: .regularExpression
        )
        // Markdown links: keep the label, drop the URL.
        result = result.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^)]*\\)",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "https?://\\S+",
            with: "a link",
            options: .regularExpression
        )

        result = shortenPaths(in: result)

        result = result.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return truncate(result, to: maxCharacters)
    }

    /// "Sources/VoxRouterKit/Audio/VoiceGate.swift" → "VoiceGate.swift".
    /// Hearing a full path spelled out is useless; the filename is the part that
    /// identifies it.
    static func shortenPaths(in text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false)
            .map { token -> Substring in
                guard token.contains("/"), token.count > 1 else { return token }
                // Leave bare "and/or"-style words alone.
                guard token.contains(".") || token.contains("/") && token.filter({ $0 == "/" }).count > 1
                else { return token }
                let trailing = token.last.map { ",.;:!?".contains($0) } ?? false
                let core = trailing ? token.dropLast() : token
                guard let name = core.split(separator: "/").last, !name.isEmpty else { return token }
                return trailing ? Substring(name + String(token.last!)) : name
            }
            .joined(separator: " ")
    }

    /// Truncates on a sentence boundary when possible — cutting mid-clause
    /// sounds like a glitch.
    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let clipped = String(text.prefix(limit))
        if let lastStop = clipped.lastIndex(where: { ".!?".contains($0) }),
           clipped.distance(from: clipped.startIndex, to: lastStop) > limit / 3 {
            return String(clipped[...lastStop])
        }
        if let lastSpace = clipped.lastIndex(of: " ") {
            return String(clipped[..<lastSpace]) + "…"
        }
        return clipped + "…"
    }

    static func spokenEngineName(_ id: String) -> String {
        switch id.lowercased() {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default: return id
        }
    }

    static func relativePhrase(_ date: Date, from now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "shortly" }
        if seconds < 90 { return "in about a minute" }
        if seconds < 3600 { return "in about \(Int((seconds / 60).rounded())) minutes" }
        if seconds < 86_400 {
            let hours = Int((seconds / 3600).rounded())
            return hours == 1 ? "in about an hour" : "in about \(hours) hours"
        }
        let days = Int((seconds / 86_400).rounded())
        return days == 1 ? "tomorrow" : "in about \(days) days"
    }
}
