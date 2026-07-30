import Foundation

/// The handoff mechanism.
///
/// Neither engine's native session resume crosses the boundary to the other:
/// if Claude dies at 80% of a task, `codex exec resume` knows nothing about it.
/// So the authoritative record of a run lives *outside* both engines, in a file
/// both can read. A failover is then just "here is the task, here is what has
/// already happened, continue" — which is the only way engine switching is
/// survivable rather than a restart.
public actor RunJournal {
    public struct Entry: Codable, Sendable {
        public let at: Date
        public let engine: String
        public let kind: String
        public let detail: String
    }

    public struct Manifest: Codable, Sendable {
        public var runId: String
        public var task: String
        public var startedAt: Date
        public var workingDirectory: String
        /// Every engine that has worked on this run, in order. More than one
        /// entry means a failover happened.
        public var engineHistory: [String]
        public var finishedAt: Date?
        public var outcome: String?
    }

    // `nonisolated` so callers outside this module can read them synchronously;
    // they're immutable and Sendable, so there's nothing to protect.
    public nonisolated let runId: String
    public nonisolated let directory: URL
    private var manifest: Manifest
    private var entries: [Entry] = []
    /// engineId -> that engine's own session id, for same-engine resume.
    private var sessionIds: [String: String] = [:]

    public func sessionId(for engineId: String) -> String? { sessionIds[engineId] }

    public init(task: String, workingDirectory: URL, root: URL = Config.stateDirectory) throws {
        // Sortable, collision-resistant, and readable in a directory listing.
        let stamp = Self.stampFormatter.string(from: Date())
        let suffix = String(UInt32.random(in: 0..<0xFFFF), radix: 16)
        self.runId = "\(stamp)-\(suffix)"
        self.directory = root.appendingPathComponent("runs/\(runId)")
        self.manifest = Manifest(
            runId: runId,
            task: task,
            startedAt: Date(),
            workingDirectory: workingDirectory.path,
            engineHistory: [],
            finishedAt: nil,
            outcome: nil
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.write(manifest: manifest, entries: [], to: directory)
    }

    public func beginEngine(_ engineId: String, reason: String) throws {
        manifest.engineHistory.append(engineId)
        entries.append(Entry(at: Date(), engine: engineId, kind: "engine-start", detail: reason))
        try persist()
    }

    public func record(engine: String, event: EngineEvent) throws {
        let entry: Entry?
        switch event {
        case .status(let detail):
            entry = Entry(at: Date(), engine: engine, kind: "status", detail: detail)
        case .text(let detail):
            entry = Entry(at: Date(), engine: engine, kind: "text", detail: detail)
        case .action(let detail):
            entry = Entry(at: Date(), engine: engine, kind: "action", detail: detail)
        case .session(let sessionId):
            sessionIds[engine] = sessionId
            entry = nil
        case .rateLimited(let detail, _):
            entry = Entry(at: Date(), engine: engine, kind: "rate-limited", detail: detail)
        case .unavailable(let detail):
            entry = Entry(at: Date(), engine: engine, kind: "unavailable", detail: detail)
        case .failed(let detail):
            entry = Entry(at: Date(), engine: engine, kind: "failed", detail: detail)
        case .finished(let code):
            entry = Entry(at: Date(), engine: engine, kind: "finished", detail: "exit \(code)")
        case .raw:
            // Deliberately not journalled: raw protocol chatter would bury the
            // signal a resuming engine needs to read.
            entry = nil
        }
        guard let entry else { return }
        entries.append(entry)
        try persist()
    }

    public func finish(outcome: String) throws {
        manifest.finishedAt = Date()
        manifest.outcome = outcome
        try persist()
    }

    public func currentManifest() -> Manifest { manifest }

    /// The prompt handed to a replacement engine after a failover.
    ///
    /// The instruction to re-check state before editing matters: the previous
    /// engine may have half-applied a change, and the replacement has no way to
    /// know that except by looking.
    public func continuationPrompt() -> String {
        let transcript = entries
            .filter { $0.kind != "engine-start" }
            .map { "- [\($0.engine)] \($0.kind): \($0.detail)" }
            .joined(separator: "\n")

        let priorEngines = manifest.engineHistory.dropLast().joined(separator: ", ")

        return """
        You are resuming a task that another coding agent started and could not \
        finish, because it ran out of usage quota partway through.

        ## Original task
        \(manifest.task)

        ## What the previous agent (\(priorEngines.isEmpty ? "unknown" : priorEngines)) did
        \(transcript.isEmpty ? "(no recorded progress — treat this as a fresh start)" : transcript)

        ## How to proceed
        Continue from where it stopped. Do not redo work already completed. The \
        previous agent may have left a change half-applied, so inspect the \
        current state of any file before editing it — trust what is on disk over \
        what the log above claims. If the log is unclear about whether a step \
        finished, verify it directly.
        """
    }

    // MARK: - Persistence

    private func persist() throws {
        try Self.write(manifest: manifest, entries: entries, to: directory)
    }

    /// Rewritten in full on each event. Runs produce tens of entries, not
    /// thousands, so an atomic rewrite is cheaper than managing append offsets
    /// and can't leave a torn file if we're killed mid-write.
    ///
    /// `nonisolated static` so `init` can lay down the initial files before the
    /// actor is fully formed.
    private nonisolated static func write(
        manifest: Manifest,
        entries: [Entry],
        to directory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        try encoder.encode(manifest)
            .write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        try encoder.encode(entries)
            .write(to: directory.appendingPathComponent("entries.json"), options: .atomic)

        // Human-readable mirror, so `cat` is enough to see what happened.
        var markdown = """
        # \(manifest.task)

        - run: `\(manifest.runId)`
        - started: \(manifest.startedAt.formatted(.iso8601))
        - cwd: `\(manifest.workingDirectory)`
        - engines: \(manifest.engineHistory.joined(separator: " → "))

        """
        if let outcome = manifest.outcome {
            markdown += "- outcome: **\(outcome)**\n"
        }
        markdown += "\n## Log\n\n"
        for entry in entries {
            markdown += "- `\(entry.at.formatted(.iso8601))` **\(entry.engine)** "
                + "*\(entry.kind)* — \(entry.detail)\n"
        }
        try Data(markdown.utf8)
            .write(to: directory.appendingPathComponent("journal.md"), options: .atomic)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        // POSIX locale, or "HH" renders as 12-hour with an AM/PM suffix under
        // locales that prefer it — which puts a space in the directory name.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = .current
        return f
    }()
}
