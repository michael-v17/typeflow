import AppKit
import ApplicationServices

/// Tells whether ⌃G really opened Warp's Rich Input, before anything is pasted.
///
/// In a fresh tab Warp may not have recognized claude yet, so ⌃G goes through to
/// claude itself, which opens its external editor (vim). Pasting and pressing ↵
/// there would type the prompt into whatever has focus. So the send compares
/// Warp's Accessibility state before and after ⌃G, and stops unless it changed
/// the way an opened Rich Input changes it.
///
/// Read-only: only AX attributes are read, nothing is pressed.
enum RichInputCheck {
    /// What Warp's Accessibility tree shows at one moment.
    struct Snapshot: Equatable {
        /// Edit › "Clear Command Editor" is enabled: an input editor has focus.
        var editorMenuEnabled: Bool?
        /// The focused element (Warp exposes one text area per focused editor).
        var focusedRole: String?
        /// Length of the focused element's value. Warp exposes the terminal's
        /// text there; an editor that just opened is empty or much shorter.
        var focusedValueLength: Int?
        /// Identity of the focused element, to notice that focus moved.
        var focusedHash: Int?
    }

    static func snapshot(of warp: NSRunningApplication) -> Snapshot {
        let app = AXUIElementCreateApplication(warp.processIdentifier)
        var s = Snapshot()
        if let focused = element(app, kAXFocusedUIElementAttribute) {
            s.focusedRole = string(focused, kAXRoleAttribute)
            s.focusedValueLength = string(focused, kAXValueAttribute)?.utf16.count
            s.focusedHash = Int(CFHash(focused))
        }
        s.editorMenuEnabled = menuItem(in: app, menu: "Edit", title: "Clear Command Editor")
            .flatMap { bool($0, kAXEnabledAttribute) }
        return s
    }

    /// True when the change from `before` to `after` is Rich Input opening.
    /// Unknown (nil) signals never count as evidence.
    static func opened(from before: Snapshot, to after: Snapshot) -> Bool {
        if before.editorMenuEnabled == false, after.editorMenuEnabled == true { return true }
        return false
    }

    /// Polls until `opened` holds or `timeout` passes. Returns the last snapshot
    /// too, for the debug log.
    static func waitUntilOpened(_ warp: NSRunningApplication, from before: Snapshot,
                                timeout: TimeInterval) -> (opened: Bool, last: Snapshot) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = before
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            last = snapshot(of: warp)
            if opened(from: before, to: last) { return (true, last) }
        } while Date() < deadline
        return (false, last)
    }

    // MARK: - AX helpers

    private static func menuItem(in app: AXUIElement, menu: String, title: String) -> AXUIElement? {
        guard let bar = element(app, kAXMenuBarAttribute) else { return nil }
        for top in children(bar) where string(top, kAXTitleAttribute) == menu {
            for list in children(top) {
                for item in children(list) where string(item, kAXTitleAttribute) == title { return item }
            }
        }
        return nil
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
}
