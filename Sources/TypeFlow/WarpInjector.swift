import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Sends prompts into Warp's Rich Input editor instead of writing into the
/// PTY directly. This sidesteps every claude-CLI input quirk (cursor jumping
/// home, submit not firing, multi-line edit breaking) because Rich Input is
/// a proper editor that handles paste, edit, and submit natively.
///
/// Mechanism:
///   1. Activate Warp.
///   2. ⌃G to open Rich Input. (⌃G *toggles* Rich Input in Warp; because we
///      close it again after every submit, it's reliably closed when we get
///      here, so this press reliably opens it.)
///   3. Put text on the pasteboard.
///   4. ⌘V to paste.
///   5. ↵ to submit (when `autoSubmit` is true).
///   6. ⌃G again to close Rich Input, so keyboard focus returns to claude's TUI
///      and its interactive prompts (arrow-key menus, y/n) are navigable. Only
///      when we submitted — an un-submitted draft is left open for editing.
///   7. Restore pasteboard.
///
/// Requires the Accessibility permission (one-time grant in System Settings →
/// Privacy & Security → Accessibility).
enum WarpInjector {
    enum InjectError: Error, CustomStringConvertible {
        case noAccessibilityPermission
        case warpNotRunning

        var description: String {
            switch self {
            case .noAccessibilityPermission:
                return "TypeFlow needs Accessibility permission to send keystrokes to Warp. " +
                       "Grant it in System Settings → Privacy & Security → Accessibility."
            case .warpNotRunning:
                return "Warp doesn't appear to be running."
            }
        }
    }

    /// Bundle identifiers for Warp (Stable / Preview).
    private static let warpBundleIDs = [
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "dev.warp.Warp-Preview",
    ]

    /// Delays tuned to give Warp time to open Rich Input and process the paste.
    private static let postActivateMicros: UInt32 = 60_000  // 60ms
    private static let postRichInputMicros: UInt32 = 150_000 // 150ms — opening RI takes a beat
    private static let postPasteMicros: UInt32 = 80_000     // 80ms
    private static let postSubmitMicros: UInt32 = 80_000    // 80ms before restoring pasteboard

    /// Returns true if Accessibility is already granted; otherwise triggers
    /// the system prompt (only on first call) and returns false.
    static func checkAccessibility(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: CFDictionary = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func send(_ text: String, autoSubmit: Bool = true) throws {
        guard checkAccessibility(prompt: true) else {
            throw InjectError.noAccessibilityPermission
        }
        guard let warp = findWarp() else {
            throw InjectError.warpNotRunning
        }

        // 1. Activate Warp.
        warp.activate(options: [])
        usleep(postActivateMicros)

        // 2. Stash and replace pasteboard.
        let pb = NSPasteboard.general
        let savedString = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        // 3. ⌃G — open Rich Input.
        sendKey(keyCode: UInt16(kVK_ANSI_G), modifiers: .maskControl)
        usleep(postRichInputMicros)

        // 4. ⌘V — paste.
        sendKey(keyCode: UInt16(kVK_ANSI_V), modifiers: .maskCommand)
        usleep(postPasteMicros)

        // 5. ↵ — submit.
        if autoSubmit {
            sendKey(keyCode: UInt16(kVK_Return), modifiers: [])
            usleep(postSubmitMicros)

            // 6. ⌃G again — close Rich Input so keyboard focus returns to
            //    claude's TUI. Warp's ⌃G toggles Rich Input (show/hide) and it
            //    stays open after a submit, otherwise swallowing the keys claude
            //    expects for its interactive prompts (arrow-key menus, y/n).
            sendKey(keyCode: UInt16(kVK_ANSI_G), modifiers: .maskControl)
            usleep(postRichInputMicros)
        }

        // 7. Restore pasteboard.
        pb.clearContents()
        if let savedString {
            pb.setString(savedString, forType: .string)
        }
    }

    // MARK: - Helpers

    private static func findWarp() -> NSRunningApplication? {
        for id in warpBundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                return app
            }
        }
        return nil
    }

    private static func sendKey(keyCode: UInt16, modifiers: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src,
                                 virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src,
                               virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = modifiers
        up.flags = modifiers
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
