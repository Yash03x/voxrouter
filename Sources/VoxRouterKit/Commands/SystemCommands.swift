import Foundation

/// Small things the Mac can do itself.
///
/// None of these should cost twenty seconds and a slice of quota, which is what
/// dispatching "turn the volume down" to a coding agent would cost.
enum SystemControl {
    /// Current output volume, 0–100.
    static func currentVolume() -> Int? {
        guard let raw = osascript("output volume of (get volume settings)"),
              let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return value
    }

    @discardableResult
    static func setVolume(_ percent: Int) -> Bool {
        osascript("set volume output volume \(percent.clamped(to: 0...100))") != nil
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        osascript("set volume output muted \(muted)") != nil
    }

    /// Whether an installed application answers to this name.
    ///
    /// Needed because "open" is a common task verb — "open the parser and
    /// refactor it" was being taken as a launch request and never reached an
    /// engine. Claiming the utterance requires the app to exist.
    static func applicationExists(named name: String) -> Bool {
        let normalized = name.lowercased()
        let directories = [
            "/Applications", "/System/Applications",
            "/System/Applications/Utilities", "/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory)
            else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                if entry.dropLast(4).lowercased() == normalized { return true }
            }
        }
        return false
    }

    static func openApplication(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", name]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @discardableResult
    static func osascript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Parses "five minutes", "90 seconds", "1 hour" into a duration.
enum DurationParser {
    private static let words: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "fifteen": 15,
        "twenty": 20, "thirty": 30, "forty": 40, "forty five": 45,
        "fortyfive": 45, "sixty": 60, "ninety": 90, "half": 30,
    ]

    /// Returns seconds, or nil if there's no duration in the text.
    static func seconds(in text: String) -> Int? {
        let lowered = text.lowercased()

        // Speech recognition writes numbers both ways depending on phrasing, so
        // both digits and words have to work.
        var amount: Int?
        if let match = lowered.range(of: #"\d+"#, options: .regularExpression) {
            amount = Int(lowered[match])
        } else {
            for (word, value) in words where lowered.contains(word) {
                amount = value
                break
            }
        }
        guard let amount, amount > 0 else { return nil }

        if lowered.contains("hour") { return amount * 3600 }
        if lowered.contains("second") { return amount }
        // Minutes is the sensible default for a spoken timer.
        return amount * 60
    }

    static func spoken(_ seconds: Int) -> String {
        if seconds % 3600 == 0, seconds >= 3600 {
            let hours = seconds / 3600
            return hours == 1 ? "an hour" : "\(hours) hours"
        }
        if seconds >= 60 {
            let minutes = seconds / 60
            return minutes == 1 ? "a minute" : "\(minutes) minutes"
        }
        return "\(seconds) seconds"
    }
}

// MARK: - Commands

extension LocalCommand {
    public static let volume = LocalCommand(
        id: "system.volume",
        examples: ["volume up", "mute", "set volume to 30"],
        matches: { text in
            let normalized = normalize(text)
            let triggers = [
                "volume up", "turn it up", "turn the volume up", "louder",
                "volume down", "turn it down", "turn the volume down", "quieter",
                "mute", "mute it", "unmute", "unmute it",
            ]
            if triggers.contains(normalized) { return Invocation(argument: normalized) }
            if let match = prefixed(["set volume to", "set the volume to", "volume"])(text),
               Int(match.argument) != nil {
                return Invocation(argument: "set \(match.argument)")
            }
            return nil
        },
        perform: { invocation, _ in
            let argument = invocation.argument
            if argument.hasPrefix("set "), let target = Int(argument.dropFirst(4)) {
                SystemControl.setMuted(false)
                SystemControl.setVolume(target)
                return nil  // The change is audible; saying so is noise.
            }
            if argument.hasPrefix("mute") {
                SystemControl.setMuted(true)
                return nil
            }
            if argument.hasPrefix("unmute") {
                SystemControl.setMuted(false)
                return nil
            }
            guard let current = SystemControl.currentVolume() else { return nil }
            let isUp = argument.contains("up") || argument.contains("louder")
            SystemControl.setMuted(false)
            SystemControl.setVolume(current + (isUp ? 12 : -12))
            return nil
        }
    )

    public static let openApp = LocalCommand(
        id: "system.open",
        examples: ["open Safari", "launch Spotify"],
        matches: { text in
            guard let invocation = prefixed(["open", "launch", "open up"])(text) else { return nil }
            // Only claim it if the target is real — a shortcut or an installed
            // app. Otherwise "open the parser and refactor it" never reaches an
            // engine.
            let isShortcut = Shortcuts.resolve(invocation.argument) != nil
            let isApp = SystemControl.applicationExists(named: invocation.argument)
            return (isShortcut || isApp) ? invocation : nil
        },
        perform: { invocation, _ in
            // "open my watchlist" is far more likely to be a shortcut than an
            // app, so shortcuts win the name before Finder is asked.
            if let shortcut = Shortcuts.resolve(invocation.argument) {
                let result = Shortcuts.run(named: shortcut)
                // Fall through to launching an app only when no such shortcut
                // exists. A shortcut that ran and reported a real problem —
                // "requires Letterboxd to be installed" — should say so rather
                // than silently trying something else.
                if case .failure(.notFound) = result {} else {
                    return Shortcuts.spokenResult(of: result)
                }
            }
            guard SystemControl.openApplication(invocation.argument) else {
                return "I couldn't open \(invocation.argument)."
            }
            return nil  // It's now on screen; announcing it is redundant.
        }
    )

    public static let setTimer = LocalCommand(
        id: "system.timer",
        examples: ["set a timer for five minutes", "timer for 30 seconds"],
        matches: { text in
            let normalized = normalize(text)
            let isTimer = normalized.hasPrefix("set a timer")
                || normalized.hasPrefix("set timer")
                || normalized.hasPrefix("timer for")
                || normalized.hasPrefix("remind me in")
            guard isTimer else { return nil }
            return Invocation(argument: normalized)
        },
        perform: { invocation, context in
            guard let seconds = DurationParser.seconds(in: invocation.argument) else {
                return "How long for?"
            }
            let notify = context.notify
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                await notify("Your \(DurationParser.spoken(seconds)) timer is up.")
            }
            return "Timer set for \(DurationParser.spoken(seconds))."
        }
    )

    public static let quotaReport = LocalCommand(
        id: "quota.report",
        examples: ["what's my quota", "how much quota is left"],
        matches: exact([
            "what's my quota", "whats my quota", "what is my quota",
            "how much quota do i have", "how much quota is left",
            "quota", "check quota", "how's my quota", "hows my quota",
        ]),
        perform: { _, context in
            let providers = await context.quota()
            guard !providers.isEmpty else {
                return "I can't reach the quota dashboard."
            }
            // Only the binding window per engine — the one that decides routing.
            // Reading every window aloud would be a wall of numbers.
            let parts = providers.compactMap { provider -> String? in
                guard let window = provider.bindingWindow else { return nil }
                let name = provider.displayName ?? provider.providerId
                return "\(name) \(Int(window.usedPercent)) percent used"
            }
            return parts.isEmpty ? "No quota reported." : parts.joined(separator: ", ") + "."
        }
    )

    public static let repeatLast = LocalCommand(
        id: "assistant.repeat",
        examples: ["say that again", "what did you say"],
        matches: exact([
            "say that again", "what did you say", "repeat that", "again",
            "come again", "sorry what", "what was that",
        ]),
        perform: { _, context in
            await context.lastReply() ?? "I haven't said anything yet."
        }
    )

    public static let capabilities = LocalCommand(
        id: "assistant.help",
        examples: ["what can you do"],
        matches: exact([
            "what can you do", "what can i say", "help", "what are your commands",
        ]),
        perform: { _, _ in
            "Ask me to run a shortcut, set a timer, change the volume, open an "
            + "app, take a note, or check your quota. Anything else I'll hand to "
            + "Claude or Codex."
        }
    )
}
