import CryptoKit
import Foundation

/// Remembers what was said before, so a follow-up command isn't heard in a
/// vacuum.
///
/// Without this, every command is a one-shot: "run the tests" then "fix those
/// failures" would start the second request completely blank. Talking to
/// something naturally implies continuity, so the assistant has to have some.
///
/// Continuity comes in two strengths, and the stronger one is preferred:
///
/// 1. **Engine session resume** — when the follow-up routes to the same engine
///    that handled the previous turn, its own session id is passed to
///    `--resume`. That's true continuity: the model still has its full context.
/// 2. **Context preamble** — when the engine has changed (or the session is
///    gone), a compact digest of recent turns is prepended instead. Weaker, but
///    it's the best available across an engine boundary.
///
/// Scoped per working directory: work in two projects is two conversations.
public actor ConversationStore {
    public struct Turn: Codable, Sendable {
        public let at: Date
        public let task: String
        public let engineId: String
        /// The engine's own session id, when it reported one.
        public let sessionId: String?
        public let runId: String
        public let summary: String?
        public let succeeded: Bool
        /// Where the repository was before this turn ran, so it can be undone.
        /// Nil when the directory isn't a git repository.
        public var recovery: RecoveryPoint?

        public init(
            at: Date,
            task: String,
            engineId: String,
            sessionId: String?,
            runId: String,
            summary: String?,
            succeeded: Bool,
            recovery: RecoveryPoint? = nil
        ) {
            self.at = at
            self.task = task
            self.engineId = engineId
            self.sessionId = sessionId
            self.runId = runId
            self.summary = summary
            self.succeeded = succeeded
            self.recovery = recovery
        }
    }

    public struct Conversation: Codable, Sendable, Identifiable {
        public var id: String
        public var turns: [Turn]
        public var startedAt: Date

        public init(id: String = UUID().uuidString, turns: [Turn] = [], startedAt: Date) {
            self.id = id
            self.turns = turns
            self.startedAt = startedAt
        }

        public var endedAt: Date? { turns.last?.at }
        public var title: String { turns.first?.task ?? "Empty conversation" }
    }

    /// On-disk shape: every conversation for this directory, oldest first.
    ///
    /// Past conversations used to be overwritten when a new one began, which
    /// made history impossible to show. They're archived now — the cost is a
    /// few KB per project.
    private struct Archive: Codable {
        var conversations: [Conversation]
        /// When the user last said "start over". Any conversation whose final
        /// turn precedes this is closed, regardless of the idle timeout.
        var closedAt: Date?
    }

    /// How the next task should be primed.
    public enum Continuity: Sendable, Equatable {
        /// Nothing to continue from.
        case fresh
        /// Resume this engine's own session — full fidelity.
        case resumeSession(engineId: String, sessionId: String)
        /// Different engine, or no session: prepend this digest to the prompt.
        case preamble(String)
    }

    private let directory: URL
    private let root: URL
    private let timeout: TimeInterval
    private let maxTurns: Int
    private var archive = Archive(conversations: [])
    private var loaded = false
    /// The maximum number of past conversations retained per directory.
    private let maxConversations: Int

    public init(
        workingDirectory: URL,
        root: URL = Config.stateDirectory.appendingPathComponent("conversations"),
        timeout: TimeInterval = 30 * 60,
        maxTurns: Int = 12,
        maxConversations: Int = 50
    ) {
        self.directory = workingDirectory
        self.root = root
        self.timeout = timeout
        self.maxTurns = maxTurns
        self.maxConversations = maxConversations
    }

    // MARK: - Reading

    /// Turns still inside the idle window. A long gap means the user has moved
    /// on, and dragging yesterday's task into today's request is worse than
    /// starting clean.
    public func activeTurns(now: Date = Date()) -> [Turn] {
        load()
        guard let current = archive.conversations.last, let last = current.turns.last else {
            return []
        }
        // Explicitly closed by the user.
        if let closedAt = archive.closedAt, closedAt >= last.at { return [] }
        // Or gone idle.
        guard now.timeIntervalSince(last.at) <= timeout else { return [] }
        return current.turns
    }

    /// Every conversation for this directory, newest first. Powers the history
    /// view in the app.
    public func history() -> [Conversation] {
        load()
        return archive.conversations.reversed().filter { !$0.turns.isEmpty }
    }

    /// Whether the most recent conversation is still live.
    public func hasActiveConversation(now: Date = Date()) -> Bool {
        !activeTurns(now: now).isEmpty
    }

    /// How to prime a new task, given which engine it will run on.
    public func continuity(for engineId: String, now: Date = Date()) -> Continuity {
        let turns = activeTurns(now: now)
        guard let last = turns.last else { return .fresh }

        if last.engineId == engineId, let sessionId = last.sessionId {
            return .resumeSession(engineId: engineId, sessionId: sessionId)
        }
        return .preamble(Self.digest(of: turns))
    }

    /// Compact history for an engine that can't resume a session.
    ///
    /// Only tasks and outcomes — not full transcripts. The point is to explain
    /// what "those failures" refers to, not to replay the work.
    static func digest(of turns: [Turn]) -> String {
        let lines = turns.suffix(6).map { turn -> String in
            var line = "- I asked: \"\(turn.task)\""
            if let summary = turn.summary, !summary.isEmpty {
                line += "\n  Result: \(summary.prefix(300))"
            } else if !turn.succeeded {
                line += "\n  Result: did not complete."
            }
            return line
        }
        return """
        ## Earlier in this session
        These are the immediately preceding requests in this same directory. \
        The new request may refer back to them.

        \(lines.joined(separator: "\n"))
        """
    }

    // MARK: - Writing

    /// The most recent turn that can be undone, newest first.
    public func mostRecentRecoverable(now: Date = Date()) -> Turn? {
        load()
        return archive.conversations.last?.turns.last { $0.recovery != nil }
    }

    public func record(
        task: String,
        engineId: String,
        sessionId: String?,
        runId: String,
        summary: String?,
        succeeded: Bool,
        recovery: RecoveryPoint? = nil,
        now: Date = Date()
    ) {
        load()

        // A gap longer than the timeout starts a new conversation. The previous
        // one stays in the archive rather than being replaced.
        var isContinuation = false
        if let last = archive.conversations.last?.turns.last,
           now.timeIntervalSince(last.at) <= timeout,
           !(archive.closedAt.map { $0 >= last.at } ?? false) {
            isContinuation = true
        }
        if !isContinuation {
            archive.conversations.append(Conversation(startedAt: now))
        }

        var current = archive.conversations[archive.conversations.count - 1]
        current.turns.append(Turn(
            at: now,
            task: task,
            engineId: engineId,
            sessionId: sessionId,
            runId: runId,
            summary: summary,
            succeeded: succeeded,
            recovery: recovery
        ))
        if current.turns.count > maxTurns {
            current.turns.removeFirst(current.turns.count - maxTurns)
        }
        archive.conversations[archive.conversations.count - 1] = current

        if archive.conversations.count > maxConversations {
            archive.conversations.removeFirst(archive.conversations.count - maxConversations)
        }
        persist()
    }

    /// Ends the current conversation — "start over", or an explicit `--new`.
    ///
    /// Closes it rather than deleting it: the user asked to stop *continuing*,
    /// not to erase what happened. History keeps it.
    public func reset(now: Date = Date()) {
        load()
        archive.closedAt = now
        persist()
    }

    // MARK: - Persistence

    /// Keyed by a hash of the directory: paths contain characters that are
    /// awkward in filenames, and the hash keeps them flat and collision-free.
    private var fileURL: URL {
        let path = directory.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let name = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16)
        return root.appendingPathComponent("\(name).json")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let stored = try? decoder.decode(Archive.self, from: data) {
            archive = stored
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(archive).write(to: fileURL, options: .atomic)
        } catch {
            // A conversation that can't be saved must not fail the task.
            Log.dispatch.error(
                "could not persist conversation: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
