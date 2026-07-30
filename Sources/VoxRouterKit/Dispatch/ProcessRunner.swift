import Foundation

public enum ProcessLine: Sendable {
    case stdout(String)
    case stderr(String)
    case exited(Int32)
}

public enum ProcessRunner {
    /// Streams a subprocess's output line by line as it arrives.
    ///
    /// Line-at-a-time rather than collect-then-parse: an engine run lasts
    /// minutes, and both the spoken progress updates and rate-limit failover
    /// depend on reacting mid-run rather than at exit.
    public static func stream(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]? = nil
    ) -> AsyncStream<ProcessLine> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.environment = environment ?? ProcessInfo.processInfo.environment
            // Never let a subprocess block waiting on a tty we don't have.
            process.standardInput = FileHandle.nullDevice

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            // readabilityHandler rather than async bytes: it delivers on a
            // Dispatch-managed queue without holding a Swift concurrency thread
            // per pipe for the whole run.
            let stdoutBuffer = LineBuffer { continuation.yield(.stdout($0)) }
            let stderrBuffer = LineBuffer { continuation.yield(.stderr($0)) }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    stdoutBuffer.flush()
                } else {
                    stdoutBuffer.append(data)
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    stderrBuffer.flush()
                } else {
                    stderrBuffer.append(data)
                }
            }

            process.terminationHandler = { finished in
                // Drain whatever is still buffered in the pipes before
                // reporting exit, or the final (often most important) lines are
                // lost to the race with termination.
                stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
                stdoutBuffer.flush()
                stderrBuffer.flush()
                continuation.yield(.exited(finished.terminationStatus))
                continuation.finish()
            }

            continuation.onTermination = { reason in
                if case .cancelled = reason, process.isRunning {
                    process.terminate()
                }
            }

            do {
                try process.run()
            } catch {
                continuation.yield(.stderr("failed to launch \(executable.path): \(error.localizedDescription)"))
                continuation.yield(.exited(-1))
                continuation.finish()
            }
        }
    }
}

/// Accumulates bytes and emits complete lines. Pipe reads split mid-line
/// constantly, and a half-line of JSON parses as garbage.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let emit: (String) -> Void
    private let lock = NSLock()

    init(emit: @escaping (String) -> Void) {
        self.emit = emit
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if !lineData.isEmpty {
                lines.append(String(decoding: lineData, as: UTF8.self))
            }
        }
        lock.unlock()
        for line in lines { emit(line) }
    }

    func flush() {
        lock.lock()
        let remainder = pending
        pending.removeAll()
        lock.unlock()
        guard !remainder.isEmpty else { return }
        emit(String(decoding: remainder, as: UTF8.self))
    }
}
