import Foundation

/// Codex, driven headless via `codex exec --json`.
///
/// Falls back to the binary bundled inside ChatGPT.app, which is a full
/// codex-cli and is present even when nothing is on PATH.
///
/// Handles two wire schemas, because they vary by codex version and the user's
/// build can change under us:
///   - current (0.146+): `thread.started` / `turn.started` /
///     `item.completed{item:{type,...}}` / `turn.completed`
///   - older: `event_msg` with a nested `msg.type` of `agent_message`,
///     `exec_command_begin`, `token_count`, ...
public struct CodexEngine: Engine {
    public let id = "codex"
    public let displayName = "Codex"
    public var extraArgs: [String]
    /// Overrides the model for this run. Nil follows `~/.codex/config.toml`.
    public var modelOverride: String?

    public init(extraArgs: [String] = [], modelOverride: String? = nil) {
        self.extraArgs = extraArgs
        self.modelOverride = modelOverride
    }

    /// Deliberately empty by default. Codex model names aren't enumerable from
    /// the CLI, and offering invented ones would produce runs that fail at
    /// launch — the app lists whatever `config.toml` actually specifies, plus
    /// anything the user adds to `engineModelChoices`.
    public static let modelChoices: [String] = []

    public var binaryPath: URL? {
        if let onPath = BinaryLocator.find(["codex"], extraPaths: [NSHomeDirectory() + "/.codex/bin"]) {
            return onPath
        }
        return BinaryLocator.firstExecutable([
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            NSHomeDirectory() + "/Applications/ChatGPT.app/Contents/Resources/codex",
        ])
    }

    public var installHint: String {
        "npm i -g @openai/codex  (or install ChatGPT.app, which bundles codex-cli)"
    }

    public var configuredModel: String? {
        if let modelOverride, !modelOverride.isEmpty { return modelOverride }
        return EngineModel.codex()
    }

    /// Codex requires the prompt last, after flags.
    ///
    /// Note `--skip-git-repo-check` is deliberately *not* added by default:
    /// codex refuses to run in an untrusted directory, and that guard is worth
    /// keeping. Add it via `engineArgs["codex"]` if you really want it.
    public func arguments(for task: String, resuming sessionId: String?) -> [String] {
        var args = ["exec", "--json"]
        if let sessionId {
            args += ["resume", sessionId]
        }
        if let modelOverride, !modelOverride.isEmpty {
            args += ["--model", modelOverride]
        }
        return args + extraArgs + [task]
    }

    public func parse(line: String) -> EngineEvent {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .raw("") }

        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Self.sniff(trimmed)
        }

        let type = object["type"] as? String ?? ""

        // --- Current schema ---
        // Note every branch below classifies structurally. Text sniffing is
        // reserved for the non-JSON path; running it over protocol JSON reads
        // healthy status events as failures.
        switch type {
        case "thread.started":
            if let threadId = object["thread_id"] as? String {
                return .session(threadId)
            }
            return .raw(trimmed)

        case "turn.started":
            return .status("started")

        case "turn.completed":
            return .status("done")

        case "turn.failed":
            let detail = Self.nestedMessage(object) ?? trimmed
            return Self.classifyFailure(detail)

        case "item.completed", "item.started", "item.updated":
            guard let item = object["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return .raw(trimmed) }
            // Only report items once, on completion, or every action is
            // announced three times.
            guard type == "item.completed" else { return .raw(trimmed) }
            return parseItem(itemType, item, rawLine: trimmed)

        default:
            break
        }

        // --- Older schema ---
        if let msg = object["msg"] as? [String: Any] {
            return parseLegacy(msg, rawLine: trimmed)
        }

        return Self.sniff(trimmed)
    }

    // MARK: - Current schema items

    private func parseItem(
        _ itemType: String,
        _ item: [String: Any],
        rawLine: String
    ) -> EngineEvent {
        let text = (item["text"] as? String) ?? (item["message"] as? String)

        switch itemType {
        case "agent_message":
            return text.map(EngineEvent.text) ?? .raw(rawLine)

        case "reasoning":
            // Journal-only: useful context on a handoff, too noisy to speak.
            return .raw(rawLine)

        case "command_execution":
            let command = (item["command"] as? String)
                ?? (item["command"] as? [String])?.joined(separator: " ")
            return command.map(EngineEvent.action) ?? .raw(rawLine)

        case "file_change":
            if let changes = item["changes"] as? [[String: Any]] {
                let paths = changes.compactMap { $0["path"] as? String }
                if !paths.isEmpty {
                    return .action("edit \(paths.joined(separator: ", "))")
                }
            }
            return .action("file change")

        case "mcp_tool_call":
            let tool = (item["tool"] as? String) ?? (item["name"] as? String) ?? "tool"
            return .action(tool)

        case "web_search":
            return .action("web search")

        case "todo_list":
            return .raw(rawLine)

        case "error":
            // Not necessarily fatal. Codex emits an `error` item for advisory
            // warnings too (e.g. "Under-development features enabled:
            // chronicle"), and the turn still completes. Treating these as
            // failures would break every run on a config that has any enabled.
            // Real failures arrive as `turn.failed` or a non-zero exit.
            guard let text else { return .raw(rawLine) }
            // classify() returns nil for advisory text, so a warning still
            // lands on .status rather than killing the run.
            return RateLimitSniffer.classify(text) ?? .status(text)

        default:
            return .raw(rawLine)
        }
    }

    // MARK: - Older schema


    private func parseLegacy(_ msg: [String: Any], rawLine: String) -> EngineEvent {
        switch msg["type"] as? String ?? "" {
        case "error", "stream_error":
            let detail = (msg["message"] as? String) ?? rawLine
            return Self.classifyFailure(detail)

        case "token_count":
            // Carries the authoritative rate_limits block in older builds.
            if let limits = msg["rate_limits"] as? [String: Any] {
                if let reached = limits["rate_limit_reached_type"] as? String, !reached.isEmpty {
                    return .rateLimited(
                        detail: "codex reported limit reached: \(reached)",
                        retryAfter: Self.resetDate(from: limits)
                    )
                }
                if let primary = limits["primary"] as? [String: Any],
                   let used = primary["used_percent"] as? Double, used >= 100 {
                    return .rateLimited(
                        detail: "codex primary window at \(Int(used))%",
                        retryAfter: Self.resetDate(from: limits)
                    )
                }
            }
            return .raw(rawLine)

        case "agent_message":
            if let message = msg["message"] as? String, !message.isEmpty {
                return .text(message)
            }
            return .raw(rawLine)

        case "exec_command_begin":
            if let command = msg["command"] as? [String] {
                return .action(command.joined(separator: " "))
            }
            if let command = msg["command"] as? String {
                return .action(command)
            }
            return .raw(rawLine)

        case "task_started":
            return .status("started")

        case "task_complete":
            if let message = msg["last_agent_message"] as? String, !message.isEmpty {
                return .text(message)
            }
            return .status("done")

        default:
            // Structured JSON: classified by event type above, never sniffed.
            return .raw(rawLine)
        }
    }

    // MARK: - Helpers

    private static func sniff(_ line: String) -> EngineEvent {
        RateLimitSniffer.classify(line) ?? .raw(line)
    }

    private static func classifyFailure(_ detail: String) -> EngineEvent {
        RateLimitSniffer.classify(detail) ?? .failed(detail)
    }

    private static func nestedMessage(_ object: [String: Any]) -> String? {
        if let message = object["message"] as? String { return message }
        if let error = object["error"] as? [String: Any] {
            return error["message"] as? String
        }
        return nil
    }

    private static func resetDate(from limits: [String: Any]) -> Date? {
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any] else { continue }
            if let resetsAt = window["resets_at"] as? Double, resetsAt > 1_000_000_000 {
                return Date(timeIntervalSince1970: resetsAt)
            }
            if let seconds = window["resets_in_seconds"] as? Double {
                return Date().addingTimeInterval(seconds)
            }
        }
        return nil
    }
}
