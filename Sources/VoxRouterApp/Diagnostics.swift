import AVFoundation
import AppKit
import Foundation
import VoxRouterKit

/// Prints why the app isn't working, without starting it.
///
/// Startup can block indefinitely inside `AVCaptureDevice.requestAccess` when
/// the microphone prompt is never answered, and from the outside that is
/// indistinguishable from a crash — no window, no output, no log. This reports
/// each precondition separately so the actual blocker is obvious.
enum Diagnostics {
    static func run() {
        var out = ""
        func line(_ text: String) { out += text + "\n" }

        line("VoxRouter diagnostics")
        line("")

        let bundleID = Bundle.main.bundleIdentifier ?? "(none — not running from a bundle)"
        line("  bundle id        \(bundleID)")
        line("  bundle path      \(Bundle.main.bundlePath)")
        line("  macOS            \(ProcessInfo.processInfo.operatingSystemVersionString)")
        line("")

        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let micText: String
        switch mic {
        case .authorized: micText = "authorized"
        case .notDetermined: micText = "NOT DETERMINED — will prompt on launch, and startup blocks until answered"
        case .denied: micText = "DENIED — grant it in System Settings ▸ Privacy & Security ▸ Microphone"
        case .restricted: micText = "restricted by policy"
        @unknown default: micText = "unknown"
        }
        line("  microphone       \(micText)")

        let inputs = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        line("  input devices    \(inputs.isEmpty ? "NONE FOUND" : inputs.map(\.localizedName).joined(separator: ", "))")
        line("")

        // Every line marked pass/fail rather than reported as neutral fact: on
        // a fresh install the interesting question is "what's missing", and a
        // bare list of values answers it only if you already know what correct
        // looks like.
        let config = Config.load()

        let project = config.activeProject
        if config.needsProjectSetup {
            line("  project          NONE — choose one from the menu bar before use")
        } else if project.exists {
            let vcs = project.isGitRepository ? "" : "  (not a git repo — codex will refuse it)"
            line("  project          \(project.name) — \(project.path)\(vcs)")
        } else {
            line("  project          \(project.name) — MISSING at \(project.path)")
        }

        let engines = EngineRegistry.all(config: config)
        let installed = engines.filter(\.isInstalled)
        if installed.isEmpty {
            line("  engines          NONE INSTALLED — nothing can run")
            for engine in engines {
                line("                   \(engine.displayName): \(engine.installHint)")
            }
        } else {
            for engine in engines {
                let label = engine.id.padding(toLength: 10, withPad: " ", startingAt: 0)
                line("  engine \(label)\(engine.binaryPath?.path ?? "not installed")")
            }
        }

        line("  openusage        \(openUsageStatus(config))")
        line("")

        if #available(macOS 26, *) {
            line("  speech API       available")
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var status = "(timed out)"
            Task {
                if let locale = await AppleTranscriber.resolvedLocale(for: Locale.current) {
                    status = "\(locale.identifier) — \(await AppleTranscriber.modelStatus(for: locale))"
                } else {
                    status = "no model supports \(Locale.current.identifier)"
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 10)
            line("  speech model     \(status)")
        } else {
            line("  speech API       UNAVAILABLE — needs macOS 26+")
        }

        line("")
        line("  status item      created at launch, before any async work")
        line("                   (if you see no menu bar icon, the app isn't running)")

        FileHandle.standardOutput.write(Data(out.utf8))
    }

    /// Whether the quota dashboard is actually answering. Without it routing
    /// still works, but falls back to preference order — worth knowing.
    private static func openUsageStatus(_ config: Config) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = "unreachable — routing falls back to preference order"
        Task {
            defer { semaphore.signal() }
            let client = QuotaClient(baseURL: config.openUsageBaseURL)
            if let snapshot = try? await client.fetchAll() {
                let names = snapshot.providers.map { $0.displayName ?? $0.providerId }
                result = names.isEmpty
                    ? "reachable, but no providers enabled in OpenUsage"
                    : "reachable — \(names.joined(separator: ", "))"
            }
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return result
    }

    /// Downloads the on-device speech model under *this bundle's* identity.
    static func installModel() {
        guard #available(macOS 26, *) else {
            FileHandle.standardError.write(Data("Needs macOS 26 or later.\n".utf8))
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            guard let locale = await AppleTranscriber.resolvedLocale(for: Locale.current) else {
                FileHandle.standardError.write(Data("No supported locale.\n".utf8))
                return
            }
            let status = await AppleTranscriber.modelStatus(for: locale)
            guard status != "installed" else {
                print("Already installed for \(locale.identifier).")
                return
            }
            print("Installing \(locale.identifier) for \(Bundle.main.bundleIdentifier ?? "?")…")
            do {
                try await AppleTranscriber.installModel(for: locale) { fraction in
                    FileHandle.standardOutput.write(
                        Data(String(format: "\r  %.0f%%", fraction * 100).utf8)
                    )
                }
                print("\r  done.     ")
            } catch {
                FileHandle.standardError.write(
                    Data("\nfailed: \(error.localizedDescription)\n".utf8)
                )
            }
        }
        // Model downloads can be large; allow generous time.
        _ = semaphore.wait(timeout: .now() + 900)
    }
}
