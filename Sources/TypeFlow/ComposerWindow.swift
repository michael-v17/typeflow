import AppKit

final class ComposerWindow: NSWindow {
    let textView = GhostTextView()
    private let wordCompleter = WordCompleter()
    private let ghostCompleter = GhostCompleter()
    private let grammarReviewer = GrammarReviewer()
    /// Suggestions panel (between the text and the footer) listing the current
    /// grammar/naturalness fixes; the window grows downward to fit it.
    private let grammarPanel = NSStackView()
    private var grammarPanelHeight: NSLayoutConstraint!
    private var currentSpans: [GrammarSpan] = []
    /// How much window height the panel currently adds (0 when there are no issues).
    private var panelExtraHeight: CGFloat = 0
    private static let debug = ProcessInfo.processInfo.environment["TYPEFLOW_DEBUG"] == "1"
    private let sessionPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hintLabel = NSTextField(labelWithString: "↵ send   ⇧↵ newline   ⎋ close")
    private let keepOpenCheckbox = NSButton(checkboxWithTitle: "keep open", target: nil, action: nil)
    private let dictateButton = NSButton()
    /// Returns true if the send succeeded; on false the composer keeps its text.
    /// Second arg: whether this draft was dictated (→ send carries the ;;v marker).
    private var onSubmit: ((String, Bool) -> Bool)?
    private let textDelegate = ComposerTextDelegate()

    /// Called when the user picks a session from the footer dropdown.
    var onSessionSelected: ((pid_t) -> Void)?

    /// Called when the composer is shown / hidden, so the app can speed up or
    /// slow down the session-poll cadence.
    var onShow: (() -> Void)?
    var onHide: (() -> Void)?

    private static let keepOpenKey = "TypeFlowKeepOpenAfterSend"
    /// When on, Enter sends the prompt but leaves the composer open and focused
    /// for the next one. Persisted across launches.
    private var keepOpen: Bool {
        // Default ON: keep the composer open after sending unless the user has
        // explicitly turned it off (object == nil means they never touched it).
        get { (UserDefaults.standard.object(forKey: Self.keepOpenKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.keepOpenKey) }
    }

    // Per-session state: a separate draft per Claude session, and live following
    // of whichever Warp tab is focused.
    private var sessions: [ClaudeSession] = []
    private var drafts: [pid_t: String] = [:]
    /// Per-session "this draft was dictated" flag, parallel to `drafts`. When set,
    /// the send carries the ;;v voice marker so the observer runs its
    /// dictation-misrecognition + naturalness analysis. Conservative: once the mic
    /// is used for a draft, the whole send is treated as voice.
    private var draftsDictated: [pid_t: Bool] = [:]
    /// Live dictated flag for the visible draft (mirrors draftsDictated[currentPID],
    /// the way textView.string mirrors drafts[currentPID]).
    private var liveDictated = false
    private var currentPID: pid_t?
    /// Last-seen Warp focused-window title. We re-follow only on a real change,
    /// so a manual dropdown pick isn't immediately overridden by the poll.
    private var lastWarpTitle: String?
    private var followTimer: Timer?

    init(onSubmit: @escaping (String, Bool) -> Bool) {
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
        // Warm the on-device model once so the first phrase completion is fast.
        // No-op (logs to stderr) if Foundation Models isn't available.
        ghostCompleter.bootstrap()
        grammarReviewer.bootstrap()
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

        keepOpenCheckbox.translatesAutoresizingMaskIntoConstraints = false
        keepOpenCheckbox.controlSize = .small
        keepOpenCheckbox.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        keepOpenCheckbox.target = self
        keepOpenCheckbox.action = #selector(keepOpenToggled(_:))
        keepOpenCheckbox.state = keepOpen ? .on : .off
        keepOpenCheckbox.toolTip = "Enter sends without closing the composer"

        dictateButton.translatesAutoresizingMaskIntoConstraints = false
        dictateButton.isBordered = false
        dictateButton.bezelStyle = .accessoryBarAction
        dictateButton.imagePosition = .imageOnly
        dictateButton.image = NSImage(systemSymbolName: "mic.fill",
                                      accessibilityDescription: "Dictate")
        dictateButton.contentTintColor = .tertiaryLabelColor
        dictateButton.toolTip = "Dictate (Apple dictation)"
        dictateButton.target = self
        dictateButton.action = #selector(startDictationClicked)

        // Grammar suggestions panel: a vertical list shown between the text and
        // the footer when the reviewer finds issues; the window grows to fit it.
        grammarPanel.translatesAutoresizingMaskIntoConstraints = false
        grammarPanel.orientation = .vertical
        grammarPanel.alignment = .leading
        grammarPanel.distribution = .fill
        grammarPanel.spacing = 4
        grammarPanel.isHidden = true
        grammarPanel.clipsToBounds = true

        footer.addSubview(sessionPicker)
        footer.addSubview(hintLabel)
        footer.addSubview(keepOpenCheckbox)
        footer.addSubview(dictateButton)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let container: NSView = blur
        container.addSubview(scroll)
        container.addSubview(grammarPanel)
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

        // The text area prefers a fixed height (priority high, not required, so a
        // manual vertical window-resize can still stretch it). Without this the
        // scroll view is the only unconstrained element in the vertical chain and
        // greedily absorbs the window growth meant for the grammar panel —
        // collapsing the panel to height 0 (the bug that hid the suggestions).
        let scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 140)
        scrollHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollHeight,
            scroll.bottomAnchor.constraint(equalTo: grammarPanel.topAnchor, constant: -8),

            grammarPanel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grammarPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            grammarPanel.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -10),

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
            keepOpenCheckbox.trailingAnchor.constraint(equalTo: hintLabel.leadingAnchor, constant: -14),
            keepOpenCheckbox.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            dictateButton.trailingAnchor.constraint(equalTo: keepOpenCheckbox.leadingAnchor, constant: -12),
            dictateButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            dictateButton.widthAnchor.constraint(equalToConstant: 16),
            dictateButton.heightAnchor.constraint(equalToConstant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])

        grammarPanelHeight = grammarPanel.heightAnchor.constraint(equalToConstant: 0)
        grammarPanelHeight.isActive = true
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
        onShow?() // boost the session poll while we're open
        // Follow the focused Warp tab live while the composer is open.
        lastWarpTitle = nil   // force the first poll to follow
        followTick()
        startFollowTimer()
    }

    func hide() {
        stopFollowTimer()
        onHide?() // drop the session poll back to idle cadence
        if let cur = currentPID { drafts[cur] = textView.string; draftsDictated[cur] = liveDictated } // preserve draft
        textView.suggestion = nil
        ghostCompleter.cancel()
        clearGrammar()
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
        clearGrammar() // the sent prompt's suggestions don't belong to the empty draft
        liveDictated = false
        refreshDictateButton()
        if let cur = currentPID { drafts[cur] = ""; draftsDictated[cur] = false } // the prompt was sent
    }

    /// Drop any pending grammar review + its marks/panel. A suggestion belongs to
    /// the exact draft it was computed from, so we clear it whenever the buffer is
    /// replaced (send, or switching to another session's draft) to avoid showing a
    /// fix that no longer matches the visible text.
    private func clearGrammar() {
        grammarReviewer.cancel()
        textView.setGrammarSpans([])
        populateGrammarPanel([])
    }

    // MARK: - Ghost text (inline word completion)

    /// Guards against re-entrancy when our own edit triggers `textDidChange`.
    private var isCorrecting = false

    /// Runs on every text change: first apply contraction autocorrect (on a
    /// finished word), then refresh the word-completion ghost.
    private func handleTextChange() {
        autocorrectContraction()
        updateGhost()
        updateGrammar()
    }

    /// Grammar/naturalness review. Existing marks go stale the instant the text
    /// changes, so clear them now and re-mark after the (debounced) review lands.
    private func updateGrammar() {
        // Marks + panel go stale the instant the text changes; clear now and
        // re-populate after the (debounced) review lands.
        textView.setGrammarSpans([])
        populateGrammarPanel([])
        let text = textView.string
        grammarReviewer.review(text) { [weak self] spans in
            guard let self, self.textView.string == text else { return } // ignore stale
            self.textView.setGrammarSpans(spans)
            self.populateGrammarPanel(spans)
        }
    }

    /// Rebuild the suggestions panel and grow/shrink the window to fit it.
    private func populateGrammarPanel(_ spans: [GrammarSpan]) {
        if Self.debug { fputs("TypeFlow: grammar panel populate spans=\(spans.count)\n", stderr) }
        currentSpans = spans
        grammarPanel.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let shown = Array(spans.prefix(5)) // cap the list; underlines still mark them all
        var rows: [NSView] = []
        // A "Fix all" header only earns its row when there's more than one issue.
        if shown.count >= 2 { rows.append(makeFixAllRow(count: shown.count)) }
        for (i, span) in shown.enumerated() { rows.append(makeGrammarRow(span, index: i)) }
        for row in rows {
            grammarPanel.addArrangedSubview(row)
            // Activate the full-width constraint ONLY after the row joins
            // grammarPanel — before that the two anchors share no common ancestor
            // and `.isActive = true` throws, aborting the whole populate (the bug
            // that left detection + underlines working but no panel).
            row.widthAnchor.constraint(equalTo: grammarPanel.widthAnchor).isActive = true
        }
        grammarPanel.isHidden = rows.isEmpty
        let n = CGFloat(rows.count)
        setPanelHeight(rows.isEmpty ? 0 : n * 22 + max(0, n - 1) * 4)
    }

    /// Header row shown above the suggestions when there are 2+ issues: a count
    /// on the left and a "Fix all" button that applies every fix at once.
    private func makeFixAllRow(count: Int) -> NSView {
        let label = NSTextField(labelWithString: "\(count) suggestions")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let fixAll = NSButton(title: "Fix all", target: self,
                              action: #selector(grammarFixAllClicked))
        fixAll.controlSize = .small
        fixAll.bezelStyle = .rounded
        fixAll.contentTintColor = .systemOrange
        fixAll.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [label, fixAll])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return row
    }

    /// One "original → correction · reason   [Fix]" row.
    private func makeGrammarRow(_ span: GrammarSpan, index: Int) -> NSView {
        let str = NSMutableAttributedString()
        str.append(NSAttributedString(string: span.original, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: 12)]))
        str.append(NSAttributedString(string: "  →  ", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]))
        str.append(NSAttributedString(string: span.correction, attributes: [
            .foregroundColor: NSColor.systemOrange, // match the in-text underline
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)]))
        str.append(NSAttributedString(string: "   \(span.reason)", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]))

        let label = NSTextField(labelWithAttributedString: str)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let fix = NSButton(title: "Fix", target: self, action: #selector(grammarFixClicked(_:)))
        fix.tag = index
        fix.controlSize = .small
        fix.bezelStyle = .rounded
        fix.contentTintColor = .systemOrange
        fix.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [label, fix])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        // Width is constrained by the caller AFTER the row is added to grammarPanel
        // (see populateGrammarPanel) — doing it here throws (no common ancestor yet).
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return row
    }

    @objc private func grammarFixClicked(_ sender: NSButton) {
        let i = sender.tag
        guard i >= 0, i < currentSpans.count else { return }
        applyGrammarSpan(currentSpans[i])
    }

    /// Apply every current fix in one go. Edits run right-to-left so each span's
    /// absolute range is still valid when we reach it (edits to the right never
    /// shift positions to the left), wrapped in one undo group so a single ⌘Z
    /// reverts the whole batch. Each span is re-validated against the live text.
    @objc private func grammarFixAllClicked() {
        let ordered = currentSpans.sorted { $0.range.location > $1.range.location }
        makeFirstResponder(textView)
        textView.undoManager?.beginUndoGrouping()
        for span in ordered {
            let ns = textView.string as NSString
            guard NSMaxRange(span.range) <= ns.length,
                  ns.substring(with: span.range) == span.original else { continue }
            textView.insertText(span.correction, replacementRange: span.range)
        }
        textView.undoManager?.endUndoGrouping()
        // The edits fire handleTextChange → updateGrammar, which clears the marks
        // and re-reviews; clear eagerly too so the panel doesn't flash stale rows.
        textView.setGrammarSpans([])
        populateGrammarPanel([])
    }

    /// Replace just this span with its correction — one undoable edit, the rest of
    /// the prompt untouched. The text change re-runs the review for any remainder.
    private func applyGrammarSpan(_ span: GrammarSpan) {
        let ns = textView.string as NSString
        guard NSMaxRange(span.range) <= ns.length,
              ns.substring(with: span.range) == span.original else {
            populateGrammarPanel([]); textView.setGrammarSpans([]); return // stale
        }
        makeFirstResponder(textView)
        textView.insertText(span.correction, replacementRange: span.range)
    }

    /// Grow the window downward (top edge fixed) to make room for the panel.
    private func setPanelHeight(_ h: CGFloat) {
        let delta = h - panelExtraHeight
        guard abs(delta) > 0.5 else { return }
        panelExtraHeight = h
        grammarPanelHeight.constant = h
        var f = frame
        f.size.height += delta
        f.origin.y -= delta
        setFrame(f, display: true)
        contentView?.layoutSubtreeIfNeeded()
        if Self.debug {
            fputs("TypeFlow: setPanelHeight h=\(h) delta=\(delta) frameH=\(f.size.height) panelFrame=\(grammarPanel.frame)\n", stderr)
        }
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
            ghostCompleter.cancel()
            return
        }
        // Mid-word → instant local word completion (NSSpellChecker, English).
        if let word = wordCompleter.completion(in: textView.string, caret: sel.location) {
            ghostCompleter.cancel()
            textView.suggestion = word
            return
        }
        // No word to finish (a boundary, or a complete word) → ask the on-device
        // model for a short, context-aware continuation (Copilot-style, English,
        // debounced). Clear the stale ghost now; the async callback fills it in
        // only if the buffer is still exactly what we asked about (else it's stale).
        textView.suggestion = nil
        let prefix = textView.string
        ghostCompleter.requestCompletion(prefix: prefix) { [weak self] suggestion in
            guard let self else { return }
            let current = self.textView.string
            let caret = self.textView.selectedRange()
            guard current == prefix,
                  caret.length == 0, caret.location == (current as NSString).length
            else { return }
            self.textView.suggestion = suggestion.isEmpty ? nil : suggestion
        }
    }

    /// If the caret moved off the end of the buffer (click, arrow keys), any
    /// pending suggestion is stale — drop it.
    private func clearGhostIfCaretMoved() {
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        if sel.length != 0 || sel.location != ns.length {
            textView.suggestion = nil
            ghostCompleter.cancel()
        }
    }

    /// Populates the footer dropdown with the live session list. Drafts for
    /// sessions that have disappeared are discarded. Selection follows the
    /// current session if set, otherwise the supplied target.
    func setSessions(_ sessions: [ClaudeSession], targetPID: pid_t?) {
        let previousPIDs = Set(self.sessions.map { $0.pid })
        self.sessions = sessions
        // Forget drafts for sessions that no longer exist.
        let alive = Set(sessions.map { $0.pid })
        drafts = drafts.filter { alive.contains($0.key) }
        draftsDictated = draftsDictated.filter { alive.contains($0.key) }
        if let cur = currentPID, !alive.contains(cur) { currentPID = nil }

        sessionPicker.removeAllItems()
        guard !sessions.isEmpty else {
            sessionPicker.addItem(withTitle: "→ no Claude Code session")
            sessionPicker.isEnabled = false
            return
        }
        sessionPicker.isEnabled = true
        // Sort newest-first so the implicit target sits at the top.
        let sorted = sessions.sorted(by: { $0.startTime > $1.startTime })
        // PascalCase folder names; append the tty only to disambiguate collisions.
        let names = sorted.map { Self.sessionName(for: $0) }
        var counts: [String: Int] = [:]
        for n in names { counts[n, default: 0] += 1 }
        for (i, session) in sorted.enumerated() {
            var label = names[i]
            if (counts[names[i]] ?? 0) > 1 {
                label += " (\((session.ttyPath as NSString).lastPathComponent))"
            }
            sessionPicker.addItem(withTitle: "claude · \(label)")
            sessionPicker.lastItem?.representedObject = NSNumber(value: session.pid)
        }

        // A newly-spawned session becomes the current one — running `claude` in
        // a terminal should focus that session here, just like a new terminal
        // tab takes focus. `sorted` is newest-first, so this is the newest pid we
        // hadn't seen before. Per-session drafts mean the switch loses no input;
        // shouldAutoFocus only holds off while the user is mid-draft.
        let newSession = sorted.first { !previousPIDs.contains($0.pid) }
        if let newSession, shouldAutoFocus(newSession.pid) {
            switchTo(newSession.pid)
        } else if let pid = currentPID ?? targetPID {
            selectPicker(pid)
        }
    }

    /// Whether a newly-detected session should steal the composer's selection.
    /// We never yank the buffer out from under an in-progress draft in the open
    /// composer; otherwise (closed, or empty) the new session takes over.
    private func shouldAutoFocus(_ pid: pid_t) -> Bool {
        guard pid != currentPID else { return false }
        return !(isVisible && !textView.string.isEmpty)
    }

    @objc private func sessionPickerChanged(_ sender: NSPopUpButton) {
        guard let pidNumber = sender.selectedItem?.representedObject as? NSNumber
        else { return }
        let pid = pid_t(pidNumber.int32Value)
        switchTo(pid)            // swap to that session's draft
        onSessionSelected?(pid)
    }

    // MARK: - Session following & per-session drafts

    /// Swap the composer to a different session's draft, saving the current one
    /// first so nothing is lost. No-op if already on that session.
    private func switchTo(_ pid: pid_t) {
        guard pid != currentPID else { return }
        if let cur = currentPID { drafts[cur] = textView.string; draftsDictated[cur] = liveDictated }
        currentPID = pid
        textView.string = drafts[pid] ?? ""
        liveDictated = draftsDictated[pid] ?? false
        refreshDictateButton()
        textView.suggestion = nil
        clearGrammar() // the previous session's suggestions don't apply to this draft
        selectPicker(pid)
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        // Re-review the draft we just switched to (no-op if it's empty).
        if !textView.string.isEmpty { updateGrammar() }
    }

    private func selectPicker(_ pid: pid_t) {
        if let item = sessionPicker.itemArray.first(where: {
            ($0.representedObject as? NSNumber)?.int32Value == pid
        }) {
            sessionPicker.select(item)
        }
    }

    /// Poll Warp's focused tab; follow it only when the title actually changes,
    /// so a manual dropdown pick isn't immediately overridden by the poll.
    @objc private func followTick() {
        let title = WarpInspector.focusedWindowTitle()
        guard title != lastWarpTitle else { return }
        lastWarpTitle = title
        guard let title, let pid = sessionMatching(warpTitle: title) else { return }
        switchTo(pid)
    }

    /// Match Warp's window title to a session. Warp prettifies titles — it
    /// inserts spaces at camelCase boundaries and changes case ("MyProject" →
    /// "My Project", "PhotoBox" → "Photo Box") — so we compare a normalized
    /// form (letters/digits only, lowercased) against the cwd basename first,
    /// then any ancestor path component.
    private func sessionMatching(warpTitle: String) -> pid_t? {
        let t = Self.normalize(warpTitle)
        guard !t.isEmpty else { return nil }
        if let s = sessions.first(where: {
            guard let cwd = $0.cwd else { return false }
            return Self.normalize((cwd as NSString).lastPathComponent) == t
        }) { return s.pid }
        if let s = sessions.first(where: {
            guard let cwd = $0.cwd else { return false }
            return (cwd as NSString).pathComponents.contains { Self.normalize($0) == t }
        }) { return s.pid }
        return nil
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// PascalCase display name for a session — its cwd folder, or the tty if the
    /// cwd is unknown. When the leaf folder is a lower-cased variant of an
    /// ancestor (e.g. ".../PhotoBox/Code/photobox"), we borrow the ancestor's
    /// better casing so the name reads as the real project ("PhotoBox").
    private static func sessionName(for s: ClaudeSession) -> String {
        guard let cwd = s.cwd, !cwd.isEmpty else {
            return (s.ttyPath as NSString).lastPathComponent
        }
        let components = (cwd as NSString).pathComponents
        let leaf = components.last ?? (cwd as NSString).lastPathComponent
        let key = normalize(leaf)
        // Among path components naming the same thing, prefer the best-cased one.
        let sameName = components.filter { normalize($0) == key }
        let best = sameName.max(by: { upperCount($0) < upperCount($1) }) ?? leaf
        return pascalCase(best)
    }

    private static func upperCount(_ s: String) -> Int {
        s.filter { $0.isUppercase }.count
    }

    /// "my-project" / "my_project" / "myProject" → "MyProject". Existing internal
    /// capitals are preserved, so an already-PascalCase name is left unchanged.
    private static func pascalCase(_ name: String) -> String {
        let chunks = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return chunks.map { chunk -> String in
            guard let first = chunk.first else { return "" }
            return first.uppercased() + chunk.dropFirst()
        }.joined()
    }

    private func startFollowTimer() {
        followTimer?.invalidate()
        let t = Timer.scheduledTimer(timeInterval: 0.4, target: self,
                                     selector: #selector(followTick),
                                     userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common) // keep firing during UI tracking
        followTimer = t
    }

    private func stopFollowTimer() {
        followTimer?.invalidate()
        followTimer = nil
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
        // If the send failed (e.g. Warp not running), keep the text and the
        // window so the user doesn't lose their prompt.
        guard onSubmit?(text, liveDictated) == true else { return }
        clear()
        if keepOpen {
            // The send activates Warp; re-focus the composer once it has landed
            // so the next prompt can be typed right away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.makeKeyAndOrderFront(nil)
                self.makeFirstResponder(self.textView)
            }
        } else {
            hide()
        }
    }

    @objc private func keepOpenToggled(_ sender: NSButton) {
        keepOpen = (sender.state == .on)
        makeFirstResponder(textView) // keep typing focus after clicking the box
    }

    @objc private func startDictationClicked() {
        // startDictation: is the selector the system dictation shortcut invokes;
        // calling it on the focused text view starts Apple dictation in the box.
        // Mark this draft as dictated so the send carries the ;;v voice marker and
        // the observer runs its dictation-misrecognition + naturalness analysis.
        liveDictated = true
        refreshDictateButton()
        makeFirstResponder(textView)
        textView.perform(Selector(("startDictation:")), with: nil)
    }

    /// Sync the mic button tint with the dictated state — it glows accent when the
    /// current draft will be sent as voice (;;v), neutral otherwise.
    private func refreshDictateButton() {
        dictateButton.contentTintColor = liveDictated ? .controlAccentColor : .tertiaryLabelColor
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
            // Shift+Return must insert a newline, NOT submit. In this text view
            // Shift+Return arrives as insertNewline: — the SAME selector as a
            // plain Return (it isn't given a distinct insertLineBreak: binding) —
            // so we disambiguate via the triggering event's modifier flags.
            ghost?.suggestion = nil
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            }
            onSubmit?()
            return true
        case #selector(NSResponder.insertLineBreak(_:)):
            // Kept in case a key-binding config does route Shift+Return here;
            // behaves identically (insert a newline).
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
