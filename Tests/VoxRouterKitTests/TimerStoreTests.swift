import Foundation
import Testing
@testable import VoxRouterKit

/// A store is "restarted" here by building a second one over the same file —
/// which is exactly what a relaunch does.
@Suite("Timers that outlive the app")
struct TimerStoreTests {
    private func scratchFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voxrouter-timers-\(UUID().uuidString).json")
    }

    /// The bug this exists for: a timer you were told was set, silently gone
    /// after a relaunch.
    @Test("A pending timer survives a restart")
    func survivesRestart() async {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = TimerStore(file: file)
        _ = await first.schedule(seconds: 600, now: now)

        let afterRestart = TimerStore(file: file)
        await afterRestart.restore(now: now.addingTimeInterval(60))

        let pending = await afterRestart.timers(now: now.addingTimeInterval(60))
        #expect(pending.count == 1)
        #expect(pending.first?.duration == 600)
    }

    /// It has to re-arm on the *remaining* time, not the original duration —
    /// otherwise every restart quietly extends the timer.
    @Test("Restoring keeps the original due time")
    func keepsDueTime() async {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = TimerStore(file: file)
        let scheduled = await store.schedule(seconds: 600, now: now)

        let afterRestart = TimerStore(file: file)
        await afterRestart.restore(now: now.addingTimeInterval(300))
        let restored = await afterRestart.timers(now: now.addingTimeInterval(300))

        #expect(restored.first?.dueAt == scheduled.dueAt)
    }

    @Test("A timer that came due while the app was closed is announced, not dropped")
    func announcesMissed() async {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = TimerStore(file: file)
        _ = await store.schedule(seconds: 60, now: now)

        let spoken = Spy()
        let afterRestart = TimerStore(file: file)
        await afterRestart.setNotifier { await spoken.record($0) }
        await afterRestart.restore(now: now.addingTimeInterval(300))

        let said = await spoken.waitForFirst()
        #expect(said?.contains("while I was closed") == true)
        #expect(await afterRestart.timers(now: now.addingTimeInterval(300)).isEmpty)
    }

    /// Announcing a timer from last week at login would teach you to ignore
    /// the feature entirely.
    @Test("A long-stale timer is dropped silently")
    func dropsStale() async {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = TimerStore(file: file)
        _ = await store.schedule(seconds: 60, now: now)

        let spoken = Spy()
        let afterRestart = TimerStore(file: file)
        await afterRestart.setNotifier { await spoken.record($0) }
        // A week later, well past the grace window.
        await afterRestart.restore(now: now.addingTimeInterval(86_400 * 7))

        #expect(await afterRestart.timers(now: now.addingTimeInterval(86_400 * 7)).isEmpty)
        #expect(await spoken.count() == 0)
    }

    /// Persistence is what makes this necessary: a mistranscribed "eight hours"
    /// used to die with the app.
    @Test("Cancelling clears the file too, so nothing comes back")
    func cancelIsPermanent() async {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = TimerStore(file: file)
        _ = await store.schedule(seconds: 600, now: now)
        _ = await store.schedule(seconds: 900, now: now)

        let cancelled = await store.cancelAll()
        #expect(cancelled.count == 2)

        let afterRestart = TimerStore(file: file)
        await afterRestart.restore(now: now)
        #expect(await afterRestart.timers(now: now).isEmpty)
    }

    @Test("Cancelling with nothing pending reports nothing pending")
    func cancelWhenEmpty() async {
        let store = TimerStore(file: scratchFile())
        #expect(await store.cancelAll().isEmpty)
    }

    /// The app and the CLI both write this file. `persist()` writes the
    /// in-memory list wholesale, so a process that hadn't read the file first
    /// replaced everything in it with the single timer it had just made.
    @Test("A second process adds to the file instead of replacing it")
    func doesNotClobberAnotherProcess() async {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = await TimerStore(file: file).schedule(seconds: 600, now: now)
        // A fresh store, as a separate process would have.
        _ = await TimerStore(file: file).schedule(seconds: 900, now: now)

        let reader = TimerStore(file: file)
        #expect(await reader.timers(now: now).map(\.duration) == [600, 900])
    }

    @Test("Reading sees timers written by another process")
    func readsWithoutRestoring() async {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = await TimerStore(file: file).schedule(seconds: 600, now: now)
        #expect(await TimerStore(file: file).timers(now: now).count == 1)
    }

    @Test("Cancelling reaches timers this process never scheduled")
    func cancelsAnotherProcessesTimers() async {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = await TimerStore(file: file).schedule(seconds: 600, now: now)
        #expect(await TimerStore(file: file).cancelAll().count == 1)
        #expect(await TimerStore(file: file).timers(now: now).isEmpty)
    }

    @Test("A timer actually fires")
    func fires() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let spoken = Spy()
        let store = TimerStore(file: file)
        await store.setNotifier { await spoken.record($0) }
        _ = await store.schedule(seconds: 0)

        let said = try #require(await spoken.waitForFirst())
        #expect(said.contains("timer is up"))
        // Firing has to clear it, or a restart would announce it again.
        #expect(await store.timers().isEmpty)
    }

    @Test("A cancelled timer does not fire")
    func cancelledDoesNotFire() async {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let spoken = Spy()
        let store = TimerStore(file: file)
        await store.setNotifier { await spoken.record($0) }
        _ = await store.schedule(seconds: 0)
        await store.cancelAll()

        try? await Task.sleep(for: .milliseconds(200))
        #expect(await spoken.count() == 0)
    }

    @Test("Timers are listed soonest first")
    func ordersByDueTime() async {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = TimerStore(file: file)
        _ = await store.schedule(seconds: 900, now: now)
        _ = await store.schedule(seconds: 300, now: now)

        let pending = await store.timers(now: now)
        #expect(pending.map(\.duration) == [300, 900])
    }

    @Test("A missing or corrupt file reads as no timers, not a crash")
    func toleratesBadFile() async {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let store = TimerStore(file: file)
        await store.restore()
        #expect(await store.timers().isEmpty)

        try? Data("not json".utf8).write(to: file)
        let second = TimerStore(file: file)
        await second.restore()
        #expect(await second.timers().isEmpty)
    }
}

/// Collects what the store said.
private actor Spy {
    private var lines: [String] = []

    func record(_ line: String) { lines.append(line) }
    func count() -> Int { lines.count }

    /// Firing goes through a detached task, so give it a moment to arrive.
    func waitForFirst() async -> String? {
        for _ in 0..<100 {
            if let first = lines.first { return first }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}
