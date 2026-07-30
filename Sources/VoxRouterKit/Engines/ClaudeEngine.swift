import Foundation

/// Claude Code, driven headless via `claude -p` with streaming JSON.
public struct ClaudeEngine: Engine {
    public let id = "claude"
    public let displayName = "Claude Code"
    public var extraArgs: [String]
    /// Overrides the model for this run. Nil follows the CLI's own config.
    public var modelOverride: String?
    /// Overrides reasoning effort. Nil follows `~/.claude/settings.json`.
    public var effortOverride: String?

    public init(
        extraArgs: [String] = [],
        modelOverride: String? = nil,
        effortOverride: String? = nil
    ) {
        self.extraArgs = extraArgs
        self.modelOverride = modelOverride
        self.effortOverride = effortOverride
    }

    /// Every model alias the CLI accepts, read out of its binary.
    ///
    /// Not curated: an unpinned family alias resolves to whatever is newest,
    /// which is a decision the user should get to make rather than have made
    /// for them. Where a version exists in both dash and compact form
    /// (`opus-4-5` / `opus45`) only one is listed — they select the same model,
    /// and offering both would double the menu for nothing. The compact form is
    /// used where no dash form exists.
    ///
    /// `opusplan` is Claude Code's mixed mode: Opus for planning, Sonnet for
    /// execution.
    /// Grouped by family, each family's unversioned alias first. One ordered
    /// list rather than "latest" and "pinned" sections — splitting them made a
    /// single menu look like two.
    public static let modelChoices = [
        "opus", "opus-5", "opus-4-8", "opus-4-7", "opus-4-6", "opus-4-5",
        "opus41", "opus40", "opusplan",
        "sonnet", "sonnet-5", "sonnet-4-6", "sonnet-4-5", "sonnet37", "sonnet35",
        "haiku", "haiku45", "haiku35",
        "fable", "fable-5",
    ]

    /// `claude --help` documents `--effort <level>` but not its values; these
    /// are the accepted levels, read out of the CLI bundle.
    public static let effortChoices = ["minimal", "low", "medium", "high", "xhigh", "max"]

    public var binaryPath: URL? {
        BinaryLocator.find(["claude"], extraPaths: [NSHomeDirectory() + "/.claude/local"])
    }

    public var installHint: String {
        "npm i -g @anthropic-ai/claude-code"
    }

    public var configuredModel: String? {
        // An override is what will actually run, so report that in preference
        // to the CLI's own configured value.
        if let modelOverride, !modelOverride.isEmpty { return modelOverride }
        return EngineModel.claudeModel()
    }

    public var configuredEffort: String? {
        if let effortOverride, !effortOverride.isEmpty { return effortOverride }
        return EngineModel.claudeEffort()
    }

    public func arguments(for task: String, resuming sessionId: String?) -> [String] {
        var args = ["-p", task, "--output-format", "stream-json", "--verbose"]
        if let sessionId {
            args += ["--resume", sessionId]
        }
        if let modelOverride, !modelOverride.isEmpty {
            args += ["--model", modelOverride]
        }
        if let effortOverride, !effortOverride.isEmpty {
            args += ["--effort", effortOverride]
        }
        return args + extraArgs
    }

    public func parse(line: String) -> EngineEvent {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .raw("") }

        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Non-JSON on stdout is usually a plain error from the CLI itself.
            if let classified = RateLimitSniffer.classify(trimmed) { return classified }
            return .raw(trimmed)
        }

        let type = object["type"] as? String ?? ""

        // `system`/`init` carries the session id, which lets a same-engine retry
        // resume instead of starting over.
        if type == "system", let sessionId = object["session_id"] as? String {
            return .session(sessionId)
        }

        // Claude emits a `rate_limit_event` on healthy runs too, carrying
        // `status: "allowed"`. It must be read structurally — a text sniffer
        // sees "rate_limit" and declares failure, which threw away a completed
        // run and re-did it on the other engine, doubling quota spend.
        if type == "rate_limit_event" {
            guard let info = object["rate_limit_info"] as? [String: Any] else {
                return .raw(trimmed)
            }
            let status = (info["status"] as? String)?.lowercased() ?? "allowed"
            guard status != "allowed" else { return .raw(trimmed) }
            var resetsAt: Date?
            if let seconds = info["resetsAt"] as? Double, seconds > 1_000_000_000 {
                resetsAt = Date(timeIntervalSince1970: seconds)
            }
            let window = (info["rateLimitType"] as? String).map { " (\($0))" } ?? ""
            return .rateLimited(detail: "claude rate limit \(status)\(window)", retryAfter: resetsAt)
        }

        if type == "result" {
            if let subtype = object["subtype"] as? String, subtype != "success" {
                let detail = object["result"] as? String ?? subtype
                if let classified = RateLimitSniffer.classify(detail) { return classified }
                if let classified = RateLimitSniffer.classify(subtype) { return classified }
                return .failed(detail)
            }
            if let result = object["result"] as? String {
                return .text(result)
            }
            return .status("done")
        }

        if type == "error" || object["is_error"] as? Bool == true {
            let detail = (object["error"] as? String)
                ?? (object["message"] as? String)
                ?? trimmed
            if let classified = RateLimitSniffer.classify(detail) { return classified }
            return .failed(detail)
        }

        if type == "assistant",
           let message = object["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for block in content {
                if block["type"] as? String == "tool_use", let name = block["name"] as? String {
                    return .action(Self.describeToolUse(
                        name: name,
                        input: block["input"] as? [String: Any]
                    ))
                }
            }
            let prose = content
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: " ")
            if !prose.isEmpty { return .text(prose) }
        }

        // Anything else (system init, user echoes, tool results) is journal-only.
        //
        // Deliberately NOT text-sniffed: this is structured protocol JSON, and
        // every genuine failure arrives through the `result`, `error` or
        // `rate_limit_event` branches above. Running a substring matcher over
        // arbitrary JSON is exactly how a healthy `rate_limit_event` got read as
        // a limit, discarding a finished run and redoing it on the other engine.
        // Text sniffing is for plain-text output only.
        return .raw(trimmed)
    }

    /// Turns a tool call into a line another agent could act on.
    ///
    /// The tool *name* alone is near-useless in a handoff — "it used Bash three
    /// times" tells a replacement nothing. The arguments are what matter, so
    /// the identifying one is pulled out per tool and truncated. Bulk content
    /// (`old_string`, file bodies) is deliberately omitted: it would bury the
    /// journal and a replacement should read the file rather than trust a log.
    static func describeToolUse(name: String, input: [String: Any]?) -> String {
        guard let input else { return name }

        func string(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        switch name {
        case "Bash", "BashOutput":
            if let command = string("command") { return "Bash: \(clip(command))" }

        case "Read", "Write", "NotebookEdit":
            if let path = string("file_path") { return "\(name): \(shorten(path))" }

        case "Edit", "MultiEdit":
            if let path = string("file_path") { return "Edit: \(shorten(path))" }

        case "Grep":
            let pattern = string("pattern").map { "\"\(clip($0, to: 60))\"" } ?? ""
            if let path = string("path") { return "Grep: \(pattern) in \(shorten(path))" }
            if !pattern.isEmpty { return "Grep: \(pattern)" }

        case "Glob":
            if let pattern = string("pattern") { return "Glob: \(clip(pattern, to: 60))" }

        case "WebFetch":
            if let url = string("url") { return "WebFetch: \(clip(url, to: 80))" }

        case "WebSearch":
            if let query = string("query") { return "WebSearch: \(clip(query, to: 60))" }

        case "Task", "Agent":
            if let description = string("description") { return "Task: \(clip(description))" }

        default:
            // Unknown tool: fall back to whichever common argument it carries.
            for key in ["file_path", "path", "command", "query", "pattern", "description"] {
                if let value = string(key) { return "\(name): \(clip(value))" }
            }
        }
        return name
    }

    private static func clip(_ text: String, to limit: Int = 120) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    /// Absolute paths are mostly noise in a log; the tail identifies the file.
    private static func shorten(_ path: String) -> String {
        let components = path.split(separator: "/")
        guard components.count > 2 else { return path }
        return components.suffix(2).joined(separator: "/")
    }
}
