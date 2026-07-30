import Foundation

public struct Config: Codable, Sendable {
    public var openUsageBaseURL: URL
    public var quotaRefreshInterval: TimeInterval
    public var routing: RoutingPolicy
    /// Extra CLI args appended to each engine invocation, keyed by engine id.
    public var engineArgs: [String: [String]]
    /// Model override per engine id. Empty/absent follows the CLI's own config.
    public var engineModels: [String: String]
    /// Extra model names to offer in the app's picker, per engine id. Needed for
    /// Codex, whose valid model names can't be enumerated from the CLI.
    public var engineModelChoices: [String: [String]]
    /// Where dispatched work runs.
    public var workingDirectory: String
    /// Idle gap after which a follow-up starts a new conversation rather than
    /// continuing the last one. A long silence means you've moved on, and
    /// dragging an old task into a new request is worse than starting clean.
    public var conversationTimeout: TimeInterval
    public var wakePhrases: [String]
    /// `say` voice name; nil uses the system default.
    public var voice: String?
    /// How much it says out loud. "minimal" (default) speaks only the result,
    /// failures, and being out of quota; "detailed" also announces which engine
    /// picked the task up and when it switches.
    public var speechVerbosity: SpokenNarration.Verbosity
    public var speechRate: Int?

    public static let `default` = Config(
        openUsageBaseURL: URL(string: "http://127.0.0.1:6736")!,
        quotaRefreshInterval: 20,
        routing: RoutingPolicy(),
        engineArgs: [:],
        engineModels: [:],
        engineModelChoices: [:],
        workingDirectory: NSHomeDirectory() + "/code",
        conversationTimeout: 30 * 60,
        // Deliberately no "hey" prefix: "Hey Siri" is enabled by default on
        // macOS, and a phrase sharing that opening risks cross-triggering
        // whichever assistant hears it first. Two or three distinct syllables
        // also match far more reliably than a single short word.
        wakePhrases: ["vox router", "okay vox"],
        voice: nil,
        speechVerbosity: .minimal,
        speechRate: nil
    )

    public static var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/voxrouter/config.json")
    }

    public static var stateDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/state/voxrouter")
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
