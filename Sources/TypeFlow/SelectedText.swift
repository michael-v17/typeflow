import AppKit
import Carbon.HIToolbox

/// Text selected in another app, for right-click → TypeFlow (macOS Services) and
/// its hotkeys (⌥⌘E correct, ⌥⌘T translate), which cover apps without Services
/// (Warp, most Electron apps).
enum SelectedText {
    /// The front app's selection: Accessibility first, then a synthesized ⌘C with
    /// the clipboard put back afterwards. nil when nothing is selected.
    static func grab() -> String? {
        if let text = focusedElement().flatMap(axSelectedText), !text.isEmpty { return text }
        return copyFromFrontApp()
    }

    /// Where the selection is on screen (Cocoa coordinates), for placing the
    /// translation card under it. nil when the app doesn't say.
    static func bounds() -> NSRect? {
        guard let element = focusedElement() else { return nil }
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        // AX is top-left based on the primary screen; Cocoa is bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    private static func axSelectedText(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// ⌘C into the front app, read what it copied, then restore the clipboard
    /// (every item and type, so a copied image survives too).
    private static func copyFromFrontApp() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        // The hotkey's ⌥ would turn our ⌘C into ⌥⌘C.
        WarpInjector.waitForModifierRelease()
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let before = pb.changeCount
        let src = CGEventSource(stateID: .hidSystemState)
        let c = CGKeyCode(kVK_ANSI_C)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: false) else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Through the HID stream, like a real ⌘C: Chrome ignores keys posted to its pid.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        let deadline = Date().addingTimeInterval(0.5)
        while pb.changeCount == before, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard pb.changeCount != before else { return nil } // nothing selected
        let text = pb.string(forType: .string)
        pb.clearContents()
        let items = saved.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
        return text?.isEmpty == false ? text : nil
    }
}

/// The right-click entries ("Correct with TypeFlow", "Translate with TypeFlow"),
/// declared as `NSServices` in Info.plist (scripts/make-app.sh). macOS lists them
/// in the context menu of selected text in any app that supports Services.
final class ServiceProvider: NSObject {
    var onCorrect: ((String) -> Void)?
    var onTranslate: ((String) -> Void)?

    @objc func correctSelection(_ pboard: NSPasteboard, userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = Self.text(pboard) else { return }
        onCorrect?(text)
    }

    @objc func translateSelection(_ pboard: NSPasteboard, userData: String?,
                                  error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = Self.text(pboard) else { return }
        onTranslate?(text)
    }

    private static func text(_ pboard: NSPasteboard) -> String? {
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
