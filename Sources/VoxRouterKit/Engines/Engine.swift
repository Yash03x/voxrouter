import Foundation

/// Something an engine emitted while working.
public enum EngineEvent: Sendable {
    /// Human-meaningful progress worth speaking or showing.
    case status(String)
    /// Assistant prose (not code).
    case text(String)
    /// A tool/command the engine ran.
    case action(String)
    /// The engine's own session/thread id, so a retry on the *same* engine can
    /// resume rather than restart. Cross-engine handoff still goes through the
    /// journal, since neither engine can resume the other's session.
    case session(String)
    /// The engine hit its usage limit. Triggers failover.
    case rateLimited(detail: String, retryAfter: Date?)
    /// The engine can't run at all — expired login, missing credentials, broken
    /// install. Distinct from `failed`, which means the *task* went wrong.
    ///
    /// This distinction decides whether to fail over. A compile error will fail
    /// identically on the other engine, so retrying there just burns quota. An
    /// unusable engine is the opposite: the other one can do the job fine, and
    /// the user shouldn't be blocked because one CLI needs a re-login.
    case unavailable(detail: String)
    case failed(String)
    case finished(exitCode: Int32)
    /// Unparsed line, kept for the journal.
    case raw(String)
}

/// How much the engines may do without asking.
///
/// A voice dispatcher cannot answer an interactive approval prompt — there is no
/// one at the keyboard to say yes — so a task that triggers one simply stalls.
/// Autonomy has to be decided up front rather than per action.
public enum Autonomy: String, Codable, Sendable {
    /// Engines ask as usual. Correct for the CLI, unusable by voice.
    case prompt
    /// No prompts, but confined to the working directory where the engine
    /// supports it. Note Claude Code has no filesystem sandbox, so for Claude
    /// this is equivalent to `full`; only Codex is genuinely confined.
    case workspace
    /// No prompts, no sandbox. Anything the engine decides to run, runs.
    case full
}

public protocol Engine: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Resolved path to the executable, or nil when not installed.
    var binaryPath: URL? { get }
    /// How to install it, shown when missing.
    var installHint: String { get }
    /// Which model this engine will use, read from its own configuration.
    /// Nil when it can't be determined.
    var configuredModel: String? { get }

    func arguments(for task: String, resuming sessionId: String?) -> [String]
    /// Parse one line of output into an event.
    func parse(line: String) -> EngineEvent
}

extension Engine {
    public var isInstalled: Bool { binaryPath != nil }
}

// MARK: - Binary discovery

enum BinaryLocator {
    /// Resolves a binary without shelling out to `which` — spawning a shell per
    /// lookup is measurable at startup and pointless when we can stat directly.
    static func find(_ names: [String], extraPaths: [String] = []) -> URL? {
        let fm = FileManager.default
        var searchPaths = extraPaths
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            searchPaths += envPath.split(separator: ":").map(String.init)
        }
        // A GUI-launched .app inherits a minimal PATH, so include the usual
        // suspects explicitly.
        searchPaths += [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/.bun/bin",
        ]

        for dir in searchPaths {
            for name in names {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    static func firstExecutable(_ absolutePaths: [String]) -> URL? {
        let fm = FileManager.default
        for path in absolutePaths where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

// MARK: - Rate limit sniffing

enum RateLimitSniffer {
    /// Substrings that mean "you are out of quota" rather than "a request
    /// failed".
    ///
    /// These apply to **plain-text output only** — structured protocol events
    /// are classified by their own fields. That separation is load-bearing:
    /// `rate_limit` used to be matched here and fired on Claude's healthy
    /// `rate_limit_event` (`status: "allowed"`), discarding a completed run and
    /// re-doing it on the other engine. A false positive is not cheap; it costs
    /// a duplicate task and double quota.
    ///
    /// Bare status codes like "429" are excluded for the same reason: they
    /// collide with token counts, byte sizes, timestamps and ids.
    static let patterns: [String] = [
        "rate limit exceeded",
        "usage limit",
        "usage_limit_reached",
        "quota exceeded",
        "insufficient_quota",
        "too many requests",
        "you've reached your usage limit",
        "limit reached",
    ]

    static func looksRateLimited(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return patterns.contains { lowered.contains($0) }
    }

    /// Signs the engine itself can't run, as opposed to the task failing.
    /// Observed in the wild: `claude` prints "Failed to authenticate: OAuth
    /// session expired and could not be refreshed" and exits 1.
    static let unavailablePatterns: [String] = [
        "failed to authenticate",
        "oauth session expired",
        "session expired",
        "not logged in",
        "please log in",
        "please run /login",
        "authentication required",
        "unauthorized",
        "invalid api key",
        "no credentials",
        "credentials not found",
        // Status codes only with context — a bare "401" collides with token
        // counts, byte sizes and ids.
        "401 unauthorized",
        "403 forbidden",
        "status 401",
        "status 403",
    ]

    static func looksUnavailable(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return unavailablePatterns.contains { lowered.contains($0) }
    }

    /// Classifies a line as a quota or availability problem, or nil if it's
    /// neither. Quota is checked first: it's the more specific diagnosis and
    /// carries a reset time.
    static func classify(_ line: String) -> EngineEvent? {
        if looksRateLimited(line) {
            return .rateLimited(detail: line, retryAfter: retryAfter(in: line))
        }
        if looksUnavailable(line) {
            return .unavailable(detail: line)
        }
        return nil
    }

    /// Pull a reset time out of a line when one is present. Handles unix
    /// seconds (`resets_at`, `reset_at`) and second offsets
    /// (`resets_in_seconds`, `retry_after`).
    static func retryAfter(in line: String, now: Date = Date()) -> Date? {
        if let seconds = firstNumber(after: ["resets_at", "reset_at", "resetsAt"], in: line),
           seconds > 1_000_000_000 {
            return Date(timeIntervalSince1970: seconds)
        }
        if let offset = firstNumber(
            after: ["resets_in_seconds", "retry_after", "retry-after", "retryAfter"],
            in: line
        ) {
            return now.addingTimeInterval(offset)
        }
        return nil
    }

    private static func firstNumber(after keys: [String], in line: String) -> Double? {
        for key in keys {
            guard let keyRange = line.range(of: key, options: .caseInsensitive) else { continue }
            let tail = line[keyRange.upperBound...].prefix(40)
            var digits = ""
            var seenDigit = false
            for char in tail {
                if char.isNumber || (char == "." && seenDigit) {
                    digits.append(char)
                    seenDigit = true
                } else if seenDigit {
                    break
                }
            }
            if let value = Double(digits) { return value }
        }
        return nil
    }
}
