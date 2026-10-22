import AppKit
import Carbon.HIToolbox

/// Text selected in another app, for right-click → TypeFlow (macOS Services) and
/// its hotkeys (⌥⌘E correct, ⌥⌘K quick fix, ⌥⌘T translate), which cover apps
/// without Services (Warp, most Electron apps).
enum SelectedText {
    /// What a hotkey works on.
    struct Grab {
        let text: String
        /// Read from the clipboard: there's no selection to place a card under or
        /// paste over.
        let fromClipboard: Bool
        /// The app that was in front.
        let app: NSRunningApplication?
    }

    /// The front app's selection: Accessibility first, then a synthesized ⌘C with
    /// the clipboard put back afterwards; with neither, the clipboard itself (Warp
    /// copies on select but answers neither). `cut` also removes the selection
    /// from the app, like ⌘X — the original then stays on the clipboard. nil when
    /// there's no text anywhere.
    static func grab(cut: Bool = false) -> Grab? {
        let app = NSWorkspace.shared.frontmostApplication
        let cut = cut && !WarpInjector.isWarp(app) // terminal output can't be cut
        if let text = focusedElement().flatMap(axSelectedText), !text.isEmpty {
            if cut { _ = press(kVK_ANSI_X) } // read-only text just stays
            return Grab(text: text, fromClipboard: false, app: app)
        }
        if let text = (cut ? cutFromFrontApp() : nil) ?? copyFromFrontApp() {
            return Grab(text: text, fromClipboard: false, app: app)
        }
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Grab(text: text, fromClipboard: true, app: app)
    }

    /// ⌥⌘E / right-click → Correct also cuts the selection from its app, so the
    /// correction pastes in its place. On by default (⋯ menu, menu bar menu).
    static var cutWhenCorrecting: Bool {
        get { (UserDefaults.standard.object(forKey: cutKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: cutKey) }
    }
    private static let cutKey = "TypeFlowCutWhenCorrecting"

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
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        guard press(kVK_ANSI_C) else { return nil } // nothing selected
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

    /// ⌘X into the front app: the selection leaves it and stays on the clipboard,
    /// as with a real cut. Its text; nil when nothing was cut (read-only text, no
    /// selection).
    @discardableResult
    static func cutFromFrontApp() -> String? {
        guard press(kVK_ANSI_X) else { return nil }
        let text = NSPasteboard.general.string(forType: .string)
        return text?.isEmpty == false ? text : nil
    }

    /// ⌘V into the front app: whatever is on the clipboard replaces its selection.
    static func paste() {
        post(kVK_ANSI_V)
    }

    /// ⌘`key` into the front app; true once it changed the clipboard (≤0.5 s).
    private static func press(_ key: Int) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
        let pb = NSPasteboard.general
        let before = pb.changeCount
        post(key)
        let deadline = Date().addingTimeInterval(0.5)
        while pb.changeCount == before, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return pb.changeCount != before
    }

    private static func post(_ key: Int) {
        // The hotkey's ⌥ would turn our ⌘C into ⌥⌘C.
        WarpInjector.waitForModifierRelease()
        let src = CGEventSource(stateID: .hidSystemState)
        let code = CGKeyCode(key)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Through the HID stream, like a real ⌘C: Chrome ignores keys posted to its pid.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
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
