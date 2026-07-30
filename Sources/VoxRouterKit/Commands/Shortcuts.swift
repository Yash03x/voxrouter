import Foundation

/// Bridge to the macOS Shortcuts app.
///
/// The highest-leverage integration available: Shortcuts already holds the
/// permissions for Calendar, Reminders, Notes, Music, Home and everything else,
/// so running one asks *Shortcuts* to act rather than requesting those grants
/// ourselves. One bridge instead of one integration per app — and every
/// shortcut the user makes later is voice-callable with no code change.
public enum Shortcuts {
    /// Names of every shortcut on the machine.
    ///
    /// Cached briefly: `shortcuts list` shells out, and a spoken command
    /// shouldn't wait on it more than once in a while.
    public static func available(now: Date = Date()) -> [String] {
        if let cached = cache, now.timeIntervalSince(cached.at) < cacheLifetime {
            return cached.names
        }

        // An expired cache is served anyway, and refreshed off this thread.
        // This sits on the classification path of nearly every utterance, so a
        // synchronous `shortcuts list` would add a second of dead air to the
        // first thing said each minute — to catch a shortcut installed within
        // the last sixty seconds, which is not worth stalling speech for.
        if let cached = cache {
            refreshInBackground(now: now)
            return cached.names
        }

        // Nothing cached at all (first use, before the launch warm-up has
        // landed) — only then is it worth blocking, briefly.
        return refresh(now: now)
    }

    private static func refreshInBackground(now: Date) {
        guard beginRefresh() else { return }
        Thread.detachNewThread {
            defer { endRefresh() }
            _ = refreshLocked(now: now)
        }
    }

    private static func refresh(now: Date) -> [String] {
        guard beginRefresh() else { return cache?.names ?? [] }
        defer { endRefresh() }
        return refreshLocked(now: now)
    }

    /// The actual fetch. Callers hold the refresh flag, not the state lock.
    private static func refreshLocked(now: Date) -> [String] {
        // Don't re-attempt straight after a failure. The shortcut service
        // really can wedge — when it does, `list` burns its whole timeout,
        // and retrying on each utterance would stall everything said.
        if let failedAt, now.timeIntervalSince(failedAt) < retryAfterFailure {
            return cache?.names ?? []
        }

        // Listing is a database read — if it doesn't answer promptly something
        // is wrong with the service, and a voice command shouldn't wait on it.
        guard case .completed(0, let stdout, _) = execute(["list"], timeout: listTimeout) else {
            // The last known names are kept rather than replaced with nothing:
            // reporting "I don't have a shortcut called X" because of a slow
            // read points at entirely the wrong problem.
            Log.dispatch.notice("could not list shortcuts")
            failedAt = now
            return cache?.names ?? []
        }
        let names = stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        cache = (names, now)
        failedAt = nil
        return names
    }

    /// Fills the cache off the critical path.
    ///
    /// Otherwise the first thing said after launch waits on `shortcuts list` —
    /// about a second — before it can even be classified.
    public static func warm() {
        Thread.detachNewThread { _ = available() }
    }

    /// A shortcut whose name *is* the whole utterance.
    ///
    /// Strict equality, unlike ``resolve(_:in:)``. Saying a shortcut's exact
    /// name should run it — you shouldn't have to say "run" first when you
    /// named the thing "Turn off the lights". But bare utterances are also how
    /// every ordinary request arrives, so the fuzzy containment match is far
    /// too eager here: "log a film about the trip" must not become "Log a film".
    public static func exactMatch(_ spoken: String, in names: [String]? = nil) -> String? {
        let target = normalize(spoken)
        guard !target.isEmpty else { return nil }
        return (names ?? available()).first { normalize($0) == target }
    }

    /// Best match for a spoken name.
    ///
    /// Speech gives you "turn off the lights" for `Turn off the lights`, and may
    /// drop or add a filler word, so matching is on normalised alphanumerics
    /// rather than exact text — the same approach that works for project names.
    public static func resolve(_ spoken: String, in names: [String]? = nil) -> String? {
        let candidates = names ?? available()
        let target = words(spoken)
        guard !target.isEmpty else { return nil }

        if let exact = candidates.first(where: { words($0) == target }) {
            return exact
        }
        // Longest containing match, so "letterboxd diary" prefers
        // "Open my Letterboxd diary" over "Search Letterboxd".
        return candidates
            .filter { partiallyMatches(name: words($0), target: target) }
            .max { words($0).count < words($1).count }
    }

    /// Whether a spoken fragment and a shortcut name refer to the same thing.
    ///
    /// Matching is on whole words, and this used to be raw substring
    /// containment in both directions — which meant a *short* shortcut name was
    /// a substring of almost any sentence. With a shortcut named "VPN", "run the
    /// logging pipeline against the vpn box" resolved to it and was swallowed as
    /// a shortcut invocation. Nobody's own shortcuts happened to be that short,
    /// but "Log", "Home", "TV" and "PC" are perfectly ordinary names.
    static func partiallyMatches(name: [String], target: [String]) -> Bool {
        guard !name.isEmpty else { return false }

        // The name is the longer side: the fragment names part of it, as in
        // "watchlist" for "Open my watchlist". Safe — whatever the user said is
        // entirely accounted for by the shortcut's name.
        if contains(name, target) { return true }

        // The utterance is the longer side, so the name has to account for most
        // of it. "water eject please" is an invocation; a sentence with the
        // name buried in it is a task that happens to mention it.
        guard contains(target, name) else { return false }
        return Double(name.count) / Double(target.count) >= 0.5
    }

    static func words(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    /// Whether `needle` appears in `haystack` as a run of whole words.
    private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    /// Runs a shortcut and returns whatever it wrote to output, if anything.
    public static func run(named name: String) -> Result<String?, ShortcutsError> {
        guard !available().isEmpty else { return .failure(.unavailable) }
        guard let resolved = resolve(name) else { return .failure(.notFound(name)) }

        // Output goes to a file rather than stdout: `shortcuts run` writes
        // results only when asked to, and a shortcut that returns text should
        // be able to answer out loud.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxrouter-shortcut-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        switch execute(["run", resolved, "--output-path", outputURL.path]) {
        case .unavailable:
            return .failure(.unavailable)

        case .stillRunning:
            // Not a failure. "Water Eject" plays a tone for half a minute;
            // a shortcut that opens an app may sit until it finishes launching.
            // It keeps running — we just stop waiting for it.
            return .failure(.stillRunning(resolved))

        case .completed(let status, _, let stderr):
            guard status == 0 else {
                // `shortcuts` puts a genuinely useful sentence on stderr —
                // "This action requires Letterboxd to be installed." Speaking
                // that beats speaking "it didn't finish".
                return .failure(.failed(name: resolved, reason: firstSentence(of: stderr)))
            }
            let output = (try? String(contentsOf: outputURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(output?.isEmpty == false ? output : nil)
        }
    }

    // MARK: - Plumbing

    public enum ShortcutsError: Error, Equatable {
        case unavailable
        case notFound(String)
        /// Ran and reported a problem. `reason` is the CLI's own message.
        case failed(name: String, reason: String?)
        /// Started and hasn't finished yet — still running, not broken.
        case stillRunning(String)
    }

    /// Strips the CLI's "Error: " prefix and keeps one speakable sentence.
    static func firstSentence(of stderr: String) -> String? {
        var text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let line = text.split(separator: "\n").first { text = String(line) }
        for prefix in ["Error: ", "error: "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static let cacheLifetime: TimeInterval = 60
    /// Long enough that a wedged service isn't retried on every utterance,
    /// short enough that a transient failure doesn't hide shortcuts for long.
    static let retryAfterFailure: TimeInterval = 10
    static let listTimeout: TimeInterval = 5

    /// Guarded by `stateLock`: `warm()` writes from a detached thread while
    /// the voice pipeline reads from its actor, which without the lock is a
    /// plain data race on a tuple — exactly the kind that never shows up until
    /// the first utterance lands during the warm-up read.
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var _cache: (names: [String], at: Date)?
    nonisolated(unsafe) private static var _failedAt: Date?

    private static var cache: (names: [String], at: Date)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _cache }
        set { stateLock.lock(); _cache = newValue; stateLock.unlock() }
    }

    private static var failedAt: Date? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _failedAt }
        set { stateLock.lock(); _failedAt = newValue; stateLock.unlock() }
    }

    /// At most one `shortcuts list` in flight. Without this, every utterance
    /// in the window after expiry would kick off its own subprocess.
    nonisolated(unsafe) private static var _refreshing = false

    private static func beginRefresh() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !_refreshing else { return false }
        _refreshing = true
        return true
    }

    private static func endRefresh() {
        stateLock.lock(); _refreshing = false; stateLock.unlock()
    }

    /// Test seam — resets the process-wide cache.
    static func resetCache() {
        cache = nil
        failedAt = nil
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    enum Execution {
        case completed(status: Int32, stdout: String, stderr: String)
        case stillRunning
        case unavailable
    }

    /// How long a spoken command waits before giving up on an answer.
    ///
    /// Not a failure deadline — shortcuts legitimately run longer than this
    /// ("Water Eject" plays a tone for about half a minute). It's just the
    /// point past which standing silent is worse than saying "it's running".
    static let replyTimeout: TimeInterval = 12

    /// How long a shortcut is left alone before it's assumed stuck.
    ///
    /// Generous, because the cure has been worse than the disease: SIGKILLing
    /// a `shortcuts run` mid-request wedged the system's shortcut service so
    /// thoroughly that *every* later run — CLI and AppleScript alike — hung
    /// until the service was restarted. So this waits minutes, then sends
    /// SIGTERM only, letting the CLI tear its XPC connection down cleanly.
    static let abandonAfter: TimeInterval = 300

    private static func execute(
        _ arguments: [String],
        timeout: TimeInterval = replyTimeout
    ) -> Execution {
        let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .unavailable
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return .unavailable }

        // Both pipes are drained on their own threads. Leaving either unread
        // would deadlock the child once its 64K buffer filled — and stderr is
        // where the CLI writes the one useful sentence it produces.
        let collectedErrors = drain(errors)
        let collectedOutput = drain(output)

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard !process.isRunning else {
            abandon(process, after: abandonAfter)
            return .stillRunning
        }
        return .completed(
            status: process.terminationStatus,
            stdout: String(decoding: collectedOutput.get(), as: UTF8.self),
            stderr: String(decoding: collectedErrors.get(), as: UTF8.self)
        )
    }

    private static func drain(_ pipe: Pipe) -> Locked<Data> {
        let collected = Locked<Data>(Data())
        let handle = pipe.fileHandleForReading
        let thread = Thread { collected.set(handle.readDataToEndOfFile()) }
        thread.stackSize = 64 * 1024
        thread.start()
        return collected
    }

    /// Stops waiting on a shortcut, and eventually stops it.
    private static func abandon(_ process: Process, after grace: TimeInterval) {
        Log.dispatch.notice("shortcut still running; no longer waiting on it")
        let box = Unchecked(process)
        let thread = Thread {
            let deadline = Date().addingTimeInterval(grace)
            while box.value.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 1)
            }
            guard box.value.isRunning else { return }
            Log.dispatch.notice("shortcut exceeded grace period; terminating")
            box.value.terminate()
        }
        thread.stackSize = 64 * 1024
        thread.start()
    }
}

/// Minimal mutable box for handing a value back from a thread.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
}

/// Carries a non-Sendable reference onto a thread we own end to end.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

extension Shortcuts {
    /// Turns a run outcome into something worth saying out loud.
    static func spokenResult(of result: Result<String?, ShortcutsError>) -> String? {
        switch result {
        case .success(let output):
            // A shortcut that returns text should answer out loud; one that
            // returns nothing has already done its thing visibly, and
            // announcing it would just be noise.
            guard let output, !output.isEmpty else { return nil }
            return SpokenNarration.speakable(output, maxCharacters: 200)

        case .failure(.notFound(let name)):
            guard !available().isEmpty else {
                return "I couldn't find any shortcuts on this Mac."
            }
            return "I don't have a shortcut called \(name)."

        case .failure(.unavailable):
            return "Shortcuts isn't available on this Mac."

        case .failure(.stillRunning(let name)):
            return "\(name) is running."

        case .failure(.failed(let name, let reason)):
            guard let reason else { return "\(name) didn't finish." }
            // The CLI's own message — "This action requires Letterboxd to be
            // installed" — tells the user what to fix. Ours never could.
            return SpokenNarration.speakable(reason, maxCharacters: 200)
        }
    }
}

// MARK: - Commands

extension LocalCommand {
    public static let runShortcut = LocalCommand(
        id: "shortcut.run",
        examples: ["run turn off the lights", "run the water eject shortcut"],
        matches: { text in
            // Saying the shortcut's own name is enough.
            if let exact = Shortcuts.exactMatch(text) { return Invocation(argument: exact) }

            guard let invocation = prefixed(["run", "run the", "shortcut", "run shortcut"])(text)
            else { return nil }
            // "run the X shortcut" — drop the trailing noun so the name matches.
            var argument = invocation.argument
            for suffix in [" shortcut", " short cut"] where argument.hasSuffix(suffix) {
                argument = String(argument.dropLast(suffix.count))
            }
            argument = argument.trimmingCharacters(in: .whitespaces)
            guard !argument.isEmpty else { return nil }

            // Claim it only if a shortcut by that name actually exists. "run"
            // is one of the commonest task verbs — "run the tests and fix what
            // breaks" was being swallowed as a shortcut name and never reached
            // an engine. Matching on the verb alone is not enough; the target
            // has to be real.
            guard Shortcuts.resolve(argument) != nil else { return nil }
            return Invocation(argument: argument)
        },
        perform: { invocation, _ in
            Shortcuts.spokenResult(of: Shortcuts.run(named: invocation.argument))
        }
    )

    public static let listShortcuts = LocalCommand(
        id: "shortcut.list",
        examples: ["what shortcuts do I have", "list my shortcuts"],
        matches: exact([
            "what shortcuts do i have", "list my shortcuts", "list shortcuts",
            "what shortcuts are there", "my shortcuts",
        ]),
        perform: { _, _ in
            let names = Shortcuts.available()
            guard !names.isEmpty else { return "I couldn't find any shortcuts." }
            // Reading fifteen names aloud is a poor experience, so the count
            // leads and only a few are named.
            let sample = names.prefix(5).joined(separator: ", ")
            if names.count <= 5 { return "You have \(names.count): \(sample)." }
            return "You have \(names.count), including \(sample)."
        }
    )
}
