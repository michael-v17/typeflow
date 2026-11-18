import AppKit
import Carbon.HIToolbox

/// Minimal global hotkey wrapper around Carbon's RegisterEventHotKey.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x54466C77 // 'TFlw'
    private let id: UInt32
    private let onFire: () -> Void

    static var registry: [UInt32: HotKey] = [:]
    static var nextId: UInt32 = 1

    init(keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) {
        self.onFire = onFire
        self.id = HotKey.nextId
        HotKey.nextId += 1
        HotKey.registry[id] = self
        register(keyCode: keyCode, modifiers: modifiers)
    }

    convenience init(_ shortcut: AnyAppShortcut, onFire: @escaping () -> Void) {
        self.init(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, onFire: onFire)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        HotKey.registry.removeValue(forKey: id)
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            if let hk = HotKey.registry[hkID.id] {
                hk.onFire()
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        let hkID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        // Usually another app already owns the combination.
        if status != noErr { fputs("TypeFlow: hotkey \(keyCode)/\(modifiers) not registered (\(status))\n", stderr) }
    }
}

/// The hotkeys that work on text selected (or copied) in any app. The app
/// registers them from this table and the menu bar menu lists them from it, so a
/// key and its label can't drift apart.
enum AnyAppShortcut: CaseIterable {
    case correct, quickFix, translate, readAloud

    var keyCode: UInt32 {
        switch self {
        case .correct: return UInt32(kVK_ANSI_E)
        case .quickFix: return UInt32(kVK_ANSI_K)
        case .translate: return UInt32(kVK_ANSI_T)
        case .readAloud: return UInt32(kVK_ANSI_R)
        }
    }

    var modifiers: UInt32 { UInt32(cmdKey | optionKey) }

    /// Its line in the menu bar menu.
    var menuLine: String {
        switch self {
        case .correct: return "   ⌥⌘E  correct in the composer"
        case .quickFix: return "   ⌥⌘K  quick fix in place"
        case .translate: return "   ⌥ ⌥ or ⌥⌘T  translate"
        case .readAloud: return "   ⌥⌘R  read aloud"
        }
    }
}

/// A modifier tapped twice on its own (⌥ ⌥) — a shortcut that needs one finger.
/// Watches every app's key events, which needs the Accessibility grant TypeFlow
/// already has. A key or another modifier in between, or a held press, resets it.
final class DoubleTap {
    private let modifier: NSEvent.ModifierFlags
    private let onFire: () -> Void
    private var monitors: [Any] = []
    private var downAt: TimeInterval?
    private var lastTap: TimeInterval?
    private static let maxPress: TimeInterval = 0.3
    private static let maxGap: TimeInterval = 0.4

    init(_ modifier: NSEvent.ModifierFlags, onFire: @escaping () -> Void) {
        self.modifier = modifier
        self.onFire = onFire
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] in self?.flagsChanged($0) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown],
                                                     handler: { [weak self] _ in self?.reset() }) {
            monitors.append(m)
        }
    }

    deinit { monitors.forEach(NSEvent.removeMonitor) }

    private func flagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command, .function])
        let now = event.timestamp
        if flags == modifier {
            downAt = now
        } else if flags.isEmpty, let down = downAt {
            downAt = nil
            guard now - down < Self.maxPress else { return reset() }
            if let last = lastTap, now - last < Self.maxGap {
                reset()
                onFire()
            } else {
                lastTap = now
            }
        } else {
            reset()
        }
    }

    private func reset() {
        downAt = nil
        lastTap = nil
    }
}
