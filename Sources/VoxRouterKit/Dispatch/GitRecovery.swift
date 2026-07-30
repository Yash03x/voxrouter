import Foundation

/// A snapshot of a repository taken immediately before a task ran.
public struct RecoveryPoint: Codable, Sendable, Equatable {
    public let runId: String
    public let directory: String
    /// Commit the branch was on before the task.
    public let head: String
    public let branch: String?
    /// Ref holding the uncommitted changes that existed beforehand, or nil if
    /// the tree was clean.
    public let dirtyRef: String?
    public let capturedAt: Date

    public var hadUncommittedChanges: Bool { dirtyRef != nil }
    public var shortHead: String { String(head.prefix(8)) }
}

public enum RecoveryError: Error, LocalizedError {
    case notARepository(String)
    case gitFailed(String)
    case nothingToUndo

    public var errorDescription: String? {
        switch self {
        case .notARepository(let path): return "\(path) isn't a git repository."
        case .gitFailed(let detail): return "git: \(detail)"
        case .nothingToUndo: return "There's no recovery point for that."
        }
    }
}

/// Records where a repository was before a task, so the work can be undone.
///
/// With approval prompts disabled, an agent acting on a misheard instruction
/// changes files immediately and with no confirmation. Git is already the
/// safety net for most of what this does — this just makes sure a usable point
/// exists *before* the agent starts, rather than hoping one does.
///
/// Deliberately non-invasive: it never modifies the working tree, never runs
/// `git stash` (which would move the user's changes out from under them or the
/// agent), and never adds to `git stash list`. Uncommitted work is captured with
/// `git stash create`, which writes a commit object and changes nothing else,
/// and kept alive under `refs/voxrouter/` so garbage collection can't drop it
/// and `git stash list` stays clean.
public enum GitRecovery {
    static let refNamespace = "refs/voxrouter/snapshots"

    // MARK: - Capture

    public static func capture(in directory: URL, runId: String) -> RecoveryPoint? {
        guard isRepository(directory) else { return nil }
        guard let head = git(["rev-parse", "HEAD"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else {
            // A repo with no commits yet has no HEAD to return to.
            return nil
        }

        let branch = git(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var dirtyRef: String?
        if hasUncommittedChanges(directory) {
            // `stash create` builds the commit object without touching the
            // working tree or the stash list.
            if let stash = git(["stash", "create"], in: directory)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !stash.isEmpty {
                let ref = "\(refNamespace)/\(runId)"
                // Anchor it to a ref, or gc is free to collect it.
                if git(["update-ref", ref, stash], in: directory) != nil {
                    dirtyRef = ref
                }
            }
        }

        return RecoveryPoint(
            runId: runId,
            directory: directory.path,
            head: head,
            branch: branch == "HEAD" ? nil : branch,
            dirtyRef: dirtyRef,
            capturedAt: Date()
        )
    }

    // MARK: - Restore

    public struct RestoreResult: Sendable {
        public let head: String
        public let restoredUncommitted: Bool
        /// Ref holding what was discarded, so undoing the undo is possible.
        public let undoneRef: String?
    }

    /// Returns the repository to the recorded point.
    ///
    /// Takes a snapshot of the *current* state first. Undo is itself
    /// destructive — it throws away whatever the agent did — and an undo you
    /// can't reverse is just a different way to lose work.
    public static func restore(_ point: RecoveryPoint) throws -> RestoreResult {
        let directory = URL(fileURLWithPath: point.directory)
        guard isRepository(directory) else {
            throw RecoveryError.notARepository(point.directory)
        }

        // Anchor whatever is about to be thrown away.
        //
        // A stash object covers uncommitted changes *and* carries the current
        // HEAD as its parent, so it preserves both. But an agent that committed
        // its work leaves a clean tree, and `stash create` then returns nothing
        // — in that case the commits themselves are what's being discarded, so
        // anchor HEAD directly. Relying on the reflog instead would work until
        // it expires.
        var undoneRef: String?
        let candidate = git(["stash", "create"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let toAnchor: String?
        if let candidate, !candidate.isEmpty {
            toAnchor = candidate
        } else {
            toAnchor = git(["rev-parse", "HEAD"], in: directory)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let toAnchor, !toAnchor.isEmpty, toAnchor != point.head {
            let ref = "\(refNamespace)/undone-\(point.runId)"
            if git(["update-ref", ref, toAnchor], in: directory) != nil {
                undoneRef = ref
            }
        }

        guard git(["reset", "--hard", point.head], in: directory) != nil else {
            throw RecoveryError.gitFailed("could not reset to \(point.shortHead)")
        }

        var restoredUncommitted = false
        if let dirtyRef = point.dirtyRef {
            // Restores the pre-task uncommitted changes on top of the reset.
            if git(["stash", "apply", dirtyRef], in: directory) != nil {
                restoredUncommitted = true
            }
        }

        return RestoreResult(
            head: point.head,
            restoredUncommitted: restoredUncommitted,
            undoneRef: undoneRef
        )
    }

    // MARK: - Git plumbing

    public static func isRepository(_ directory: URL) -> Bool {
        git(["rev-parse", "--is-inside-work-tree"], in: directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    static func hasUncommittedChanges(_ directory: URL) -> Bool {
        guard let status = git(["status", "--porcelain"], in: directory) else { return false }
        return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Runs git, returning stdout, or nil when it fails.
    @discardableResult
    static func git(_ arguments: [String], in directory: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // Never let git open an editor, a pager, or a credential prompt: this
        // runs unattended and any of those would hang it forever.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["GIT_EDITOR"] = "true"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
