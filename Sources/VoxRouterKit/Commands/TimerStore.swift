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
    private var pending: [PendingTimer] = []
    private var scheduled: [UUID: Task<Void, Never>] = [:]
    private var notify: @Sendable (String) async -> Void = { _ in }

    public init(file: URL) {
        self.file = file
    }

    public static var `default`: TimerStore {
        TimerStore(file: Config.stateDirectory.appendingPathComponent("timers.json"))
    }

    /// Where firing timers speak. Set before ``restore(now:)``.
    public func setNotifier(_ notify: @escaping @Sendable (String) async -> Void) {
        self.notify = notify
    }

    public func schedule(seconds: Int, now: Date = Date()) -> PendingTimer {
        loadIfNeeded()
        let timer = PendingTimer(dueAt: now.addingTimeInterval(TimeInterval(seconds)), duration: seconds)
        pending.append(timer)
        persist()
        arm(timer, after: TimeInterval(seconds))
        return timer
    }

    /// Reloads timers written before the app last stopped.
    ///
    /// Anything already due is announced as missed rather than silently
    /// dropped — the whole point is that you find out.
    public func restore(now: Date = Date()) {
        pending = read()
        loaded = true
        guard !pending.isEmpty else { return }

        var missed: [PendingTimer] = []
        var live: [PendingTimer] = []
        for timer in pending {
            let remaining = timer.dueAt.timeIntervalSince(now)
            if remaining > 0 {
                live.append(timer)
            } else if -remaining <= Self.missedGrace {
                missed.append(timer)
            }
            // Anything staler than the grace window is dropped without comment.
        }

        pending = live
        persist()
        for timer in live { arm(timer, after: timer.dueAt.timeIntervalSince(now)) }

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
        loadIfNeeded()
        let cancelled = pending
        for task in scheduled.values { task.cancel() }
        scheduled.removeAll()
        pending.removeAll()
        persist()
        return cancelled
    }

    public func timers(now: Date = Date()) -> [PendingTimer] {
        loadIfNeeded()
        return pending.filter { $0.dueAt > now }.sorted { $0.dueAt < $1.dueAt }
    }

    // MARK: - Plumbing

    private var loaded = false

    /// Reads what's on disk before the first use, without arming or announcing.
    ///
    /// Every read and write goes through this, because `persist()` writes the
    /// in-memory list wholesale: a process that hadn't loaded would replace a
    /// file full of timers with only the one it just made. That is exactly what
    /// happened — setting a timer from the CLI while the app held two others
    /// destroyed both, and "what timers do I have" answered "none" with one
    /// sitting in the file.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        pending = read()
    }

    private func read() -> [PendingTimer] {
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
        // Cancellation and firing race: only the one that gets here first wins.
        guard pending.contains(where: { $0.id == timer.id }) else { return }
        pending.removeAll { $0.id == timer.id }
        scheduled[timer.id] = nil
        persist()
        await notify("Your \(DurationParser.spoken(timer.duration)) timer is up.")
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            guard !pending.isEmpty else {
                try? FileManager.default.removeItem(at: file)
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(pending).write(to: file, options: .atomic)
        } catch {
            // A timer that can't be written still fires this session; it just
            // won't survive a restart. Losing the session's timer as well would
            // make a disk problem worse than it is.
            Log.dispatch.error("could not persist timers: \(error.localizedDescription, privacy: .public)")
        }
    }
}
