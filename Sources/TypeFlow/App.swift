import AppKit
import Carbon.HIToolbox

@main
enum TypeFlowMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var composer: ComposerWindow!
    var watcher: ProcessWatcher!
    var hotKey: HotKey!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        composer = ComposerWindow { [weak self] text in
            self?.sendToClaude(text) ?? false
        }
        composer.onSessionSelected = { [weak self] pid in
            self?.watcher.preferredPID = pid
            self?.refreshStatus(sessions: self?.watcher.sessions ?? [])
        }

        watcher = ProcessWatcher()
        watcher.onChange = { [weak self] sessions in
            self?.refreshStatus(sessions: sessions)
        }
        watcher.start()

        // Option+Space (⌥Space)
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            self?.toggleComposer()
        }

        installMainMenu()
        installMenuBarItem()
        refreshStatus(sessions: [])

        // Accessibility is needed both to send keystrokes to Warp AND to read
        // Warp's focused tab for session-following — request it up front rather
        // than only on the first send (prompts once, no-op once granted).
        _ = WarpInjector.checkAccessibility(prompt: true)
    }

    /// Accessory apps don't auto-install an Edit menu, so Cmd+C/V/X/Z and
    /// Cmd+Return have no key equivalents. The bar stays hidden but the
    /// menu's keyEquivalents fire whenever TypeFlow is the active app.
    private func installMainMenu() {
        let main = NSMenu()

        // App menu (required slot; we leave it empty other than Quit so the
        // composer feels like a single-purpose tool).
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit TypeFlow",
                        action: #selector(NSApp.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Edit menu — provides Cmd+Z/X/C/V/A.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let undo = editMenu.addItem(withTitle: "Undo",
                                    action: Selector(("undo:")), keyEquivalent: "z")
        undo.keyEquivalentModifierMask = [.command]
        let redo = editMenu.addItem(withTitle: "Redo",
                                    action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // Send is handled by ComposerTextDelegate (plain Enter), not via
        // a menu key equivalent — NSTextView intercepts Cmd+Return as
        // insertNewlineIgnoringFieldEditor: before menu equivalents fire.

        NSApp.mainMenu = main
    }

    private func installMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard.badge.ellipsis",
                                   accessibilityDescription: "TypeFlow")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Composer  ⌥Space",
                     action: #selector(toggleComposer),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TypeFlow",
                     action: #selector(NSApp.terminate(_:)),
                     keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc func toggleComposer() {
        // The composer follows the focused Warp tab itself while open (see
        // ComposerWindow.show / followTick), so just refresh the list here.
        refreshStatus(sessions: watcher.sessions)
        composer.toggle()
    }

    private func refreshStatus(sessions: [ClaudeSession], targetPID: pid_t? = nil) {
        composer.setSessions(sessions, targetPID: targetPID ?? watcher.target()?.pid)
        if let button = statusItem?.button {
            button.toolTip = sessions.isEmpty
                ? "TypeFlow — no Claude Code session"
                : "TypeFlow — \(sessions.count) Claude session(s)"
        }
    }

    /// Returns true if the prompt was sent. False lets the composer keep the
    /// text (and stay open) instead of clearing on a failed send.
    @discardableResult
    private func sendToClaude(_ text: String) -> Bool {
        // v2: send into Warp's Rich Input via keystroke synthesis instead of
        // writing into the claude PTY directly. Rich Input handles paste /
        // edit / submit natively, so we sidestep every claude-CLI input quirk.
        // Side effect: we send to whichever Warp tab is frontmost, not to a
        // specific tty — the session picker is now a visual indicator only.
        // (Full session-aware tab focusing is a future AX-traversal task.)
        do {
            try WarpInjector.send(text)
            return true
        } catch let error as WarpInjector.InjectError {
            NSSound.beep()
            fputs("TypeFlow: \(error)\n", stderr)
            showAlert(message: String(describing: error))
            return false
        } catch {
            NSSound.beep()
            fputs("TypeFlow: failed to send: \(error)\n", stderr)
            return false
        }
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "TypeFlow"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

