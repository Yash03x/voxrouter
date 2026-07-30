import Foundation

/// Spots spoken requests that could destroy work, so they can be confirmed
/// before running.
///
/// The failure mode this exists for is specific: speech recognition mishears,
/// and with approval prompts disabled the engine will act on the mishearing
/// immediately and irreversibly. A gate here is the only thing standing between
/// a misheard sentence and `rm -rf`.
///
/// Tuned to avoid crying wolf. "Delete the unused import" is destructive in the
/// abstract and completely routine in practice; confirming it would train the
/// user to say yes reflexively, which is worse than not asking. So it fires on
/// *inherently* dangerous operations, or on a destructive verb aimed at a
/// *broad* target.
public enum DestructiveIntent {
    public struct Assessment: Sendable, Equatable {
        /// The phrase that triggered it, for speaking back.
        public let trigger: String
        public let reason: String
    }

    /// Operations that are dangerous regardless of what they're aimed at.
    static let alwaysConfirm: [(pattern: String, reason: String)] = [
        ("rm -rf", "a recursive force delete"),
        ("rm -fr", "a recursive force delete"),
        ("sudo", "a command as root"),
        ("force push", "a force push"),
        ("push --force", "a force push"),
        ("push -f", "a force push"),
        ("reset --hard", "a hard reset"),
        ("hard reset", "a hard reset"),
        ("drop database", "dropping a database"),
        ("drop table", "dropping a table"),
        ("truncate table", "truncating a table"),
        ("git clean", "deleting untracked files"),
        ("format the disk", "formatting a disk"),
        ("factory reset", "a factory reset"),
        ("delete the repo", "deleting a repository"),
        ("delete the repository", "deleting a repository"),
    ]

    /// Verbs that only warrant confirmation when aimed at something broad.
    static let destructiveVerbs = [
        "delete", "remove", "wipe", "erase", "destroy", "purge", "clear out",
        "get rid of", "nuke", "drop",
    ]

    /// Targets broad enough that losing them would hurt.
    static let broadTargets = [
        "everything", "all files", "all the files", "every file", "the whole",
        "entire", "the folder", "the directory", "the repo", "the repository",
        "the database", "the history", "my files", "the branch", "all branches",
        "the commits", "node_modules", "the build", "all data", "the data",
        "home directory", "downloads", "documents", "desktop",
    ]

    /// Returns an assessment when the request should be confirmed, else nil.
    public static func assess(_ text: String) -> Assessment? {
        let lowered = text.lowercased()

        for entry in alwaysConfirm where lowered.contains(entry.pattern) {
            return Assessment(trigger: entry.pattern, reason: entry.reason)
        }

        for verb in destructiveVerbs where lowered.contains(verb) {
            for target in broadTargets where lowered.contains(target) {
                return Assessment(
                    trigger: "\(verb) \(target)",
                    reason: "\(verb) \(target)"
                )
            }
        }

        return nil
    }

    // MARK: - Confirmation replies

    private static let affirmations: Set<String> = [
        "yes", "yeah", "yep", "yes please", "confirm", "confirmed", "do it",
        "go ahead", "proceed", "affirmative", "correct", "that's right", "ok",
        "okay", "sure",
    ]

    private static let negations: Set<String> = [
        "no", "nope", "cancel", "stop", "don't", "do not", "abort", "never mind",
        "nevermind", "forget it", "no thanks",
    ]

    public enum Reply: Sendable, Equatable {
        case affirm
        case decline
        /// Neither — treated as a decline, because a confirmation must be
        /// unambiguous. If the recogniser mishears the confirmation too, the
        /// safe reading is "no".
        case unclear
    }

    public static func interpretReply(_ text: String) -> Reply {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
        if affirmations.contains(normalized) { return .affirm }
        if negations.contains(normalized) { return .decline }
        return .unclear
    }
}
