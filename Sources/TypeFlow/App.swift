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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var composer: ComposerWindow!
    var watcher: ProcessWatcher!
    var hotKey: HotKey!
    var correctKey: HotKey!
    var quickFixKey: HotKey!
    var translateKey: HotKey!
    var translateTap: DoubleTap!
    var readKey: HotKey!
    /// ⌥⌘R's player, with its own voice so it never cuts off the card's or the composer's ▶.
    let reader = ReadAloudPanel()
    let services = ServiceProvider()
    let card = SelectionCard()
    var statusItem: NSStatusItem!
    private var cutItem: NSMenuItem!

    func applicationWillTerminate(_ notification: Notification) {
        composer.flushUnsentChecks()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        composer = ComposerWindow { [weak self] send in
            self?.sendToClaude(send) ?? false
        }
        watcher = ProcessWatcher()
        watcher.onChange = { [weak self] sessions in
            self?.refreshStatus(sessions: sessions)
        }
        watcher.start()
        ScreenText.warmUp() // so the first pasted screenshot doesn't wait ~65 s
        Translator.warmUp() // the first translation is 2–3 s cold
        if let demo = ProcessInfo.processInfo.environment["TYPEFLOW_DEMO_COACH"], demo == "1" || demo == "reply" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.composer.showDemoCoach(reply: demo == "reply")
            }
        }

        // Poll fast only while the composer is open; idle slowly otherwise.
        composer.onShow = { [weak self] in self?.watcher.boost() }
        composer.onHide = { [weak self] in self?.watcher.relax() }

        // Option+Space (⌥Space)
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            self?.toggleComposer()
        }

        // Right-click → Correct / Translate with TypeFlow (Services), plus
        // hotkeys for apps without Services (Warp, most Electron apps). The
        // hotkeys fall back to the clipboard when nothing selected can be read.
        services.onCorrect = { [weak self] text in
            // The app waits for this call to return before it takes any key.
            DispatchQueue.main.async {
                if SelectedText.cutWhenCorrecting { SelectedText.cutFromFrontApp() }
                self?.composer.correctSelection(text)
            }
        }
        services.onTranslate = { [weak self] text in self?.card.show(translating: text, near: SelectedText.bounds()) }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        correctKey = HotKey(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.withSelection(cut: SelectedText.cutWhenCorrecting) { self?.composer.correctSelection($0.text) }
        }
        // ⌥⌘K: the correction in place, no composer — for quick chat replies.
        quickFixKey = HotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.withSelection { grab in
                self?.card.show(correcting: grab.text, near: grab.fromClipboard ? nil : SelectedText.bounds(),
                                replaceIn: grab.app)
            }
        }
        translateKey = HotKey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.withSelection { self?.translate($0) }
        }
        // ⌥ ⌥: the one-finger way to translate, for frequent use.
        translateTap = DoubleTap(.option) { [weak self] in
            self?.withSelection { self?.translate($0) }
        }
        // ⌥⌘R: just hear it, no translation — a small player (ReadAloudPanel); again stops.
        readKey = HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            guard let self else { return }
            if self.reader.isReading { return self.reader.stop() }
            self.withSelection { self.reader.read($0.text, from: $0.app) }
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
        for line in ["Select or copy text, then:", "   ⌥⌘E  correct in the composer",
                     "   ⌥⌘K  quick fix in place", "   ⌥ ⌥ or ⌥⌘T  translate", "   ⌥⌘R  read aloud"] {
            menu.addItem(withTitle: line, action: nil, keyEquivalent: "").isEnabled = false
        }
        cutItem = menu.addItem(withTitle: "Cut the selection when correcting",
                               action: #selector(cutToggled), keyEquivalent: "")
        cutItem.target = self
        cutItem.toolTip = "⌥⌘E removes the selected text from its app (the original stays on the clipboard), so the correction pastes in its place"
        menu.delegate = self
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

    @objc private func cutToggled() {
        SelectedText.cutWhenCorrecting.toggle()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        cutItem.state = SelectedText.cutWhenCorrecting ? .on : .off // the ⋯ menu toggles it too
    }

    /// The front app's selection (else the clipboard), for the selection hotkeys;
    /// a beep when there's no text.
    private func withSelection(cut: Bool = false, _ use: @escaping (SelectedText.Grab) -> Void) {
        // Let the hotkey's key-up land first, so the ⌘C fallback isn't mixed with it.
        DispatchQueue.main.async {
            let grabbed = SelectedText.grab(cut: cut)
            if ProcessInfo.processInfo.environment["TYPEFLOW_DEBUG"] == "1" {
                fputs("TypeFlow: selection hotkey in \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"), got \(grabbed?.text.count ?? -1) chars\(grabbed?.fromClipboard == true ? " from the clipboard" : "")\n", stderr)
            }
            guard let grabbed,
                  !grabbed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
            use(grabbed)
        }
    }

    private func translate(_ grab: SelectedText.Grab) {
        card.show(translating: grab.text, near: grab.fromClipboard ? nil : SelectedText.bounds())
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
    private func sendToClaude(_ send: ComposerSend) -> Bool {
        // v2: send into Warp's Rich Input via keystroke synthesis instead of
        // writing into the claude PTY directly. Rich Input handles paste /
        // edit / submit natively, so we sidestep every claude-CLI input quirk.
        // Side effect: we send to whichever Warp tab is frontmost, not to a
        // specific tty — the footer label is a read-only indicator of that tab.
        // (Full session-aware tab focusing is a future AX-traversal task.)
        do {
            try WarpInjector.send(send.text, marker: send.marker)
            WingmanEnglishLog.record(send)
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

