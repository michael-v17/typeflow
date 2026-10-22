import AppKit
import NaturalLanguage
import Translation

/// English ↔ Spanish with Apple's Translation framework: on-device, free, offline
/// once the languages are downloaded (System Settings → General → Language &
/// Region → Translation Languages).
enum Translator {
    enum Failure: LocalizedError {
        case notDownloaded, unsupported
        var errorDescription: String? {
            switch self {
            case .notDownloaded:
                return "English ↔ Spanish isn't downloaded yet. Get it in System Settings → General → Language & Region → Translation Languages."
            case .unsupported:
                return "Apple Translation can't translate between English and Spanish on this Mac."
            }
        }
    }

    /// The other language: English → Spanish, Spanish → English.
    static func translate(_ text: String) async throws -> (text: String, from: DraftLanguage, to: DraftLanguage) {
        let from = source(of: text)
        let to: DraftLanguage = from == .english ? .spanish : .english
        let source = Locale.Language(identifier: from == .english ? "en" : "es")
        let target = Locale.Language(identifier: to == .english ? "en" : "es")
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: break
        case .supported: throw Failure.notDownloaded
        default: throw Failure.unsupported
        }
        let session = TranslationSession(installedSource: source, target: target)
        return (try await session.translate(text).targetText, from, to)
    }

    /// The first translation in a process takes 2–3 s, later ones ~0.7 s:
    /// translate a word at launch so the first ⌥⌘T is already fast.
    static func warmUp() {
        Task.detached(priority: .utility) { _ = try? await translate("Hello there") }
    }

    /// `DraftLanguage.detect` waits for 2+ words; a single word gets the
    /// recognizer's best guess, English when it can't tell.
    private static func source(of text: String) -> DraftLanguage {
        if let lang = DraftLanguage.detect(text) { return lang }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .spanish]
        recognizer.processString(text)
        return recognizer.dominantLanguage == .spanish ? .spanish : .english
    }
}

/// Right-click → Translate with TypeFlow (or ⌥⌘T): a small card under the
/// selection with the translation, Copy and ▶. It never takes focus from the app
/// you're in; ⎋, a click elsewhere or switching apps closes it.
final class TranslationCard: NSPanel {
    private let header = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton()
    private let speakButton = NSButton()
    private let speaker = Speaker()
    private var result: (text: String, language: DraftLanguage)?
    private var task: Task<Void, Never>?
    private var clickMonitor: Any?
    private var appObserver: NSObjectProtocol?
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

    override var canBecomeKey: Bool { true } // for ⎋; non-activating, so the app keeps focus

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
            (speakButton, "play.fill", "Read it aloud", #selector(speakClicked)),
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
        task?.cancel()
        speaker.stop()
        result = nil
        header.stringValue = "TRANSLATING…"
        body.stringValue = text.count > 140 ? String(text.prefix(140)) + "…" : text
        body.textColor = .tertiaryLabelColor
        copyButton.isHidden = true
        speakButton.isHidden = true
        place(near: anchor)
        orderFrontRegardless()
        makeKey()
        startDismissWatch()

        task = Task { [weak self] in
            do {
                let r = try await Translator.translate(text)
                guard let self, !Task.isCancelled else { return }
                self.result = (r.text, r.to)
                self.header.stringValue = "\(r.from.rawValue) → \(r.to.rawValue)"
                self.body.stringValue = r.text
                self.body.textColor = .labelColor
                self.copyButton.isHidden = false
                self.speakButton.isHidden = false
                self.refreshSpeakButton()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.header.stringValue = "CAN'T TRANSLATE"
                self.body.stringValue = error.localizedDescription
                self.body.textColor = .secondaryLabelColor
            }
            self?.place(near: anchor)
        }
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
        guard clickMonitor == nil else { return }
        // Global monitors only see clicks in other apps — clicks on the card are ours.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.dismiss() }
    }

    func dismiss() {
        task?.cancel()
        speaker.stop()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        clickMonitor = nil
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
        guard let result else { return }
        if speaker.isSpeaking { speaker.stop() } else { speaker.speak(result.text, language: result.language) }
        refreshSpeakButton()
    }

    private func refreshSpeakButton() {
        let playing = speaker.isSpeaking
        speakButton.image = NSImage(systemSymbolName: playing ? "stop.fill" : "play.fill",
                                    accessibilityDescription: playing ? "Stop" : "Read it aloud")
    }
}
