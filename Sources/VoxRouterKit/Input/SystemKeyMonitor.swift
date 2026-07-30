import AppKit
import Foundation

/// Captures hardware keys that `RegisterEventHotKey` can't see — the mic /
/// dictation key, media keys, and bare modifiers.
///
/// These arrive as `NSSystemDefined` events rather than ordinary key presses, so
/// they need a `CGEventTap`. That has a real cost: the tap must be a
/// `.defaultTap` to *consume* the key (otherwise Siri or Dictation still fires
/// alongside us), and a consuming tap requires **Accessibility** permission.
/// The Carbon path used for chords needs no permission at all, which is why it
/// remains the default.
public final class SystemKeyMonitor: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case pressed(keyCode: Int32)
        case released(keyCode: Int32)
    }

    /// Sub-type 8 is `NX_SUBTYPE_AUX_CONTROL_BUTTONS`: the family that carries
    /// media and function keys.
    private static let auxControlSubtype: Int16 = 8

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()
    private var handler: (@Sendable (Event) -> Void)?
    /// Keys we consume. Empty means observe everything and consume nothing,
    /// which is what the diagnostic wants.
    private var captured: Set<Int32> = []

    public init() {}

    deinit { stop() }

    // MARK: - Permission

    /// Whether a consuming tap is allowed. Accessibility, not Input Monitoring:
    /// listening alone would leave Siri responding to the same press.
    public static var isPermitted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt if permission hasn't been decided.
    ///
    /// macOS only offers this once per app identity, and thereafter the user has
    /// to go to Settings themselves — so the caller should say where.
    @discardableResult
    public static func requestPermission() -> Bool {
        // The constant is a global `var` in the SDK and so isn't Sendable; its
        // value is fixed, so use the string directly.
        let options = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    // MARK: - Lifecycle

    public enum StartError: Error, LocalizedError {
        case permissionDenied
        case tapCreationFailed

        public var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return """
                Accessibility permission is needed to capture hardware keys like \
                the microphone key. Grant it in System Settings ▸ Privacy & \
                Security ▸ Accessibility, then restart VoxRouter.
                """
            case .tapCreationFailed:
                return "Could not create the event tap."
            }
        }
    }

    /// - Parameter capturing: key codes to swallow so the system doesn't also
    ///   act on them. Anything not listed is observed and passed through.
    public func start(
        capturing keyCodes: Set<Int32>,
        onEvent: @escaping @Sendable (Event) -> Void
    ) throws {
        guard Self.isPermitted else { throw StartError.permissionDenied }

        lock.lock()
        handler = onEvent
        captured = keyCodes
        lock.unlock()

        let mask = CGEventMask(1 << 14)  // NSSystemDefined
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<SystemKeyMonitor>.fromOpaque(userInfo)
                    .takeUnretainedValue()
                return monitor.process(type: type, event: event)
            },
            userInfo: context
        ) else {
            throw StartError.tapCreationFailed
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        // .commonModes so the tap keeps working while menus are tracking.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
    }

    // MARK: - Event handling

    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // A tap gets disabled if it ever takes too long; re-enable rather than
        // dying silently.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.auxControlSubtype else {
            return Unmanaged.passUnretained(event)
        }

        // data1 packs the key code and state into one integer.
        let data = nsEvent.data1
        let keyCode = Int32((data & 0xFFFF_0000) >> 16)
        let keyFlags = data & 0x0000_FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A

        lock.lock()
        let handler = self.handler
        let shouldConsume = captured.contains(keyCode)
        lock.unlock()

        handler?(isDown ? .pressed(keyCode: keyCode) : .released(keyCode: keyCode))

        // Returning nil swallows it, so Siri or Dictation doesn't also respond.
        return shouldConsume ? nil : Unmanaged.passUnretained(event)
    }
}
