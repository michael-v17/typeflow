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

        installMenuBarItem()
        refreshStatus(sessions: [])
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
            let tty = (target.ttyPath as NSString).lastPathComponent
            composer.targetDescription = "claude (pid \(target.pid) · \(tty))"
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

