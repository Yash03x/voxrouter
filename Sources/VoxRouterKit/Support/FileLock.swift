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
    public func withLock<T>(timeout: TimeInterval = 2, _ body: () -> T) -> T {
        let acquired = acquire(before: Date().addingTimeInterval(timeout))
        defer { if acquired { flock(descriptor, LOCK_UN) } }
        return body()
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
