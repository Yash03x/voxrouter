import Foundation
import Testing
@testable import VoxRouterKit

@Suite("Spoken project matching")
struct ProjectMatchingTests {
    private let torrent = Project(name: "torrent-client", path: "/tmp/torrent-client")
    private let vox = Project(name: "voxrouter", path: "/tmp/voxrouter")

    /// Speech gives you "torrent client"; the directory is `torrent-client`.
    @Test("Hyphenated names match spoken words")
    func matchesHyphenated() {
        #expect(torrent.matches(spoken: "torrent client"))
        #expect(torrent.matches(spoken: "Torrent Client"))
        #expect(torrent.matches(spoken: "torrentclient"))
    }

    @Test("Partial names match")
    func matchesPartial() {
        #expect(vox.matches(spoken: "vox"))
        #expect(vox.matches(spoken: "voxrouter please"))
    }

    @Test("Unrelated names don't match")
    func rejectsUnrelated() {
        #expect(!vox.matches(spoken: "torrent client"))
        #expect(!torrent.matches(spoken: "letterboxd"))
        #expect(!vox.matches(spoken: ""))
    }

    @Test("The directory name is matched even when the label differs")
    func matchesPathComponent() {
        let project = Project(name: "My Side Project", path: "/tmp/gully")
        #expect(project.matches(spoken: "gully"))
        #expect(project.matches(spoken: "my side project"))
    }
}

@Suite("Spoken project commands")
struct ProjectCommandTests {
    @Test("Switching phrases are recognised")
    func recognisesSwitchPhrases() {
        #expect(ProjectCommand.parse("switch to voxrouter") == "voxrouter")
        #expect(ProjectCommand.parse("work in torrent client") == "torrent client")
        #expect(ProjectCommand.parse("go to gully") == "gully")
        #expect(ProjectCommand.parse("Switch to Voxrouter.") == "voxrouter")
    }

    @Test("Anywhere mode has its own phrases")
    func recognisesAnywhere() {
        #expect(ProjectCommand.parse("work anywhere") == "anywhere")
        #expect(ProjectCommand.parse("unrestricted mode") == "anywhere")
    }

    /// A project name inside a request is part of the task, not a command to
    /// change directory — otherwise ordinary work would silently move scope.
    @Test("A task that merely mentions a project is not a switch")
    func doesNotSwitchOnTasks() {
        #expect(ProjectCommand.parse("add tests to voxrouter") == nil)
        #expect(ProjectCommand.parse("run the tests") == nil)
        #expect(ProjectCommand.parse("switch to the other branch and rebase onto main") == nil)
        #expect(ProjectCommand.parse("switch to") == nil)
    }
}

@Suite("Project configuration")
struct ProjectConfigTests {
    /// Must be a real directory: a synthesised project pointing at nothing is
    /// exactly the fresh-install failure this seeding is meant to avoid.
    @Test("An upgrade seeds a project from an existing workingDirectory")
    func seedsFromWorkingDirectory() throws {
        let legacy = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacy) }

        var config = Config.default
        config.workingDirectory = legacy.path
        config.projects = []

        let projects = config.resolvedProjects
        #expect(projects.first?.path == legacy.path)
        #expect(projects.first?.name == legacy.lastPathComponent)
        #expect(config.effectiveWorkingDirectory == legacy.path)
    }

    /// The default working directory is `~/code`, which exists on the author's
    /// Mac and few others. Synthesising a project for a directory that isn't
    /// there gives a fresh install something that looks configured and fails on
    /// first use.
    @Test("A missing default directory yields no project, not a broken one")
    func missingDefaultYieldsNoProject() {
        var config = Config.default
        config.projects = []
        config.workingDirectory = "/tmp/definitely-not-here-\(UUID().uuidString)"

        #expect(config.needsProjectSetup, "a fresh install should ask, not pretend")
        let onlyAnywhere = config.resolvedProjects.allSatisfy(\.isAnywhere)
        #expect(onlyAnywhere)
    }

    @Test("An existing default directory is adopted as the first project")
    func existingDefaultBecomesProject() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxrouter-default-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var config = Config.default
        config.projects = []
        config.workingDirectory = directory.path

        let needsSetup = config.needsProjectSetup
        #expect(!needsSetup)
        #expect(config.effectiveWorkingDirectory == directory.path)
    }

    /// Falling back to the whole machine because setup wasn't finished is not a
    /// reasonable default, so Anywhere alone still counts as unconfigured.
    @Test("Anywhere alone does not count as being set up")
    func anywhereIsNotSetup() {
        var config = Config.default
        config.projects = [.anywhere()]
        config.workingDirectory = "/tmp/nope-\(UUID().uuidString)"
        #expect(config.needsProjectSetup)
    }

    @Test("A real project means setup is complete")
    func realProjectMeansConfigured() {
        var config = Config.default
        config.projects = [Project(id: "a", name: "alpha", path: "/tmp/alpha")]
        #expect(!config.needsProjectSetup)
    }

    /// Whether a task can reach the whole Mac should never be implicit.
    @Test("Anywhere is always offered, as a visible entry")
    func anywhereAlwaysPresent() {
        let config = Config.default
        #expect(config.resolvedProjects.contains { $0.isAnywhere })
        #expect(config.resolvedProjects.last?.name == "Anywhere")
    }

    @Test("The active project decides where tasks run")
    func activeProjectDrivesWorkingDirectory() {
        var config = Config.default
        let a = Project(id: "a", name: "alpha", path: "/tmp/alpha")
        let b = Project(id: "b", name: "beta", path: "/tmp/beta")
        config.projects = [a, b]

        config.activeProjectID = "b"
        #expect(config.effectiveWorkingDirectory == "/tmp/beta")

        config.activeProjectID = "a"
        #expect(config.effectiveWorkingDirectory == "/tmp/alpha")
    }

    @Test("An unknown active id falls back rather than breaking dispatch")
    func unknownActiveIdFallsBack() {
        var config = Config.default
        config.projects = [Project(id: "a", name: "alpha", path: "/tmp/alpha")]
        config.activeProjectID = "does-not-exist"
        #expect(config.effectiveWorkingDirectory == "/tmp/alpha")
    }

    @Test("Anywhere starts at home")
    func anywherePointsHome() {
        var config = Config.default
        config.activeProjectID = "anywhere"
        #expect(config.effectiveWorkingDirectory == NSHomeDirectory())
        #expect(config.activeProject.isAnywhere)
    }

    /// Regression for a silent data-loss bug. With synthesised Codable, adding
    /// one property made every existing config fail to decode, and `load()`
    /// then fell back to defaults — discarding the user's projects and engine
    /// flags with nothing but a log line. A config from an older version must
    /// still load, keeping every field it does have.
    @Test("A config missing newer keys still loads, keeping what it has")
    func toleratesMissingKeys() throws {
        let old = """
        {
          "openUsageBaseURL": "http://127.0.0.1:6736",
          "quotaRefreshInterval": 20,
          "routing": {
            "preferenceOrder": ["codex", "claude"],
            "highWater": 80, "lowWater": 60, "minimumSwitchGain": 10,
            "hardCeiling": 95, "blindCooldown": 900
          },
          "engineArgs": { "claude": ["--dangerously-skip-permissions"] },
          "workingDirectory": "/tmp/legacy",
          "wakePhrases": ["hello"],
          "conversationTimeout": 600,
          "speechVerbosity": "minimal"
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(old.utf8))

        // Present keys survive.
        #expect(config.engineArgs["claude"] == ["--dangerously-skip-permissions"])
        #expect(config.workingDirectory == "/tmp/legacy")
        #expect(config.routing.preferenceOrder == ["codex", "claude"])
        #expect(config.conversationTimeout == 600)
        // Absent keys take defaults instead of failing the whole decode.
        #expect(config.engineEfforts.isEmpty)
        #expect(config.projects.isEmpty)
        #expect(config.activeProjectID == nil)
    }

    @Test("An empty object decodes to defaults rather than throwing")
    func emptyObjectDecodes() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(config.quotaRefreshInterval == Config.default.quotaRefreshInterval)
        #expect(config.routing.highWater == Config.default.routing.highWater)
    }

    @Test("Projects survive a config round trip")
    func roundTripsThroughJSON() throws {
        var config = Config.default
        config.projects = [Project(id: "x", name: "alpha", path: "/tmp/alpha")]
        config.activeProjectID = "x"

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        #expect(decoded.activeProject.name == "alpha")
        #expect(decoded.effectiveWorkingDirectory == "/tmp/alpha")
    }
}
