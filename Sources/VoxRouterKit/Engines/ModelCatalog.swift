import Foundation

/// Discovers model names from the engine binaries, so the picker keeps up with
/// CLI updates on its own.
///
/// Neither CLI can enumerate its models — there's no `claude models`, no codex
/// equivalent — so the names have to be read out of the binaries. Doing that by
/// hand means the list silently goes stale the moment either tool updates, and
/// a model you're entitled to use just isn't offered.
///
/// The scan costs about three seconds against a 245 MB binary, so it runs off
/// the main path and the result is cached against the binary's size and
/// modification date. A CLI update changes both, which invalidates the cache
/// exactly when it should.
///
/// Results are always *merged* with the built-in list rather than replacing it:
/// a failed or empty scan then costs nothing, instead of emptying the picker.
public enum ModelCatalog {
    private struct Entry: Codable {
        var binaryPath: String
        var size: Int
        var modified: Date
        var models: [String]
    }

    private struct Cache: Codable {
        var entries: [String: Entry] = [:]
    }

    private static var cacheURL: URL {
        Config.stateDirectory.appendingPathComponent("model-catalog.json")
    }

    /// Patterns kept deliberately strict. A loose match picks up strings like
    /// `fable-consent-result` and `opusplan-mode-reminder`, which are not models
    /// and would clutter the menu with names the CLI rejects.
    static func pattern(for engineId: String) -> String? {
        switch engineId {
        case "claude":
            return #""(opus|sonnet|haiku|fable)(-?[0-9]+(-[0-9]+)*|plan)?""#
        case "codex":
            return #"gpt-[0-9]+(\.[0-9]+)?(-[a-z]+)*"#
        default:
            return nil
        }
    }

    /// Cached names for an engine, or nil when nothing has been scanned yet.
    public static func cached(for engineId: String, binary: URL) -> [String]? {
        guard let cache = loadCache(), let entry = cache.entries[engineId] else { return nil }
        guard entry.binaryPath == binary.path, isCurrent(entry, binary: binary) else { return nil }
        return entry.models
    }

    /// Scans if the cache is stale, otherwise returns it. Slow on a miss —
    /// call from a background task.
    @discardableResult
    public static func refresh(for engineId: String, binary: URL) -> [String] {
        if let cached = cached(for: engineId, binary: binary) { return cached }
        guard let pattern = pattern(for: engineId) else { return [] }

        let found = scan(binary: binary, pattern: pattern)
        guard !found.isEmpty else { return [] }

        var cache = loadCache() ?? Cache()
        let attributes = try? FileManager.default.attributesOfItem(atPath: binary.path)
        cache.entries[engineId] = Entry(
            binaryPath: binary.path,
            size: (attributes?[.size] as? Int) ?? 0,
            modified: (attributes?[.modificationDate] as? Date) ?? .distantPast,
            models: found
        )
        saveCache(cache)
        Log.engine.notice(
            "discovered \(found.count, privacy: .public) models for \(engineId, privacy: .public)"
        )
        return found
    }

    // MARK: - Scanning

    /// Uses `grep` rather than reading the file in: it's optimised for exactly
    /// this, and 245 MB through Foundation would be far slower and hold the
    /// whole binary in memory.
    private static func scan(binary: URL, pattern: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        // -a treats the binary as text; -o prints only the matches.
        process.arguments = ["-aoE", pattern, binary.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        guard (try? process.run()) != nil else { return [] }
        // Drained concurrently, same as every other subprocess here: an
        // unread stderr pipe deadlocks the child once its buffer fills.
        let errorHandle = errors.fileHandleForReading
        let drain = Thread { _ = errorHandle.readDataToEndOfFile() }
        drain.stackSize = 64 * 1024
        drain.start()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let matches = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        return matches.filter { seen.insert($0).inserted }.sorted()
    }

    private static func isCurrent(_ entry: Entry, binary: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: binary.path)
        else { return false }
        let size = (attributes[.size] as? Int) ?? -1
        let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
        return size == entry.size && abs(modified.timeIntervalSince(entry.modified)) < 1
    }

    // MARK: - Cache IO

    private static func loadCache() -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Cache.self, from: data)
    }

    private static func saveCache(_ cache: Cache) {
        do {
            try FileManager.default.createDirectory(
                at: Config.stateDirectory, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(cache).write(to: cacheURL, options: .atomic)
        } catch {
            // A cache that can't be written costs a rescan, not a failure.
            Log.engine.error(
                "could not cache model catalog: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
