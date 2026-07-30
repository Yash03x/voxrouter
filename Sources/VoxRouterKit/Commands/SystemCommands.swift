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
    /// Number words are matched as whole tokens, longest form first.
    ///
    /// This was a substring scan over a dictionary, and dictionary order is
    /// unspecified — with per-process hash seeding, "forty five minutes" came
    /// back as 5, 40 or 45 minutes depending on the run, and "ninety seconds"
    /// as 9 seconds or a minute. A timer that silently sets a different
    /// duration each launch is worse than one that refuses to set at all.
    private static let units: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Returns seconds, or nil if there's no duration in the text.
    ///
    /// Each number is paired with the unit that follows it and the parts are
    /// summed, so "two minutes thirty seconds" is 150 rather than whichever
    /// single unit the sentence was scanned for first.
    static func seconds(in text: String) -> Int? {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var total = 0
        var pending: Int?
        var pendingHalf = false
        var sawUnit = false
        var index = 0

        while index < tokens.count {
            if let (value, consumed) = number(at: index, in: tokens) {
                pending = value
                index += consumed
                continue
            }
            if tokens[index] == "half" {
                pendingHalf = true
                index += 1
                continue
            }
            if let scale = unitScale(tokens[index]) {
                // A unit with no number means one of it: "set a timer for an
                // hour" states a duration without ever saying a number.
                total += pendingHalf ? scale / 2 : (pending ?? 1) * scale
                pending = nil
                pendingHalf = false
                sawUnit = true
            }
            index += 1
        }

        if !sawUnit {
            // "remind me in ten" — a number and no unit. Minutes is what
            // everyone who says it means.
            guard let pending, pending > 0 else { return nil }
            return pending * 60
        }
        return total > 0 ? total : nil
    }

    /// Unit words, matched whole.
    ///
    /// This was prefix matching, and `hasPrefix("min")` is true of "minus" —
    /// so "set a timer for minus five minutes" counted "minus" as a whole
    /// minute and set six. "minimum", "mine" and "minor" all did the same.
    private static let unitWords: [String: Int] = [
        "hour": 3600, "hours": 3600, "hr": 3600, "hrs": 3600,
        "minute": 60, "minutes": 60, "min": 60, "mins": 60,
        "second": 1, "seconds": 1, "sec": 1, "secs": 1,
    ]

    private static func unitScale(_ token: String) -> Int? {
        unitWords[token]
    }

    /// The number starting at `index`, and how many tokens it spans.
    private static func number(at index: Int, in tokens: [String]) -> (value: Int, consumed: Int)? {
        let token = tokens[index]
        // Speech recognition writes numbers both ways depending on phrasing, so
        // digits and words both have to work.
        if let digits = Int(token) { return (digits, 1) }

        if let ten = tens[token] {
            // "forty five" is two tokens and one number. Taking the tens word
            // alone would quietly set a 40-minute timer for a 45-minute ask.
            if index + 1 < tokens.count, let unit = units[tokens[index + 1]], unit < 10 {
                return (ten + unit, 2)
            }
            return (ten, 1)
        }
        if let unit = units[token] { return (unit, 1) }
        return nil
    }

    /// Reads a duration back the way a person would say it.
    ///
    /// Truncating divisions made this lie: a 90-second timer was confirmed as
    /// "a minute". The confirmation is the only check the user gets that they
    /// were heard correctly, so it has to state what was actually set.
    static func spoken(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) seconds" }

        if seconds < 3600 {
            let minutes = seconds / 60
            guard seconds % 60 != 0 else {
                return minutes == 1 ? "a minute" : "\(minutes) minutes"
            }
            // "90 seconds" is how people say it; "1 minute 30 seconds" isn't.
            if minutes == 1 { return "\(seconds) seconds" }
            return "\(minutes) minutes \(seconds % 60) seconds"
        }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let hoursPhrase = hours == 1 ? "an hour" : "\(hours) hours"
        guard minutes > 0 else { return hoursPhrase }
        return "\(hoursPhrase) and \(minutes) minutes"
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
            await context.timers.schedule(seconds: seconds)
            return "Timer set for \(DurationParser.spoken(seconds))."
        }
    )

    public static let cancelTimer = LocalCommand(
        id: "system.timer.cancel",
        examples: ["cancel the timer", "cancel my timers"],
        matches: exact([
            "cancel the timer", "cancel timer", "cancel my timer",
            "cancel my timers", "cancel the timers", "cancel all timers",
            "stop the timer", "stop the timers",
        ]),
        perform: { _, context in
            let cancelled = await context.timers.cancelAll()
            guard !cancelled.isEmpty else { return "There's no timer running." }
            guard cancelled.count > 1 else {
                return "Cancelled your \(DurationParser.spoken(cancelled[0].duration)) timer."
            }
            return "Cancelled \(cancelled.count) timers."
        }
    )

    public static let listTimers = LocalCommand(
        id: "system.timer.list",
        examples: ["what timers do I have", "how long is left"],
        matches: exact([
            "what timers do i have", "what timers are running", "my timers",
            "how long is left", "how much time is left", "is there a timer running",
        ]),
        perform: { _, context in
            let pending = await context.timers.timers()
            guard let next = pending.first else { return "No timers running." }
            let remaining = Int(next.dueAt.timeIntervalSinceNow.rounded())
            let phrase = "\(DurationParser.spoken(max(1, remaining))) left"
            guard pending.count > 1 else { return phrase.prefix(1).uppercased() + phrase.dropFirst() }
            return "\(pending.count) timers, the next with \(phrase)."
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
