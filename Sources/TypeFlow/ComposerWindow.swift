import AppKit

final class ComposerWindow: NSPanel {
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "⌘↵ send   ⎋ close")
    private var onSubmit: ((String) -> Void)?

    var targetDescription: String = "no Claude Code session" {
        didSet { statusLabel.stringValue = "→ " + targetDescription }
    }

    init(onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 220),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        configureWindow()
        buildContent()
        center()
    }

    // MARK: - Window chrome

    private func configureWindow() {
        isMovableByWindowBackground = true
        isFloatingPanel = true
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

        // The whole point of TypeFlow — full Apple text intelligence
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticTextCompletionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = true
        textView.usesFindBar = false
        textView.usesInspectorBar = false

        scroll.documentView = textView

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
    }

    func currentText() -> String {
        textView.string
    }

    func clear() {
        textView.string = ""
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        // Return / Enter
        if event.keyCode == 36 || event.keyCode == 76 {
            if cmd {
                submit()
                return
            }
        }
        // Escape
        if event.keyCode == 53 {
            hide()
            return
        }
        super.keyDown(with: event)
    }

    private func submit() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSubmit?(text)
        clear()
        hide()
    }
}
