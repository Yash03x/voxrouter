import Carbon.HIToolbox
import Foundation

public struct HotkeyCombo: Sendable, Equatable, Codable, Identifiable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public let label: String

    public var id: String { label }

    public init(keyCode: UInt32, carbonModifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.label = label
    }

    /// Alternatives to fall back to when the preferred chord is taken.
    ///
    /// `RegisterEventHotKey` fails outright if another app already owns a
    /// chord, and plenty do — Alfred, Raycast, input-source switching. The
    /// default was chosen because it happened to be free on one Mac, which is
    /// not a basis for shipping. These are tried in order.
    public static let presets: [HotkeyCombo] = [
        controlOptionSpace,
        controlOptionV,
        optionSpace,
        controlOptionD,
        controlShiftSpace,
    ]

    public static let optionSpace = HotkeyCombo(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(optionKey),
        label: "⌥Space"
    )

    public static let controlOptionD = HotkeyCombo(
        keyCode: UInt32(kVK_ANSI_D),
        carbonModifiers: UInt32(controlKey | optionKey),
        label: "⌃⌥D"
    )

    public static let controlShiftSpace = HotkeyCombo(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(controlKey | shiftKey),
        label: "⌃⇧Space"
    )

    /// Default push-to-talk chord.
    ///
    /// Chosen over the keyboard's Siri/mic key deliberately: that key is a
    /// hardware media key (NX_KEYTYPE_*), so capturing it needs a CGEventTap
    /// with Input Monitoring consent *and* still races macOS's own handler.
    /// A plain key+modifier chord goes through `RegisterEventHotKey`, which
    /// needs no permissions and cannot be shadowed.
    public static let controlOptionSpace = HotkeyCombo(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(controlKey | optionKey),
        label: "⌃⌥Space"
    )

    public static let controlOptionV = HotkeyCombo(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(controlKey | optionKey),
        label: "⌃⌥V"
    )
}

public enum HotkeyError: Error, LocalizedError {
    case handlerInstallFailed(OSStatus)
    case alreadyRegistered(String)
    case registrationFailed(OSStatus, String)

    public var errorDescription: String? {
        switch self {
        case .handlerInstallFailed(let status):
            return "Could not install the hotkey event handler (OSStatus \(status))."
        case .alreadyRegistered(let label):
            return "\(label) is already claimed by another application. Pick a different chord."
        case .registrationFailed(let status, let label):
            return "Could not register \(label) (OSStatus \(status))."
        }
    }
}

/// Global press-and-release hotkey via Carbon's `RegisterEventHotKey`.
///
/// Why Carbon rather than `NSEvent.addGlobalMonitorForEvents`: the NSEvent route
/// requires Accessibility/Input Monitoring consent, which is a bad ask for a
/// tool whose whole job is to be unobtrusive. `RegisterEventHotKey` needs no
/// permission at all, and — critically for push-to-talk — reports both
/// `kEventHotKeyPressed` and `kEventHotKeyReleased`, so hold-to-talk is possible
/// rather than just toggle-on-tap.
///
/// Requires a running Cocoa/Carbon event loop; see `voxrouter ptt`, which runs
/// as an accessory app so events are actually dispatched.
public final class HotkeyMonitor: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case pressed
        case released
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let lock = NSLock()
    private var handler: (@Sendable (Event) -> Void)?

    public init() {}

    deinit { unregister() }

    public func start(
        combo: HotkeyCombo,
        onEvent: @escaping @Sendable (Event) -> Void
    ) throws {
        lock.lock()
        handler = onEvent
        lock.unlock()

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        // The C callback can't close over Swift state, so `self` travels as
        // userData. Unretained: the monitor outlives the handler by contract,
        // and retaining here would leak it.
        let context = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData)
                    .takeUnretainedValue()
                let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                monitor.deliver(isPress ? .pressed : .released)
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            context,
            &handlerRef
        )
        guard installStatus == noErr else {
            throw HotkeyError.handlerInstallFailed(installStatus)
        }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            identifier,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus == OSStatus(eventHotKeyExistsErr) {
            throw HotkeyError.alreadyRegistered(combo.label)
        }
        guard registerStatus == noErr else {
            throw HotkeyError.registrationFailed(registerStatus, combo.label)
        }

        Log.audio.notice("push-to-talk bound to \(combo.label, privacy: .public)")
    }

    /// Registers `preferred`, falling back through the presets when it's taken.
    ///
    /// Returns the chord that actually bound, or throws if every candidate is
    /// spoken for. A hard failure here means no way to talk to the app at all,
    /// so trying alternatives beats reporting "⌃⌥Space is taken" to someone who
    /// has no means of changing it.
    @discardableResult
    public func startWithFallback(
        preferred: HotkeyCombo,
        onEvent: @escaping @Sendable (Event) -> Void
    ) throws -> HotkeyCombo {
        var candidates = [preferred]
        candidates += HotkeyCombo.presets.filter { $0 != preferred }

        var lastError: Error?
        for candidate in candidates {
            do {
                try start(combo: candidate, onEvent: onEvent)
                if candidate != preferred {
                    Log.audio.notice(
                        "\(preferred.label, privacy: .public) was taken; using \(candidate.label, privacy: .public)"
                    )
                }
                return candidate
            } catch {
                lastError = error
                unregister()
            }
        }
        throw lastError ?? HotkeyError.alreadyRegistered(preferred.label)
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func deliver(_ event: Event) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(event)
    }

    /// Four-char code 'VXRT'.
    private static let signature: OSType = 0x5658_5254
}
