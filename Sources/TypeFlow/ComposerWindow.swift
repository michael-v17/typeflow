import AppKit

final class ComposerWindow: NSWindow {
    let textView = GhostTextView()
    private let wordCompleter = WordCompleter()
    private let sessionPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hintLabel = NSTextField(labelWithString: "↵ send   ⇧↵ newline   ⎋ close")
    private var onSubmit: ((String) -> Void)?
    private let textDelegate = ComposerTextDelegate()

    /// Called when the user picks a session from the footer dropdown.
    var onSessionSelected: ((pid_t) -> Void)?

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
        // Hide all native traffic-lights. The standard close button is
        // rendered at window-origin (0,0) but is clipped by our 16pt
        // rounded-corner mask, so clicks don't land on it reliably.
        // We add a custom × button to the blur view's top-right instead.
        standardWindowButton(.closeButton)?.isHidden = true
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

        // Apple text intelligence. Autocorrect / spelling / grammar / Writing
        // Tools all work and are kept on — they're complementary to ghost text.
        //
        // smartInsertDeleteEnabled is OFF: when autocorrect has many active
        // suggestions on a long buffer, smart-delete walks through dismissing
        // them one by one before deleting characters, which feels like
        // Backspace is broken. Plain delete behaves predictably.
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        // Smart quotes/dashes are OFF on purpose: these prompts carry code, paths
        // and CLI commands that get sent verbatim to Claude. Curly quotes would
        // corrupt string literals and "--flag" would become an em dash ("—flag").
        // Straight quotes/dashes are universally safe; flip to true for prose-only.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = false
        textView.usesInspectorBar = false

        // Disable the native inline-prediction overlay. It never rendered
        // reliably for this window class (proven), and we now draw our OWN gray
        // ghost text via GhostTextView + GhostCompleter, fully under our control.
        // Leaving it on only risks the native state machine fighting Delete.
        if #available(macOS 14.4, *) {
            textView.inlinePredictionType = .no
        }
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .complete
        }

        scroll.documentView = textView
        textDelegate.onSubmit = { [weak self] in self?.submit() }
        textDelegate.onCancel = { [weak self] in self?.hide() }
        textDelegate.onTextChanged = { [weak self] in self?.handleTextChange() }
        textDelegate.onSelectionChanged = { [weak self] in self?.clearGhostIfCaretMoved() }
        textView.delegate = textDelegate

        // Footer
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false

        sessionPicker.translatesAutoresizingMaskIntoConstraints = false
        sessionPicker.isBordered = false
        sessionPicker.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        sessionPicker.controlSize = .small
        sessionPicker.target = self
        sessionPicker.action = #selector(sessionPickerChanged(_:))
        if let cell = sessionPicker.cell as? NSPopUpButtonCell {
            cell.arrowPosition = .arrowAtBottom
            cell.bezelStyle = .accessoryBarAction
        }
        // Seed with the empty state — App will repopulate via setSessions.
        sessionPicker.addItem(withTitle: "→ no Claude Code session")
        sessionPicker.isEnabled = false

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = .tertiaryLabelColor

        footer.addSubview(sessionPicker)
        footer.addSubview(hintLabel)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let container: NSView = blur
        container.addSubview(scroll)
        container.addSubview(separator)
        container.addSubview(footer)

        // Custom × close button in top-right corner
        let closeButton = NSButton(title: "", target: self,
                                   action: #selector(closeButtonClicked))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "Close")
        closeButton.contentTintColor = NSColor.tertiaryLabelColor
        closeButton.imagePosition = .imageOnly
        closeButton.toolTip = "Close (Esc)"
        container.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])

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

            sessionPicker.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: -6),
            sessionPicker.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
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
        textView.suggestion = nil
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
        textView.suggestion = nil
    }

    // MARK: - Ghost text (inline word completion)

    /// Guards against re-entrancy when our own edit triggers `textDidChange`.
    private var isCorrecting = false

    /// Runs on every text change: first apply contraction autocorrect (on a
    /// finished word), then refresh the word-completion ghost.
    private func handleTextChange() {
        autocorrectContraction()
        updateGhost()
    }

    /// When the user just typed a word boundary (space/punctuation) right after
    /// a known apostrophe-less contraction, replace it with the apostrophe form
    /// (e.g. "dont " → "don't "). One edit, fully undoable; caret preserved.
    private func autocorrectContraction() {
        guard !isCorrecting else { return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let caret = sel.location
        guard sel.length == 0, caret >= 2, caret <= ns.length else { return }

        // The char just before the caret must be a boundary (non-letter).
        guard let boundary = Unicode.Scalar(ns.character(at: caret - 1)),
              !CharacterSet.letters.contains(boundary) else { return }

        // The run of letters ending just before that boundary char.
        var start = caret - 1
        while start > 0 {
            guard let s = Unicode.Scalar(ns.character(at: start - 1)),
                  CharacterSet.letters.contains(s) else { break }
            start -= 1
        }
        let wordRange = NSRange(location: start, length: (caret - 1) - start)
        // >= 1 so a lone "i" can be capitalized to "I"; the corrector's map only
        // matches known words, so other single letters are left alone.
        guard wordRange.length >= 1 else { return }
        let word = ns.substring(with: wordRange)
        guard let corrected = ContractionCorrector.correction(for: word) else { return }

        isCorrecting = true
        textView.insertText(corrected, replacementRange: wordRange)
        // Restore the caret to after the trailing boundary char(s).
        let trailing = caret - (wordRange.location + wordRange.length)
        let newCaret = wordRange.location + (corrected as NSString).length + trailing
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
        isCorrecting = false
    }

    /// Completes the word currently being typed,
    /// but only when the caret is a collapsed insertion point at the END of the
    /// buffer (the dominant typing case, and where the gray suffix renders
    /// cleanly without overlapping following text).
    private func updateGhost() {
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        guard sel.length == 0, sel.location == ns.length else {
            textView.suggestion = nil
            return
        }
        textView.suggestion = wordCompleter.completion(in: textView.string, caret: sel.location)
    }

    /// If the caret moved off the end of the buffer (click, arrow keys), any
    /// pending suggestion is stale — drop it.
    private func clearGhostIfCaretMoved() {
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        if sel.length != 0 || sel.location != ns.length {
            textView.suggestion = nil
        }
    }

    /// Populates the footer dropdown with the live session list and selects
    /// whichever session the watcher's target() chose. The user can override
    /// by picking another item.
    func setSessions(_ sessions: [ClaudeSession], targetPID: pid_t?) {
        sessionPicker.removeAllItems()
        guard !sessions.isEmpty else {
            sessionPicker.addItem(withTitle: "→ no Claude Code session")
            sessionPicker.isEnabled = false
            return
        }
        sessionPicker.isEnabled = true
        // Sort newest-first so the implicit target sits at the top.
        let sorted = sessions.sorted(by: { $0.startTime > $1.startTime })
        for session in sorted {
            let title = "→ claude (\(session.shortLabel))"
            sessionPicker.addItem(withTitle: title)
            sessionPicker.lastItem?.representedObject = NSNumber(value: session.pid)
        }
        if let pid = targetPID,
           let item = sessionPicker.itemArray.first(where: {
               ($0.representedObject as? NSNumber)?.int32Value == pid
           }) {
            sessionPicker.select(item)
        }
    }

    @objc private func sessionPickerChanged(_ sender: NSPopUpButton) {
        guard let pidNumber = sender.selectedItem?.representedObject as? NSNumber
        else { return }
        onSessionSelected?(pid_t(pidNumber.int32Value))
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
///   - Tab          → accept the inline ghost suggestion (if showing)
///   - Return       → submit
///   - Shift+Return → insert newline
///   - Escape       → dismiss ghost, else close the composer
///
/// Escape needs explicit handling because NSTextView normally maps it to
/// `cancelOperation:` (used to dismiss completion popups) and swallows the
/// event before it can reach the window's keyDown override.
final class ComposerTextDelegate: NSObject, NSTextViewDelegate {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTextChanged: (() -> Void)?
    var onSelectionChanged: (() -> Void)?

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let ghost = textView as? GhostTextView
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            // Accept a showing ghost suggestion as ONE real edit (one undo step,
            // normal selection/IME accounting). Otherwise fall through to the
            // default Tab behavior.
            if let ghost, let suggestion = ghost.suggestion, !suggestion.isEmpty {
                ghost.insertText(suggestion, replacementRange: ghost.selectedRange())
                ghost.suggestion = nil
                return true
            }
            return false
        case #selector(NSResponder.insertNewline(_:)):
            ghost?.suggestion = nil
            onSubmit?()
            return true
        case #selector(NSResponder.insertLineBreak(_:)):
            ghost?.suggestion = nil
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // First Esc dismisses a showing ghost; with none, it closes the composer.
            if let ghost, ghost.suggestion != nil {
                ghost.suggestion = nil
                return true
            }
            onCancel?()
            return true
        default:
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        onTextChanged?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        onSelectionChanged?()
    }
}
