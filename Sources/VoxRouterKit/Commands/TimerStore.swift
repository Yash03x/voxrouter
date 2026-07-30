import Foundation

/// A timer that hasn't gone off yet.
public struct PendingTimer: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let dueAt: Date
    /// The duration as it was asked for, so it can be read back the same way.
    public let duration: Int

    public init(id: UUID = UUID(), dueAt: Date, duration: Int) {
        self.id = id
        self.dueAt = dueAt
        self.duration = duration
    }
}

/// Timers that outlive the app.
///
/// They used to be a bare `Task` sleeping in memory: quitting the app, or
/// letting it be relaunched at login, dropped every pending timer without
/// saying so. A timer you were told was set and that then silently never fires
/// is worse than one that was refused — you stop checking, because you were
/// told it was handled.
public actor TimerStore {
    /// How late a timer can be before firing it is noise rather than news.
    ///
    /// A timer that came due while the Mac was asleep is worth hearing about
    /// minutes later. One from last week is not, and announcing it at login
    /// would teach you to ignore the thing entirely.
    public static let missedGrace: TimeInterval = 3600

    private let file: URL
    private let lock: FileLock?
    /// Timers this process is counting down. The *file* is the record of what
    /// exists; this is only what we're waiting on.
    private var scheduled: [UUID: Task<Void, Never>] = [:]
    private var notify: @Sendable (String) async -> Void = { _ in }

    public init(file: URL) {
        self.file = file
        self.lock = FileLock(at: file.appendingPathExtension("lock"))
    }

    public static var `default`: TimerStore {
        TimerStore(file: Config.stateDirectory.appendingPathComponent("timers.json"))
    }

    /// Where firing timers speak. Set before ``restore(now:)``.
    public func setNotifier(_ notify: @escaping @Sendable (String) async -> Void) {
        self.notify = notify
    }

    public func schedule(seconds: Int, now: Date = Date()) -> PendingTimer {
        let timer = PendingTimer(dueAt: now.addingTimeInterval(TimeInterval(seconds)), duration: seconds)
        mutate { $0.append(timer) }
        arm(timer, after: TimeInterval(seconds))
        return timer
    }

    /// Reloads timers written before the app last stopped.
    ///
    /// Anything already due is announced as missed rather than silently
    /// dropped — the whole point is that you find out.
    public func restore(now: Date = Date()) {
        var missed: [PendingTimer] = []
        // Claiming the overdue ones and writing back happens under one lock, so
        // two processes starting together can't both announce the same timer.
        let live = mutate { stored -> [PendingTimer] in
            var live: [PendingTimer] = []
            for timer in stored {
                let remaining = timer.dueAt.timeIntervalSince(now)
                if remaining > 0 {
                    live.append(timer)
                } else if -remaining <= Self.missedGrace {
                    missed.append(timer)
                }
                // Anything staler than the grace window is dropped in silence.
            }
            stored = live
            return live
        }

        for timer in live where scheduled[timer.id] == nil {
            arm(timer, after: timer.dueAt.timeIntervalSince(now))
        }

        guard !missed.isEmpty else { return }
        let notify = notify
        Task {
            for timer in missed {
                await notify(
                    "Your \(DurationParser.spoken(timer.duration)) timer went off while I was closed."
                )
            }
        }
    }

    /// Cancels everything pending, returning how many there were.
    ///
    /// Necessary *because* timers now persist: a mistranscribed "eight hours"
    /// used to die with the app, and would otherwise follow you across every
    /// restart with no way to be rid of it.
    @discardableResult
    public func cancelAll() -> [PendingTimer] {
        for task in scheduled.values { task.cancel() }
        scheduled.removeAll()
        // Clears timers set by other processes too — "cancel the timer" means
        // all of them, not just the ones this process happens to be counting.
        return mutate { stored in
            let cancelled = stored
            stored = []
            return cancelled
        }
    }

    public func timers(now: Date = Date()) -> [PendingTimer] {
        read().filter { $0.dueAt > now }.sorted { $0.dueAt < $1.dueAt }
    }

    // MARK: - Plumbing

    /// Reads, changes and writes the file without another process interleaving.
    ///
    /// The whole cycle is inside the lock, not just the write. Keeping an
    /// in-memory copy and writing it back was the original bug: a process that
    /// hadn't read the file replaced a file full of timers with the one it had
    /// just made, so setting a timer from the CLI while the app held two others
    /// destroyed both. Locking only the write wouldn't have helped — the stale
    /// copy is the problem, so the read has to be inside the lock too.
    @discardableResult
    private func mutate<T>(_ body: (inout [PendingTimer]) -> T) -> T {
        withFileLock {
            var stored = readUnlocked()
            let result = body(&stored)
            write(stored)
            return result
        }
    }

    private func read() -> [PendingTimer] {
        withFileLock { readUnlocked() }
    }

    /// Falls back to running unlocked if the lock file couldn't be opened —
    /// a read-only home directory shouldn't stop timers working in-process.
    private func withFileLock<T>(_ body: () -> T) -> T {
        guard let lock else { return body() }
        return lock.withLock(body)
    }

    private func readUnlocked() -> [PendingTimer] {
        (try? Data(contentsOf: file))
            .flatMap { try? JSONDecoder().decode([PendingTimer].self, from: $0) } ?? []
    }

    private func arm(_ timer: PendingTimer, after seconds: TimeInterval) {
        scheduled[timer.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, seconds)))
            guard !Task.isCancelled else { return }
            await self?.fire(timer)
        }
    }

    private func fire(_ timer: PendingTimer) async {
        scheduled[timer.id] = nil
        // Claiming it and removing it happen under one lock. Cancellation races
        // firing, and two processes can be counting the same restored timer —
        // whoever removes it speaks, and only once.
        let claimed = mutate { stored -> Bool in
            guard stored.contains(where: { $0.id == timer.id }) else { return false }
            stored.removeAll { $0.id == timer.id }
            return true
        }
        guard claimed else { return }
        await notify("Your \(DurationParser.spoken(timer.duration)) timer is up.")
    }

    private func write(_ timers: [PendingTimer]) {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            guard !timers.isEmpty else {
                try? FileManager.default.removeItem(at: file)
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(timers).write(to: file, options: .atomic)
        } catch {
            // A timer that can't be written still fires this session; it just
            // won't survive a restart. Losing the session's timer as well would
            // make a disk problem worse than it is.
            Log.dispatch.error("could not persist timers: \(error.localizedDescription, privacy: .public)")
        }
    }
}
