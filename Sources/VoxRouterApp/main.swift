import AppKit
import SwiftUI

/// AppKit lifecycle rather than the SwiftUI `App` protocol.
///
/// Two reasons: `@main` plus `MenuBarExtra` pulls in SwiftUI macros that ship
/// only with full Xcode (not Command Line Tools), and the status item needs
/// direct AppKit access to animate its button while listening. Top-level code
/// in `main.swift` avoids `@main` entirely.
// `--diagnose` prints startup preconditions and exits, without touching the
// permission prompt. Added because a hang inside `AVCaptureDevice.requestAccess`
// looks identical to a crash from the outside: no window, no log, no output.
if CommandLine.arguments.contains("--diagnose") {
    Diagnostics.run()
    exit(0)
}

// Speech model assets are scoped to the app's identity, so the CLI's copy does
// not count. This installs the app's own without needing the UI.
if CommandLine.arguments.contains("--install-model") {
    Diagnostics.installModel()
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// .accessory: menu bar only, no Dock icon, no menu bar menus of its own — and
// it still gets the event loop Carbon hotkeys require.
application.setActivationPolicy(.accessory)
application.run()
