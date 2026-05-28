import AppKit

final class ComposerWindow: NSWindow {
    let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "↵ send   ⇧↵ newline   ⎋ close")
    private var onSubmit: ((String) -> Void)?
    private let textDelegate = ComposerTextDelegate()

    var targetDescription: String = "no Claude Code session" {
        didSet { statusLabel.stringValue = "→ " + targetDescription }
    }

    init(onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
        // .titled (not .borderless) — Apple Intelligence's inline prediction
        // service appears to require a titled-window class to attach the
        // text input context. We hide the title bar visually via
        // .fullSizeContentView + transparent title bar + hidden buttons so
        // the composer still looks borderless.
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 220),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configureWindow()
        hideTitleBarChrome()
        buildContent()
        center()
    }

    private func hideTitleBarChrome() {
        // Keep the close (red) traffic-light visible — the user needs a
        // discoverable way to dismiss the composer beyond ⎋ / ⌥Space.
        // Route its click to hide() so the window survives for the next
        // toggle instead of being closed (which would tear down the
        // text view and lose autocorrect state).
        if let closeButton = standardWindowButton(.closeButton) {
            closeButton.isHidden = false
            closeButton.target = self
            closeButton.action = #selector(closeButtonClicked)
        }
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    @objc private func closeButtonClicked() {
        hide()
    }

    // MARK: - Window chrome

    private func configureWindow() {
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .utilityWindow
        minSize = NSSize(width: 460, height: 160)
    }

    private func buildContent() {
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        blur.translatesAutoresizingMaskIntoConstraints = false

        contentView = NSView()
        contentView?.addSubview(blur)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: contentView!.topAnchor),
            blur.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
        ])

        // ScrollView uses autolayout; its documentView (textView) must use
        // frame-based layout + autoresizingMask. Don't disable
        // translatesAutoresizingMaskIntoConstraints on the textView or its
        // frame collapses to zero and typed text becomes invisible.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let initialSize = NSSize(width: 600, height: 140)
        textView.frame = NSRect(origin: .zero, size: initialSize)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: initialSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 4, height: 8)

        // Apple text intelligence — only the features that work reliably
        // inside this borderless window today.
        //
        // smartInsertDeleteEnabled is OFF: when autocorrect has many active
        // suggestions on a long buffer, smart-delete walks through dismissing
        // them one by one before deleting characters, which feels like
        // Backspace is broken. Plain delete behaves predictably.
        //
        // inlinePredictionType is .disabled (not .default): leaving it on
        // .default puts the text view into a partial-prediction state
        // machine even when no ghost text appears, and that state machine
        // intercepts Delete. We'll re-enable once we've solved the visible-
        // ghost-text issue properly (currently tracked: the borderless
        // window class seems to block the prediction service from attaching).
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = false
        textView.usesInspectorBar = false

        if #available(macOS 14.4, *) {
            // .default = follow System Settings → Keyboard → Text Input →
            // Show inline predictive text.
            textView.inlinePredictionType = .default
        }
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .complete
        }

        scroll.documentView = textView
        textDelegate.onSubmit = { [weak self] in self?.submit() }
        textView.delegate = textDelegate

        // Footer
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "→ no Claude Code session"

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = .tertiaryLabelColor

        footer.addSubview(statusLabel)
        footer.addSubview(hintLabel)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let container: NSView = blur
        container.addSubview(scroll)
        container.addSubview(separator)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -12),

            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            separator.heightAnchor.constraint(equalToConstant: 1),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            footer.heightAnchor.constraint(equalToConstant: 18),

            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    // MARK: - Behavior

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        center()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        makeFirstResponder(textView)
    }

    func hide() {
        orderOut(nil)
        // Return focus to whatever was active before — without this, dropping
        // .nonactivatingPanel means TypeFlow stays frontmost after dismiss.
        NSApp.hide(nil)
    }

    func currentText() -> String {
        textView.string
    }

    func clear() {
        textView.string = ""
    }

    // MARK: - Keyboard

    /// Enter submission goes through ComposerTextDelegate; Escape is handled
    /// here because the text view doesn't intercept it.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            hide()
            return
        }
        super.keyDown(with: event)
    }

    @objc func submit() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        onSubmit?(text)
        clear()
        hide()
    }
}

/// Intercepts text-view command keys to give us chat-style behavior:
///   - Return       → submit
///   - Shift+Return → insert newline
final class ComposerTextDelegate: NSObject, NSTextViewDelegate {
    var onSubmit: (() -> Void)?

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?()
            return true
        case #selector(NSResponder.insertLineBreak(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        default:
            return false
        }
    }
}
