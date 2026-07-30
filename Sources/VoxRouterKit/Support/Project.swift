import Foundation

/// A directory tasks can run in.
///
/// Scoping exists because `workingDirectory` alone was a poor fit: pointed at a
/// folder containing several repos, a spoken task had no particular project in
/// view; pointed at one repo, switching meant editing a config file. Named
/// projects make the target explicit and switchable by voice.
public struct Project: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    /// Display name, and what you say to switch to it.
    public var name: String
    public var path: String
    /// The unrestricted scope: starts at home rather than in a project.
    ///
    /// Kept as an explicit, named entry rather than an invisible mode, because
    /// "can this task touch anything on the Mac?" should never be ambiguous.
    public var isAnywhere: Bool

    public init(id: String = UUID().uuidString, name: String, path: String, isAnywhere: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.isAnywhere = isAnywhere
    }

    public var url: URL { URL(fileURLWithPath: path) }

    public var exists: Bool {
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return found && isDirectory.boolValue
    }

    /// Codex refuses to run outside a git repository unless told otherwise, so
    /// this is worth surfacing before a task fails.
    public var isGitRepository: Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    public static func anywhere() -> Project {
        Project(
            id: "anywhere",
            name: "Anywhere",
            path: NSHomeDirectory(),
            isAnywhere: true
        )
    }
}

// MARK: - Spoken matching

extension Project {
    /// Loose match for a spoken project name.
    ///
    /// Speech gives you "torrent client", the directory is `torrent-client`, and
    /// the recogniser may drop or add a word. Comparison is on normalised
    /// alphanumerics so punctuation and casing can't cause a miss.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func matches(spoken: String) -> Bool {
        let target = Self.normalize(spoken)
        guard !target.isEmpty else { return false }

        let candidates = [
            Self.normalize(name),
            Self.normalize(url.lastPathComponent),
        ]
        for candidate in candidates where !candidate.isEmpty {
            if candidate == target { return true }
            // "switch to voxrouter please" and "switch to vox" should both land.
            if candidate.contains(target) || target.contains(candidate) { return true }
            // Compare without spaces, so "torrent client" matches "torrentclient".
            let squashedCandidate = candidate.replacingOccurrences(of: " ", with: "")
            let squashedTarget = target.replacingOccurrences(of: " ", with: "")
            if squashedCandidate == squashedTarget { return true }
        }
        return false
    }
}

// MARK: - Spoken commands

public enum ProjectCommand {
    /// Recognises "switch to X" / "work in X" / "use X" and friends.
    ///
    /// Requires an explicit switching verb: a bare project name in the middle of
    /// a request is part of the task ("add tests to voxrouter"), not a command
    /// to change directory.
    static let prefixes = [
        "switch to", "switch project to", "work in", "work on", "go to",
        "use project", "change to", "open project", "switch me to",
    ]

    static let anywherePhrases = [
        "work anywhere", "anywhere mode", "switch to anywhere", "go anywhere",
        "whole mac", "unrestricted mode",
    ]

    /// The project name spoken, or nil if this isn't a switch command.
    public static func parse(_ text: String) -> String? {
        let lowered = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))

        for phrase in anywherePhrases where lowered == phrase {
            return "anywhere"
        }

        for prefix in prefixes where lowered.hasPrefix(prefix) {
            let name = lowered.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
            // "switch to" with nothing after it isn't a command.
            guard !name.isEmpty else { return nil }
            // A long tail means this was a task, not a switch.
            guard name.split(separator: " ").count <= 4 else { return nil }
            return name
        }
        return nil
    }
}
