import Foundation

public struct Config: Codable, Sendable {
    public var openUsageBaseURL: URL
    public var quotaRefreshInterval: TimeInterval
    public var routing: RoutingPolicy
    /// Extra CLI args appended to each engine invocation, keyed by engine id.
    public var engineArgs: [String: [String]]
    /// Model override per engine id. Empty/absent follows the CLI's own config.
    public var engineModels: [String: String]
    /// Reasoning-effort override per engine id.
    public var engineEfforts: [String: String]
    /// Extra model names to offer in the app's picker, per engine id. Needed for
    /// Codex, whose valid model names can't be enumerated from the CLI.
    public var engineModelChoices: [String: [String]]
    /// Fallback working directory, used when no project is registered.
    /// Prefer `projects` + `activeProjectID`; this remains for compatibility
    /// and seeds the first project on upgrade.
    public var workingDirectory: String
    /// Registered projects, switchable by voice or from the menu bar.
    public var projects: [Project]
    public var activeProjectID: String?
    /// Idle gap after which a follow-up starts a new conversation rather than
    /// continuing the last one. A long silence means you've moved on, and
    /// dragging an old task into a new request is worse than starting clean.
    public var conversationTimeout: TimeInterval
    /// Push-to-talk chord. Nil uses the default, falling back automatically if
    /// another app already owns it.
    public var hotkey: HotkeyCombo?
    public var wakePhrases: [String]
    /// `say` voice name; nil uses the system default.
    public var voice: String?
    /// How much it says out loud. "minimal" (default) speaks only the result,
    /// failures, and being out of quota; "detailed" also announces which engine
    /// picked the task up and when it switches.
    public var speechVerbosity: SpokenNarration.Verbosity
    public var speechRate: Int?
    /// Whether quick general questions may be answered by the on-device model
    /// before an engine is considered. Safe to leave on: the tier's gate sends
    /// every ambiguity to the engines, so turning this off only buys slower
    /// answers, not safer ones. Off exists for machines where the model's
    /// availability check itself misbehaves.
    public var fastAnswers: Bool
    /// Which model the fast tier's Ollama backend asks for. The default is
    /// the only candidate that measured clean — qwen2.5:7b went 12/12 on the
    /// safety set (0 unsafe, 0 over-escalation, 0 wrong) at 0.81 s warm
    /// median, where llama3.2:3b answered unsafely, gemma3:4b fabricated
    /// live data, and qwen3:4b was clean but twice as slow. A knob because
    /// it's the user's disk and RAM (~4.7 GB resident) — but a smaller model
    /// here trades directly against the "never lose work" guarantee.
    public var ollamaModel: String
    /// Where the Ollama server listens. A knob for non-default ports or a
    /// server elsewhere on the LAN; the localhost default keeps questions on
    /// the machine, which is the tier's promise.
    public var ollamaBaseURL: URL

    /// Explicit, because declaring `init(from:)` suppresses the synthesised
    /// memberwise initialiser.
    public init(
        openUsageBaseURL: URL,
        quotaRefreshInterval: TimeInterval,
        routing: RoutingPolicy,
        engineArgs: [String: [String]],
        engineModels: [String: String],
        engineEfforts: [String: String],
        engineModelChoices: [String: [String]],
        workingDirectory: String,
        projects: [Project],
        activeProjectID: String?,
        conversationTimeout: TimeInterval,
        hotkey: HotkeyCombo?,
        wakePhrases: [String],
        voice: String?,
        speechVerbosity: SpokenNarration.Verbosity,
        speechRate: Int?,
        fastAnswers: Bool,
        ollamaModel: String,
        ollamaBaseURL: URL
    ) {
        self.openUsageBaseURL = openUsageBaseURL
        self.quotaRefreshInterval = quotaRefreshInterval
        self.routing = routing
        self.engineArgs = engineArgs
        self.engineModels = engineModels
        self.engineEfforts = engineEfforts
        self.engineModelChoices = engineModelChoices
        self.workingDirectory = workingDirectory
        self.projects = projects
        self.activeProjectID = activeProjectID
        self.conversationTimeout = conversationTimeout
        self.hotkey = hotkey
        self.wakePhrases = wakePhrases
        self.voice = voice
        self.speechVerbosity = speechVerbosity
        self.speechRate = speechRate
        self.fastAnswers = fastAnswers
        self.ollamaModel = ollamaModel
        self.ollamaBaseURL = ollamaBaseURL
    }

    public static let `default` = Config(
        openUsageBaseURL: URL(string: "http://127.0.0.1:6736")!,
        quotaRefreshInterval: 20,
        routing: RoutingPolicy(),
        engineArgs: [:],
        engineModels: [:],
        engineEfforts: [:],
        engineModelChoices: [:],
        // Empty on purpose. A built-in default is right only by coincidence:
        // the fresh-install test picked up an existing ~/code, which is a
        // *folder of projects* and not a git repo, so codex would have refused
        // it. Asking once beats guessing wrong quietly. A `workingDirectory`
        // read from an existing config file is still adopted — that's the
        // upgrade path, where the value was deliberate.
        workingDirectory: "",
        projects: [],
        activeProjectID: nil,
        conversationTimeout: 30 * 60,
        hotkey: nil,
        // Deliberately no "hey" prefix: "Hey Siri" is enabled by default on
        // macOS, and a phrase sharing that opening risks cross-triggering
        // whichever assistant hears it first. Two or three distinct syllables
        // also match far more reliably than a single short word.
        wakePhrases: ["vox router", "okay vox"],
        voice: nil,
        speechVerbosity: .minimal,
        speechRate: nil,
        fastAnswers: true,
        ollamaModel: "qwen2.5:7b",
        ollamaBaseURL: URL(string: "http://127.0.0.1:11434")!
    )

    public static var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/voxrouter/config.json")
    }

    public static var stateDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/state/voxrouter")
    }

    /// Field-by-field decoding, so a config written by an older version still
    /// loads.
    ///
    /// With synthesised `Codable`, adding one property makes every existing
    /// config file fail to decode — and `load()` then silently falls back to
    /// defaults, quietly discarding the user's projects, engine flags and
    /// everything else. That happened: adding `engineEfforts` disabled a
    /// carefully-configured setup with nothing but a log line to show for it.
    /// Every key is optional here, so a missing one takes its default and the
    /// rest of the file survives.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Config.default

        // `try?` flattens the optional, so a missing key and a malformed value
        // both land here as nil — which is the behaviour we want either way.
        func value<T: Decodable>(_ key: CodingKeys, _ defaultValue: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? defaultValue
        }

        openUsageBaseURL = value(.openUsageBaseURL, fallback.openUsageBaseURL)
        quotaRefreshInterval = value(.quotaRefreshInterval, fallback.quotaRefreshInterval)
        routing = value(.routing, fallback.routing)
        engineArgs = value(.engineArgs, fallback.engineArgs)
        engineModels = value(.engineModels, fallback.engineModels)
        engineEfforts = value(.engineEfforts, fallback.engineEfforts)
        engineModelChoices = value(.engineModelChoices, fallback.engineModelChoices)
        workingDirectory = value(.workingDirectory, fallback.workingDirectory)
        projects = value(.projects, fallback.projects)
        activeProjectID = try? container.decodeIfPresent(String.self, forKey: .activeProjectID)
        conversationTimeout = value(.conversationTimeout, fallback.conversationTimeout)
        hotkey = try? container.decodeIfPresent(HotkeyCombo.self, forKey: .hotkey)
        wakePhrases = value(.wakePhrases, fallback.wakePhrases)
        voice = try? container.decodeIfPresent(String.self, forKey: .voice)
        speechVerbosity = value(.speechVerbosity, fallback.speechVerbosity)
        speechRate = try? container.decodeIfPresent(Int.self, forKey: .speechRate)
        fastAnswers = value(.fastAnswers, fallback.fastAnswers)
        ollamaModel = value(.ollamaModel, fallback.ollamaModel)
        ollamaBaseURL = value(.ollamaBaseURL, fallback.ollamaBaseURL)
    }

    /// Loads config, falling back to defaults. A malformed config must not stop
    /// an always-on daemon from starting — it logs and uses defaults.
    public static func load() -> Config {
        var config = Config.default
        if let data = try? Data(contentsOf: configURL) {
            do {
                config = try JSONDecoder().decode(Config.self, from: data)
            } catch {
                Log.quota.error(
                    "config unreadable, using defaults: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        // Env override, so a single run can be pointed elsewhere without
        // editing the file the daemon is also reading.
        if let cwd = ProcessInfo.processInfo.environment["VOXROUTER_CWD"], !cwd.isEmpty {
            config.workingDirectory = cwd
        }
        return config
    }

    // MARK: - Projects

    /// Registered projects, always including the "Anywhere" scope, and seeded
    /// from `workingDirectory` on first run so an upgrade doesn't start empty.
    public var resolvedProjects: [Project] {
        var list = projects
        if list.filter({ !$0.isAnywhere }).isEmpty {
            // Only if it actually exists. The default is `~/code`, which is
            // present on the author's Mac and on few others — synthesising a
            // project for a missing directory gives a fresh install something
            // that looks configured and fails on first use.
            if !workingDirectory.isEmpty {
                let url = URL(fileURLWithPath: workingDirectory)
                let candidate = Project(
                    id: "default", name: url.lastPathComponent, path: workingDirectory
                )
                if candidate.exists { list.insert(candidate, at: 0) }
            }
        }
        if !list.contains(where: { $0.isAnywhere }) {
            list.append(.anywhere())
        }
        return list
    }

    /// True when there's nowhere real to run a task yet — a fresh install with
    /// no project chosen. "Anywhere" doesn't count: falling back to the whole
    /// machine because setup wasn't finished is not a reasonable default.
    public var needsProjectSetup: Bool {
        resolvedProjects.allSatisfy(\.isAnywhere)
    }

    public var activeProject: Project {
        let list = resolvedProjects
        if let activeProjectID, let match = list.first(where: { $0.id == activeProjectID }) {
            return match
        }
        return list.first ?? Project(name: "code", path: workingDirectory)
    }

    /// Where the next task actually runs.
    public var effectiveWorkingDirectory: String { activeProject.path }

    /// The chord to try first.
    public var preferredHotkey: HotkeyCombo { hotkey ?? .controlOptionSpace }

    public func write() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: Self.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.configURL, options: .atomic)
    }
}
