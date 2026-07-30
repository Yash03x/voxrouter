import Foundation
import Testing
@testable import VoxRouterKit

/// Exercises real repositories rather than mocks: the whole point is that the
/// git commands behave as expected, which a fake would assume rather than prove.
private struct TempRepo {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxrouter-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        run(["init", "-q", "-b", "main"])
        run(["config", "user.email", "test@example.com"])
        run(["config", "user.name", "Test"])
    }

    @discardableResult
    func run(_ arguments: [String]) -> String? {
        GitRecovery.git(arguments, in: url)
    }

    func write(_ name: String, _ contents: String) {
        try? contents.write(
            to: url.appendingPathComponent(name), atomically: true, encoding: .utf8
        )
    }

    func read(_ name: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path)
    }

    func commit(_ message: String) {
        run(["add", "-A"])
        run(["commit", "-q", "-m", message])
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("Git recovery")
struct GitRecoveryTests {
    @Test("A non-repository yields no recovery point rather than failing")
    func nonRepositoryIsNil() throws {
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxrouter-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }

        #expect(!GitRecovery.isRepository(plain))
        #expect(GitRecovery.capture(in: plain, runId: "r1") == nil)
    }

    @Test("A repository with no commits has nothing to return to")
    func emptyRepositoryIsNil() throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        #expect(GitRecovery.capture(in: repo.url, runId: "r1") == nil)
    }

    @Test("Capture records the current commit and branch")
    func capturesHead() throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        repo.write("a.txt", "one")
        repo.commit("first")

        let point = try #require(GitRecovery.capture(in: repo.url, runId: "r1"))
        #expect(point.branch == "main")
        #expect(!point.hadUncommittedChanges)
        #expect(point.head.count == 40)
    }

    /// The core promise: a task that rewrites files can be put back.
    @Test("Undoing restores files the agent changed")
    func undoRestoresChangedFiles() throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        repo.write("a.txt", "original")
        repo.commit("first")

        let point = try #require(GitRecovery.capture(in: repo.url, runId: "r1"))

        // Simulate the agent working: edit, add a file, commit.
        repo.write("a.txt", "mangled by the agent")
        repo.write("b.txt", "agent's new file")
        repo.commit("agent's work")

        _ = try GitRecovery.restore(point)

        #expect(repo.read("a.txt") == "original")
        #expect(!repo.exists("b.txt"), "files the agent added should be gone")
    }

    /// Capturing must not disturb work in progress — the agent is about to run
    /// against exactly this tree.
    @Test("Capture leaves uncommitted work untouched")
    func captureDoesNotDisturbWorkingTree() throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        repo.write("a.txt", "committed")
        repo.commit("first")
        repo.write("a.txt", "my work in progress")

        let point = try #require(GitRecovery.capture(in: repo.url, runId: "r1"))

        #expect(point.hadUncommittedChanges)
        #expect(repo.read("a.txt") == "my work in progress", "capture must not stash or revert")
    }

    /// Losing the user's own uncommitted work while undoing the agent's would
    /// be a worse outcome than not undoing at all.
    @Test("Undo restores uncommitted work that existed beforehand")
    func undoRestoresPreexistingUncommittedWork() throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        repo.write("a.txt", "committed")
        repo.commit("first")
        repo.write("a.txt", "my uncommitted edit")

        let point = try #require(GitRecovery.capture(in: repo.url, runId: "r1"))

        repo.write("a.txt", "agent overwrote it")
        repo.commit("agent's work")

        let result = try GitRecovery.restore(point)

        #expect(result.restoredUncommitted)
        #expect(repo.read("a.txt") == "my uncommitted edit")
    }

    /// An undo you can't reverse is just a different way to lose work.
    @Test("Undo keeps what it discarded, so it can be reversed")
    func undoIsItselfRecoverable() throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        repo.write("a.txt", "original")
        repo.commit("first")

        let point = try #require(GitRecovery.capture(in: repo.url, runId: "r1"))
        repo.write("a.txt", "valuable agent work")
        repo.commit("agent")

        let result = try GitRecovery.restore(point)
        let undoneRef = try #require(result.undoneRef)

        // The discarded state is still reachable.
        #expect(repo.run(["rev-parse", "--verify", undoneRef]) != nil)
    }

    /// Using `git stash` proper would move the user's changes out from under
    /// them and clutter a list they didn't ask us to touch.
    @Test("Snapshots stay out of git stash list")
    func doesNotPolluteStashList() throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        repo.write("a.txt", "committed")
        repo.commit("first")
        repo.write("a.txt", "dirty")

        _ = GitRecovery.capture(in: repo.url, runId: "r1")

        let stashList = repo.run(["stash", "list"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(stashList.isEmpty, "the user's stash list is not ours to write to")
    }

    @Test("The snapshot is anchored to a ref so gc can't drop it")
    func snapshotSurvivesGarbageCollection() throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        repo.write("a.txt", "committed")
        repo.commit("first")
        repo.write("a.txt", "dirty")

        let point = try #require(GitRecovery.capture(in: repo.url, runId: "r1"))
        let ref = try #require(point.dirtyRef)
        #expect(ref.hasPrefix(GitRecovery.refNamespace))

        repo.run(["gc", "--prune=now", "--quiet"])
        #expect(repo.run(["rev-parse", "--verify", ref]) != nil, "gc collected the snapshot")
    }

    @Test("A recovery point survives a JSON round trip")
    func codableRoundTrip() throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        repo.write("a.txt", "x")
        repo.commit("first")

        let point = try #require(GitRecovery.capture(in: repo.url, runId: "r1"))
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(RecoveryPoint.self, from: data)
        #expect(decoded == point)
    }
}

@Suite("Spoken undo")
struct UndoCommandTests {
    @Test("Undo phrases are recognised as a whole utterance")
    func recognisesUndo() {
        for phrase in ["undo that", "Undo it.", "revert that", "roll it back", "put it back"] {
            #expect(VoicePipeline.isUndoCommand(phrase), "should undo on: \(phrase)")
        }
    }

    /// "undo that change to the parser" is work for the engine, not a request
    /// to reset the repository.
    @Test("Undo inside a longer request is a task, not a reset")
    func doesNotUndoOnTasks() {
        for phrase in [
            "undo that change to the parser",
            "revert the last commit in the readme",
            "put it back the way the tests expect",
        ] {
            #expect(!VoicePipeline.isUndoCommand(phrase), "should NOT undo on: \(phrase)")
        }
    }
}
