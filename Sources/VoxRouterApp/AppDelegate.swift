import AppKit
import SwiftUI
import VoxRouterKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var historyWindow: NSWindow?
    private var pulseTimer: Timer?
    private var pulseUp = false
    // AppModel is @MainActor-isolated, so the delegate must be too.
    private let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: "VoxRouter"
        )
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let contentSize = NSSize(width: 340, height: 460)
        let content = MenuContent(
            model: model,
            openHistory: { [weak self] in self?.showHistory() },
            quit: { NSApplication.shared.terminate(nil) }
        )
        .frame(
            width: contentSize.width,
            height: contentSize.height,
            alignment: .topLeading
        )
        .background(Color(nsColor: .windowBackgroundColor))
        let hostingController = NSHostingController(rootView: content)
        hostingController.view.frame = NSRect(origin: .zero, size: contentSize)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = contentSize
        popover.contentViewController = hostingController
        self.popover = popover

        // The status item is AppKit, so it can be animated directly rather than
        // depending on a SwiftUI view being on screen — the icon must pulse
        // while listening even with the popover closed.
        model.onActivityChange = { [weak self] animating in
            self?.setPulsing(animating)
        }

        Log.audio.notice("app: didFinishLaunching, status item created")
        Task { @MainActor in
            await model.start()
            self.updateIcon()
            Log.audio.notice("app: startup task returned")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pulseTimer?.invalidate()
        Task { @MainActor in model.stop() }
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            Task { @MainActor in await model.refresh() }
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showHistory() {
        popover?.performClose(nil)

        if let historyWindow {
            historyWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoxRouter — \(model.workingDirectoryName)"
        window.contentViewController = NSHostingController(rootView: HistoryWindow(model: model))
        window.center()
        window.isReleasedWhenClosed = false
        historyWindow = window

        window.makeKeyAndOrderFront(nil)
        // .accessory apps don't come forward on their own, so a window opened
        // from the menu bar would otherwise appear behind everything.
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Icon animation

    private func updateIcon() {
        statusItem?.button?.image = NSImage(
            systemSymbolName: model.state.symbol,
            accessibilityDescription: model.state.label
        )
        statusItem?.button?.image?.isTemplate = true
        statusItem?.button?.toolTip = model.state.label
    }

    /// A slow alpha pulse: legible at a glance, and calm enough to sit in the
    /// menu bar without demanding attention.
    private func setPulsing(_ animating: Bool) {
        pulseTimer?.invalidate()
        pulseTimer = nil
        updateIcon()

        guard animating else {
            statusItem?.button?.alphaValue = 1
            return
        }

        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            // The timer is scheduled on the main run loop, so it always fires on
            // the main thread — the compiler just can't prove it through the
            // @Sendable closure. `assumeIsolated` states that invariant without
            // the hop a Task would add.
            MainActor.assumeIsolated {
                guard let self, let button = self.statusItem?.button else { return }
                self.pulseUp.toggle()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.5
                    button.animator().alphaValue = self.pulseUp ? 0.35 : 1.0
                }
            }
        }
        // Keep animating while menus are tracking, or the pulse freezes the
        // moment the user opens something.
        RunLoop.main.add(pulseTimer!, forMode: .common)
    }
}
