import Foundation

/// An advisory lock shared between processes.
///
/// The app and the CLI both write the same state files, and a read-modify-write
/// split across two processes loses whichever update lands second. `flock` is
/// held for the whole cycle so the loser reads the winner's result instead of
/// overwriting it.
///
/// The lock is a **separate** file from the data it guards, deliberately.
/// Atomic writes replace the file by renaming a temporary over it, which swaps
/// the inode — a lock taken on the data file would be held on an inode nobody
/// else can see, and every process would think it had exclusive access.
public final class FileLock: @unchecked Sendable {
    private let descriptor: Int32

    public init?(at url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let descriptor = open(url.path, O_RDONLY | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            Log.dispatch.error("could not open lock file at \(url.path, privacy: .public)")
            return nil
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    /// Runs `body` holding the lock.
    ///
    /// Waiting is bounded and the work runs regardless. A held lock means
    /// another process is mid-write, which takes microseconds — if it somehow
    /// takes longer than this, the process is wedged, and blocking the voice
    /// pipeline behind it would turn one stuck process into a stuck assistant.
    /// Losing an update in that case is the lesser failure, and it's logged.
    public func withLock<T>(timeout: TimeInterval = 2, _ body: () throws -> T) rethrows -> T {
        let acquired = acquire(before: Date().addingTimeInterval(timeout))
        // Released even when `body` throws — a write that failed must not leave
        // every other process waiting on a lock nobody will give back.
        defer { if acquired { flock(descriptor, LOCK_UN) } }
        return try body()
    }

    /// Runs `body` holding the lock that guards `url`.
    ///
    /// A fresh lock per call on purpose: `flock` is held per open file
    /// description, so sharing one descriptor between callers in this process
    /// would let both inside at once — the second `LOCK_EX` on a descriptor
    /// that already holds it succeeds immediately. Opening a file costs
    /// microseconds; losing mutual exclusion costs data.
    public static func withLock<T>(
        guarding url: URL, timeout: TimeInterval = 2, _ body: () throws -> T
    ) rethrows -> T {
        guard let lock = FileLock(at: url.appendingPathExtension("lock")) else { return try body() }
        return try lock.withLock(timeout: timeout, body)
    }

    private func acquire(before deadline: Date) -> Bool {
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
            guard Date() < deadline else {
                Log.dispatch.error("timed out waiting for a file lock; proceeding unlocked")
                return false
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
}
