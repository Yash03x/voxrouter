import Foundation

/// Quick capture — the thing you want when you're mid-something and can't stop.
///
/// Appends to a dated markdown file rather than pushing into Apple Notes: no
/// permission needed, greppable, and it survives the app being uninstalled.
/// A shortcut can move it into Notes for anyone who wants that.
public enum QuickNote {
    /// Appends a note.
    ///
    /// The read and the write are one locked step. This is a read-modify-write
    /// on a file the app and the CLI both own, and without the lock it lost
    /// notes exactly as the timer file did — measured at 5 of 12 surviving when
    /// twelve notes were taken at once. A dropped note is the worst version of
    /// this bug: the whole point of quick capture is that you stop holding the
    /// thing in your head.
    public static func append(_ text: String, to file: URL, now: Date = Date()) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        try FileLock.withLock(guarding: file) {
            let day = dayFormatter.string(from: now)
            let time = timeFormatter.string(from: now)
            var contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""

            // One heading per day, so a week of notes reads as a journal rather
            // than an undifferentiated list.
            let heading = "## \(day)"
            if !contents.contains(heading) {
                if !contents.isEmpty && !contents.hasSuffix("\n\n") { contents += "\n" }
                contents += "\n\(heading)\n\n"
            }
            contents += "- \(time) — \(trimmed)\n"

            try Data(contents.utf8).write(to: file, options: .atomic)
        }
    }

    public static func recent(from file: URL, limit: Int = 3) -> [String] {
        guard let contents = FileLock.withLock(guarding: file, {
            try? String(contentsOf: file, encoding: .utf8)
        }) else { return [] }
        return contents
            .split(separator: "\n")
            .filter { $0.hasPrefix("- ") }
            .suffix(limit)
            .map { line in
                // Strip the "- HH:mm — " prefix; the text is what matters aloud.
                guard let range = line.range(of: " — ") else {
                    return String(line.dropFirst(2))
                }
                return String(line[range.upperBound...])
            }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // POSIX locale, or this renders 12-hour with a suffix under locales that
        // prefer it — the same trap that put a space in run-id directories.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

extension LocalCommand {
    public static let note = LocalCommand(
        id: "note.capture",
        examples: ["note down the lease renews in March", "remember that the wifi password changed"],
        matches: { text in
            // "remind me in ten minutes" is a timer, not a note — the timer
            // command sits earlier in the registry, but guard here too so
            // reordering can't silently swallow timers.
            let normalized = normalize(text)
            if normalized.hasPrefix("remind me in") { return nil }
            // Bare "note" is deliberately absent. "Note the retry logic is
            // wrong and fix it" is a task, and capturing it as a note loses it
            // silently — whereas a note that reaches an engine merely costs
            // quota. Every prefix here states the intent to record something.
            return prefixed([
                "note down", "note that", "note to self", "make a note",
                "take a note", "remember that", "jot down", "write down",
            ])(text)
        },
        perform: { invocation, context in
            do {
                try QuickNote.append(invocation.argument, to: context.notesFile)
                return "Noted."
            } catch {
                return "I couldn't save that note."
            }
        }
    )

    public static let readNotes = LocalCommand(
        id: "note.read",
        examples: ["what are my notes", "read my notes"],
        matches: exact([
            "what are my notes", "read my notes", "my notes", "read back my notes",
            "what did i note down",
        ]),
        perform: { _, context in
            let notes = QuickNote.recent(from: context.notesFile)
            guard !notes.isEmpty else { return "You haven't noted anything yet." }
            return notes.joined(separator: ". ")
        }
    )
}
