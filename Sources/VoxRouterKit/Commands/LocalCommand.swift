import Foundation

/// Something the assistant does itself, without dispatching to an engine.
///
/// Exists because sending "what's my quota" to Claude Code takes twenty seconds
/// and costs quota to answer a question the app already knows. Anything that
/// can be answered or done locally should be.
///
/// The three original local commands (undo, switch project, start over) were an
/// `if`-chain inside `VoicePipeline.handle`. That reads fine at three and badly
/// at fifteen, so matching lives here: one value per command, and adding one
/// doesn't touch the pipeline.
public struct LocalCommand: Sendable {
    /// What the utterance resolved to — the command, plus whatever came after
    /// the trigger words.
    public struct Invocation: Sendable, Equatable {
        public let argument: String

        public init(argument: String = "") {
            self.argument = argument
        }
    }

    public let id: String
    /// Shown by "what can you do" and in the docs.
    public let examples: [String]
    public let matches: @Sendable (String) -> Invocation?
    /// Returns what to say back, or nil to stay silent.
    public let perform: @Sendable (Invocation, LocalContext) async -> String?

    public init(
        id: String,
        examples: [String],
        matches: @escaping @Sendable (String) -> Invocation?,
        perform: @escaping @Sendable (Invocation, LocalContext) async -> String?
    ) {
        self.id = id
        self.examples = examples
        self.matches = matches
        self.perform = perform
    }
}

/// What local commands are allowed to reach.
///
/// Passed in rather than captured so commands stay testable — every one of them
/// can be driven with a stub context.
public struct LocalContext: Sendable {
    public var notesFile: URL
    public var quota: @Sendable () async -> [ProviderUsage]
    /// The last thing the assistant said, for "say that again".
    public var lastReply: @Sendable () async -> String?
    /// Speaks something later, unprompted — used by timers when they fire.
    public var notify: @Sendable (String) async -> Void
    /// Held by the caller, not made per-utterance: a timer set by one command
    /// has to still be there when the next one asks about it.
    public var timers: TimerStore

    public init(
        notesFile: URL,
        quota: @escaping @Sendable () async -> [ProviderUsage] = { [] },
        lastReply: @escaping @Sendable () async -> String? = { nil },
        notify: @escaping @Sendable (String) async -> Void = { _ in },
        timers: TimerStore = .default
    ) {
        self.notesFile = notesFile
        self.quota = quota
        self.lastReply = lastReply
        self.notify = notify
        self.timers = timers
    }

    public static var `default`: LocalContext {
        LocalContext(
            notesFile: Config.stateDirectory.appendingPathComponent("notes.md")
        )
    }
}

public enum LocalOutcome: Sendable, Equatable {
    /// Dealt with. `reply` is spoken if present.
    case handled(reply: String?)
    /// Not a local command — dispatch it to an engine.
    case notMine
}

/// Matches an utterance against the registered commands, first match wins.
public struct LocalCommandRouter: Sendable {
    public let commands: [LocalCommand]

    public init(commands: [LocalCommand] = LocalCommandRouter.standard) {
        self.commands = commands
    }

    public func handle(_ text: String, context: LocalContext) async -> LocalOutcome {
        for command in commands {
            guard let invocation = command.matches(text) else { continue }
            Log.dispatch.notice("local command: \(command.id, privacy: .public)")
            return .handled(reply: await command.perform(invocation, context))
        }
        return .notMine
    }

    /// Order matters: more specific patterns first, so "note down the volume"
    /// is captured as a note rather than a volume change.
    public static var standard: [LocalCommand] {
        [
            .note,
            .readNotes,
            .repeatLast,
            .quotaReport,
            .runShortcut,
            .listShortcuts,
            .cancelTimer,
            .listTimers,
            .setTimer,
            .volume,
            .openApp,
            .capabilities,
        ]
    }
}

// MARK: - Matching helpers

extension LocalCommand {
    /// Normalised for comparison: lowercase, no surrounding punctuation.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
    }

    /// Matches when the utterance is exactly one of `phrases`.
    ///
    /// Whole-utterance only, deliberately. "Undo that" is a command; "undo that
    /// change to the parser" is a task, and the same reasoning applies to every
    /// command here.
    static func exact(_ phrases: [String]) -> @Sendable (String) -> Invocation? {
        { text in
            phrases.contains(normalize(text)) ? Invocation() : nil
        }
    }

    /// Matches `<prefix> <argument>` and captures the argument.
    static func prefixed(_ prefixes: [String]) -> @Sendable (String) -> Invocation? {
        { text in
            let normalized = normalize(text)
            for prefix in prefixes where normalized.hasPrefix(prefix + " ") {
                let argument = String(normalized.dropFirst(prefix.count + 1))
                    .trimmingCharacters(in: .whitespaces)
                guard !argument.isEmpty else { continue }
                return Invocation(argument: argument)
            }
            return nil
        }
    }
}
