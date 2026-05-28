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
            self?.sendToClaude(text)
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

        // Composer menu — holds the Send action (Cmd+Return).
        let composerItem = NSMenuItem()
        let composerMenu = NSMenu(title: "Composer")
        let send = NSMenuItem(title: "Send to Claude",
                              action: #selector(ComposerWindow.submit),
                              keyEquivalent: "\r")
        send.keyEquivalentModifierMask = [.command]
        composerMenu.addItem(send)
        composerItem.submenu = composerMenu
        main.addItem(composerItem)

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
        // Refresh target before showing so the footer is correct
        refreshStatus(sessions: watcher.sessions)
        composer.toggle()
    }

    private func refreshStatus(sessions: [ClaudeSession]) {
        if let target = watcher.target() {
            composer.targetDescription = "claude (\(target.shortLabel))"
        } else {
            composer.targetDescription = "no Claude Code session"
        }
        if let button = statusItem?.button {
            button.toolTip = sessions.isEmpty
                ? "TypeFlow — no Claude Code session"
                : "TypeFlow — \(sessions.count) Claude session(s)"
        }
    }

    private func sendToClaude(_ text: String) {
        guard let target = watcher.target() else {
            NSSound.beep()
            return
        }
        do {
            try PTYWriter.send(text, to: target.ttyPath)
        } catch {
            NSSound.beep()
            fputs("TypeFlow: failed to send to \(target.ttyPath): \(error)\n", stderr)
        }
    }
}

