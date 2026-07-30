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

        let config = Config.load()
        line("  working dir      \(config.workingDirectory)")
        line("  openusage        \(config.openUsageBaseURL.absoluteString)")
        for engine in EngineRegistry.all(config: config) {
            line("  engine \(engine.id.padding(toLength: 10, withPad: " ", startingAt: 0))\(engine.binaryPath?.path ?? "NOT INSTALLED")")
        }
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
