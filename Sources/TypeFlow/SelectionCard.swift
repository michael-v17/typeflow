import AppKit
import Carbon.HIToolbox

/// The small card under a selection, for the hotkeys that work in any app:
/// right-click → Translate with TypeFlow, ⌥ ⌥ or ⌥⌘T show the translation (Copy,
/// ▶); ⌥⌘K the quick correction, only the corrected text. It never takes focus
/// from the app you're in; ⎋, a click elsewhere or switching apps closes it.
final class SelectionCard: NSPanel {
    private let header = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton()
    private let speakButton = NSButton()
    private let speaker = Speaker()
    /// Its own, so a quick correction never cancels the composer's ⌘K.
    private let coach = EnglishCoach()
    private var result: (text: String, language: DraftLanguage)?
    /// What ▶ reads: always the English side — the translation, or for EN → ES
    /// the original, to hear how it's said.
    private var spoken: String?
    private var task: Task<Void, Never>?
    private var monitors: [Any] = []
    private var appObserver: NSObjectProtocol?
    /// Showing a quick correction: the card stays out of the keyboard's way, so
    /// its ⌘V reaches the app.
    private var correcting = false
    /// The app the correction is pasted into: over its selection, or at its cursor
    /// for clipboard text.
    private var replaceIn: NSRunningApplication?
    /// Why it won't be pasted: something was clicked, typed or switched meanwhile,
    /// so the selection may be gone. Shown on the card.
    private var notPasted: String?
    /// The global monitors also see our own keys: the ⌘C that read the selection
    /// (it reaches them only once the card is up) and the ⌘V that pastes.
    private var ignoreInputUntil = Date.distantPast
    private static let maxTextWidth: CGFloat = 380

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        buildContent()
        speaker.onFinish = { [weak self] in self?.refreshSpeakButton() }
    }

    // For ⎋; non-activating, so the app keeps focus.
    override var canBecomeKey: Bool { !correcting }

    private func buildContent() {
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        contentView = blur

        header.font = .systemFont(ofSize: 10, weight: .semibold)
        header.textColor = .tertiaryLabelColor
        body.font = .systemFont(ofSize: 14)
        body.isSelectable = true
        body.preferredMaxLayoutWidth = Self.maxTextWidth

        for (button, symbol, tip, action) in [
            (copyButton, "doc.on.doc", "Copy the translation", #selector(copyClicked)),
            (speakButton, "play.fill", "Read the English aloud", #selector(speakClicked)),
        ] {
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = tip
            button.target = self
            button.action = action
        }
        copyButton.title = "Copy"
        copyButton.imagePosition = .imageLeading
        copyButton.font = .systemFont(ofSize: 11)

        let top = NSStackView(views: [header, NSView(), speakButton, copyButton])
        top.spacing = 6
        let stack = NSStackView(views: [top, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    /// Translate `text` and show the card under `anchor` (the selection), or under
    /// the mouse when the app doesn't say where the selection is.
    func show(translating text: String, near anchor: NSRect?) {
        open(text, status: "TRANSLATING…", near: anchor, correcting: false)
        makeKey()

        task = Task { [weak self] in
            do {
                let r = try await Translator.translate(text)
                guard let self, !Task.isCancelled else { return }
                self.result = (r.text, r.to)
                self.spoken = r.to == .english ? r.text : text
                self.showResult("\(r.from.rawValue) → \(r.to.rawValue)", r.text)
                self.copyButton.isHidden = false
                self.speakButton.isHidden = false
                self.refreshSpeakButton()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.showFailure("CAN'T TRANSLATE", error)
            }
            self?.place(near: anchor)
        }
    }

    /// ⌥⌘K: correct `text` with the ⌘K coach and show only the corrected text. It
    /// goes on the clipboard, and is pasted into `app` (over its selection) when
    /// it's still in front and nothing was clicked or typed meanwhile. ⎋ cancels.
    func show(correcting text: String, near anchor: NSRect?, replaceIn app: NSRunningApplication?) {
        if isKeyWindow { orderOut(nil) } // a translation still holds the keyboard
        open(text, status: "CORRECTING…", near: anchor, correcting: true)
        replaceIn = app

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await self.coach.check(text)
                guard !Task.isCancelled else { return }
                self.task = nil
                self.land(r, correcting: text)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.task = nil
                self.showFailure("CAN'T CORRECT", error)
            }
            self.place(near: anchor)
        }
    }

    private func open(_ text: String, status: String, near anchor: NSRect?, correcting: Bool) {
        task?.cancel()
        coach.cancel()
        speaker.stop()
        result = nil
        spoken = nil
        self.correcting = correcting
        replaceIn = nil
        notPasted = nil
        header.stringValue = status
        body.stringValue = text.count > 140 ? String(text.prefix(140)) + "…" : text
        body.textColor = .tertiaryLabelColor
        copyButton.isHidden = true
        speakButton.isHidden = true
        place(near: anchor)
        orderFrontRegardless()
        ignoreInputUntil = Date().addingTimeInterval(0.5)
        startDismissWatch()
    }

    /// Log it like a ⌘K-checked copy, then paste it over the selection, or leave
    /// it on the clipboard. Already natural: nothing changes.
    private func land(_ r: CoachResult, correcting text: String) {
        let draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Not `isClean`: the coach can capitalize or add a period without listing
        // a fix. Typographic quotes don't count (`native` is already straight).
        let fixed = r.native.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = fixed != EnglishCoach.straight(draft)
        WingmanEnglishLog.record(ComposerSend(
            text: changed ? fixed : draft, draft: draft, dictated: false, coach: r,
            corrected: changed, cwd: nil, destination: .clipboard))
        guard changed else { return showResult("✓ LOOKS GOOD", draft) }

        let pb = NSPasteboard.general
        pb.clearContents()
        if notPasted == nil,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != replaceIn?.processIdentifier {
            notPasted = "ANOTHER APP IS IN FRONT"
        }
        if notPasted == nil {
            // Keep the selection's leading/trailing spaces and newlines.
            let lead = text.prefix(while: \.isWhitespace)
            let trail = String(text.reversed().prefix(while: \.isWhitespace).reversed())
            pb.setString(String(lead) + fixed + trail, forType: .string)
            ignoreInputUntil = Date().addingTimeInterval(0.4)
            SelectedText.paste()
            showResult(r.isTranslation ? "✓ IN ENGLISH" : "✓ CORRECTED", fixed)
        } else {
            pb.setString(fixed, forType: .string)
            showResult("✓ COPIED · ⌘V TO PASTE · " + (notPasted ?? ""), fixed)
        }
    }

    private func showResult(_ status: String, _ text: String) {
        header.stringValue = status
        body.stringValue = text
        body.textColor = .labelColor
    }

    private func showFailure(_ status: String, _ error: Error) {
        header.stringValue = status
        body.stringValue = error.localizedDescription
        body.textColor = .secondaryLabelColor
    }

    /// Size to the text, then sit just below the selection (above it if there's
    /// no room), kept on the selection's screen.
    private func place(near anchor: NSRect?) {
        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? frame.size
        let mouse = NSEvent.mouseLocation
        let a = anchor ?? NSRect(x: mouse.x, y: mouse.y - 4, width: 0, height: 20)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(a) || $0.frame.contains(mouse) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: a.minX, y: a.minY - size.height - 6)
        if origin.y < visible.minY { origin.y = a.maxY + 6 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func startDismissWatch() {
        guard monitors.isEmpty else { return }
        // Global monitors only see input meant for other apps — clicks on the card are ours.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown],
                                                     handler: { [weak self] in self?.userActed($0) }) {
            monitors.append(m)
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.userActed(nil) }
    }

    /// A click, key or app switch elsewhere closes the card — except while a
    /// correction is running: then only ⎋ does (and cancels it); anything else
    /// just keeps it from pasting. A held key's repeats don't count.
    private func userActed(_ event: NSEvent?) {
        guard Date() >= ignoreInputUntil else { return }
        if let event, event.type == .keyDown, event.isARepeat { return }
        let escape = event?.type == .keyDown && event?.keyCode == UInt16(kVK_Escape) // keyCode: key events only
        if correcting, task != nil, !escape {
            notPasted = notPasted ?? (event == nil ? "YOU SWITCHED APPS"
                                      : event?.type == .keyDown ? "YOU TYPED MEANWHILE" : "YOU CLICKED MEANWHILE")
        } else {
            dismiss()
        }
    }

    func dismiss() {
        task?.cancel()
        task = nil
        coach.cancel()
        speaker.stop()
        replaceIn = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        orderOut(nil)
    }

    override func cancelOperation(_ sender: Any?) { dismiss() } // ⎋

    @objc private func copyClicked() {
        guard let result else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.text, forType: .string)
        header.stringValue = "✓ COPIED"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.dismiss() }
    }

    @objc private func speakClicked() {
        guard let spoken else { return }
        if speaker.isSpeaking { speaker.stop() } else { speaker.speak(spoken, language: .english) }
        refreshSpeakButton()
    }

    private func refreshSpeakButton() {
        let playing = speaker.isSpeaking
        speakButton.image = NSImage(systemSymbolName: playing ? "stop.fill" : "play.fill",
                                    accessibilityDescription: playing ? "Stop" : "Read the English aloud")
    }
}
