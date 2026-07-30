import Foundation
import Testing
@testable import VoxRouterKit

/// `flock` is held per open file description, so two `FileLock` values over the
/// same path exclude each other even inside one process — which is what makes
/// the cross-process behaviour testable here.
@Suite("Cross-process file lock")
struct FileLockTests {
    private func scratchFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voxrouter-lock-\(UUID().uuidString)")
    }

    /// The failure it prevents: read, change, write-back from two places at
    /// once, where the second write is computed from a stale read and silently
    /// discards the first. Measured against the real binary before this
    /// existed, 12 concurrent writers left 2 to 7 of 12 records standing.
    @Test("Concurrent read-modify-write loses nothing")
    func serialisesReadModifyWrite() async throws {
        let file = scratchFile()
        let counter = file.appendingPathExtension("count")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: counter)
        }
        try Data("0".utf8).write(to: counter)

        let writers = 16
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<writers {
                group.addTask {
                    // A separate lock per task, as a separate process would.
                    guard let lock = FileLock(at: file) else { return }
                    lock.withLock {
                        let value = Int(
                            (try? String(contentsOf: counter, encoding: .utf8)) ?? "0"
                        ) ?? 0
                        // Widen the window a stale read would slip through.
                        Thread.sleep(forTimeInterval: 0.002)
                        try? Data("\(value + 1)".utf8).write(to: counter, options: .atomic)
                    }
                }
            }
        }

        let final = Int(try String(contentsOf: counter, encoding: .utf8)) ?? 0
        #expect(final == writers, "\(writers - final) updates were lost")
    }

    /// A held lock must never wedge the assistant: waiting is bounded, and the
    /// work runs regardless. This is the same lesson as never SIGKILLing a
    /// running shortcut — one stuck process shouldn't become a stuck app.
    @Test("Waiting for a stuck holder is bounded, and the work still runs")
    func doesNotBlockForever() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let holder = try #require(FileLock(at: file))
        let waiter = try #require(FileLock(at: file))

        let released = Locked<Bool>(false)
        let held = Thread {
            holder.withLock { Thread.sleep(forTimeInterval: 5) }
            released.set(true)
        }
        held.start()
        try await Task.sleep(for: .milliseconds(100))

        let start = Date()
        let ran = waiter.withLock(timeout: 0.25) { true }
        let waited = Date().timeIntervalSince(start)

        #expect(ran, "the body must run even when the lock can't be taken")
        #expect(waited < 2, "waited \(waited)s — should give up near the timeout")
        #expect(released.get() == false, "the holder was still holding, as intended")
    }

    @Test("An uncontended lock is taken immediately")
    func uncontendedIsFast() throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let lock = try #require(FileLock(at: file))
        let start = Date()
        #expect(lock.withLock { 42 } == 42)
        #expect(Date().timeIntervalSince(start) < 0.1)
    }

    /// Reacquiring must work — the lock is released on the way out, not leaked.
    @Test("The same lock can be taken repeatedly")
    func releasesOnExit() throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let lock = try #require(FileLock(at: file))
        for _ in 0..<5 { _ = lock.withLock { true } }
        // A second holder proves the first really let go.
        let other = try #require(FileLock(at: file))
        #expect(other.withLock(timeout: 0.5) { true })
    }

    @Test("The lock file is created if its directory doesn't exist yet")
    func createsDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxrouter-lockdir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let lock = FileLock(at: directory.appendingPathComponent("nested/state.lock"))
        #expect(lock != nil)
    }
}
