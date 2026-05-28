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
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
    }
}
