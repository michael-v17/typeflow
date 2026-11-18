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
///   2. ⌃G to open Rich Input (posted to Warp's pid so global hotkeys can't steal it). (⌃G *toggles* Rich Input in Warp; because we
///      close it again after every submit, it's reliably closed when we get
///      here, so this press reliably opens it.) Then CONFIRM it opened
///      (`RichInputCheck`): in a tab where Warp hasn't recognized claude yet, ⌃G
///      reaches claude and opens its editor (vim). Unconfirmed → stop: no paste,
///      no ↵, no second ⌃G, pasteboard untouched; the composer keeps the text.
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
        case warpNotFrontmost
        /// ⌃G didn't open Rich Input; nothing else was typed.
        case richInputNotOpened

        /// Shown in the composer's footer (not an alert) for `richInputNotOpened`.
        static let richInputMessage = "Couldn't open Warp's input — text kept"

        var description: String {
            switch self {
            case .noAccessibilityPermission:
                return "TypeFlow needs Accessibility permission to send keystrokes to Warp. " +
                       "Grant it in System Settings → Privacy & Security → Accessibility."
            case .warpNotRunning:
                return "Warp doesn't appear to be running."
            case .warpNotFrontmost:
                return "Warp didn't come to the front, so nothing was sent. Your draft is still here — try again."
            case .richInputNotOpened:
                return Self.richInputMessage
            }
        }
    }

    /// Bundle identifiers for Warp (Stable / Preview).
    private static let warpBundleIDs = [
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "dev.warp.Warp-Preview",
    ]

    static func isWarp(_ app: NSRunningApplication?) -> Bool {
        warpBundleIDs.contains(app?.bundleIdentifier ?? "")
    }

    /// Delays tuned to give Warp time to open Rich Input and process the paste.
    private static let postActivateMicros: UInt32 = 60_000  // 60ms, once Warp is confirmed frontmost
    /// Upper bounds for the two waits before any keystroke is synthesized.
    private static let modifierReleaseTimeout: TimeInterval = 1.0
    private static let activationTimeout: TimeInterval = 1.0
    private static let debug = ProcessInfo.processInfo.environment["TYPEFLOW_DEBUG"] == "1"
    private static let postRichInputMicros: UInt32 = 150_000 // 150ms — opening RI takes a beat
    /// How long to wait for Rich Input to show up after ⌃G before giving up.
    private static let richInputTimeout: TimeInterval = 0.8
    private static let postPasteMicros: UInt32 = 80_000     // 80ms
    private static let postSubmitMicros: UInt32 = 80_000    // 80ms before restoring pasteboard

    /// Returns true if Accessibility is already granted; otherwise triggers
    /// the system prompt (only on first call) and returns false.
    static func checkAccessibility(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: CFDictionary = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// `text` is pasted as is — any provenance prefix is already in it
    /// (`ComposerSend.payload()`).
    static func send(_ text: String, autoSubmit: Bool = true) throws {
        guard checkAccessibility(prompt: true) else {
            throw InjectError.noAccessibilityPermission
        }
        guard let warp = findWarp() else {
            throw InjectError.warpNotRunning
        }

        // 0. Wait for the user to let go of modifiers (e.g. ⌥ from ⌥↵). A held
        //    key merges into our synthetic events: ⌃G becomes ⌃⌥G and ↵ becomes
        //    ⌥↵ (a newline in claude), so the prompt never submits.
        waitForModifierRelease()

        // 1. Activate Warp, and CONFIRM it's frontmost before typing anything.
        //    macOS 14+ activation is cooperative: we yield first, and a fixed
        //    sleep isn't enough — if Warp isn't in front, the keystrokes land
        //    back in TypeFlow and the prompt is silently lost.
        NSApp.yieldActivation(to: warp)
        warp.activate(options: [])
        guard waitUntilFrontmost(warp) else {
            log("send aborted: frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
            throw InjectError.warpNotFrontmost
        }
        usleep(postActivateMicros)
        log("send: Warp frontmost, injecting \(text.count) chars")

        // 2. ⌃G — open Rich Input, and confirm it opened before typing anything else.
        let before = RichInputCheck.snapshot(of: warp)
        sendKey(keyCode: UInt16(kVK_ANSI_G), modifiers: .maskControl, to: warp)
        let check = RichInputCheck.waitUntilOpened(warp, from: before, timeout: richInputTimeout)
        log("send: rich input \(check.opened ? "opened" : "NOT opened") before=\(before) after=\(check.last)")
        guard check.opened else { throw InjectError.richInputNotOpened }
        usleep(postRichInputMicros)

        // 3. Stash and replace pasteboard.
        let pb = NSPasteboard.general
        let savedString = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        // 4. ⌘V — paste.
        sendKey(keyCode: UInt16(kVK_ANSI_V), modifiers: .maskCommand, to: warp)
        usleep(postPasteMicros)

        // 5. ↵ — submit.
        if autoSubmit {
            sendKey(keyCode: UInt16(kVK_Return), modifiers: [], to: warp)
            usleep(postSubmitMicros)

            // 6. ⌃G again — close Rich Input so keyboard focus returns to
            //    claude's TUI. Warp's ⌃G toggles Rich Input (show/hide) and it
            //    stays open after a submit, otherwise swallowing the keys claude
            //    expects for its interactive prompts (arrow-key menus, y/n).
            sendKey(keyCode: UInt16(kVK_ANSI_G), modifiers: .maskControl, to: warp)
            usleep(postRichInputMicros)
        }

        // 7. Restore pasteboard.
        pb.clearContents()
        if let savedString {
            pb.setString(savedString, forType: .string)
        }
    }

    // MARK: - Helpers

    static func waitForModifierRelease() {
        let held: CGEventFlags = [.maskAlternate, .maskCommand, .maskControl, .maskShift]
        let deadline = Date().addingTimeInterval(modifierReleaseTimeout)
        while !CGEventSource.flagsState(.hidSystemState).intersection(held).isEmpty,
              Date() < deadline {
            usleep(10_000)
        }
    }

    private static func waitUntilFrontmost(_ app: NSRunningApplication) -> Bool {
        let deadline = Date().addingTimeInterval(activationTimeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                return true
            }
            // Let the run loop deliver the activation notifications.
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return false
    }

    private static func log(_ message: String) {
        if debug { fputs("TypeFlow: \(message)\n", stderr) }
    }

    private static func findWarp() -> NSRunningApplication? {
        for id in warpBundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                return app
            }
        }
        return nil
    }

    /// Posts the key straight to Warp's process rather than the system-wide HID
    /// stream. Global hotkeys only see the HID stream, so another app's shortcut
    /// can't steal the keystroke (the Gemini app grabs ⌃G globally, which sent
    /// our prompts to Gemini instead of Warp's Rich Input).
    private static func sendKey(keyCode: UInt16, modifiers: CGEventFlags, to app: NSRunningApplication) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src,
                                 virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src,
                               virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = modifiers
        up.flags = modifiers
        down.postToPid(app.processIdentifier)
        up.postToPid(app.processIdentifier)
    }
}
