import AppKit

final class ComposerWindow: NSWindow, NSMenuDelegate {
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
    /// On-demand English coaching (⌘K) via Codex or Claude, shown in its own panel below
    /// the grammar suggestions. Scrolls when the coaching runs long.
    private let coach = EnglishCoach()
    private enum CoachState {
        case loading(draft: String, deep: Bool)
        case result(CoachResult, draft: String)
        case failed(String)
    }
    private var coachState: CoachState?
    /// The latest ⌘K check per session that hasn't been sent or copied yet.
    /// Logged as unsent once its draft is abandoned; dropped on send/copy.
    private var unsentChecks: [pid_t: ComposerSend] = [:]
    private var coachTask: Task<Void, Never>?
    private let coachScroll = NSScrollView()
    private let coachStack = NSStackView()
    private var coachPanelHeight: NSLayoutConstraint!
    private var coachExtraHeight: CGFloat = 0
    private static let coachMaxHeight: CGFloat = 360
    private static let defaultHint = "↵ send   ⌘K check English   ⇧↵ newline   ⎋ close"
    private static let debug = ProcessInfo.processInfo.environment["TYPEFLOW_DEBUG"] == "1"
    private let sessionLabel = NSTextField(labelWithString: "→ no Claude Code session")
    private let hintLabel = NSTextField(labelWithString: ComposerWindow.defaultHint)
    private let keepOpenCheckbox = NSButton(checkboxWithTitle: "keep open", target: nil, action: nil)
    /// Picks who runs ⌘K: Codex · Luna, or a Claude account + model.
    private let coachPicker = NSPopUpButton(frame: .zero, pullsDown: true)
    private let dictateButton = NSButton()
    /// Returns true if the send succeeded; on false the composer keeps its text.
    private var onSubmit: ((ComposerSend) -> Bool)?
    private let textDelegate = ComposerTextDelegate()

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
    /// the send carries the ;;v marker, so wingman-english reads it as spoken
    /// (misrecognition, not grammar). Conservative: once the mic
    /// is used for a draft, the whole send is treated as voice.
    private var draftsDictated: [pid_t: Bool] = [:]
    /// Live dictated flag for the visible draft (mirrors draftsDictated[currentPID],
    /// the way textView.string mirrors drafts[currentPID]).
    private var liveDictated = false
    private var currentPID: pid_t?
    /// Last-seen Warp focused-window title. We re-follow only on a real change,
    /// so a manual dropdown pick isn't immediately overridden by the poll.
    private var lastWarpTitle: String?
    /// Custom Warp tab names (from Warp's session DB) for sessions we've seen in
    /// the front tab — the footer shows these instead of the folder name.
    private var tabNames: [pid_t: String] = [:]
    private var followTimer: Timer?

    init(onSubmit: @escaping (ComposerSend) -> Bool) {
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
        // .moveToActiveSpace (not .canJoinAllSpaces): keep the floating level so the
        // composer stays above other windows, but show it ONLY on the desktop the
        // user is working on — invoking ⌥Space brings it to the current Space, and
        // switching to another Space doesn't reveal a stray TypeFlow window there.
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
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
        textDelegate.onCancel = { [weak self] in self?.handleEscape() }
        textDelegate.onSubmitOriginal = { [weak self] in self?.submitOriginal() }
        textDelegate.isCoachShowing = { [weak self] in self?.coachState != nil }
        textDelegate.onTextChanged = { [weak self] in self?.handleTextChange() }
        textDelegate.onSelectionChanged = { [weak self] in self?.clearGhostIfCaretMoved() }
        textView.delegate = textDelegate
        textView.onTypingIntoEmpty = { [weak self] in
            guard let self, self.liveDictated else { return }
            self.liveDictated = false
            self.refreshDictateButton()
        }

        // Footer
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false

        // Read-only indicator of the session we're on — i.e. the frontmost Warp
        // tab the send will land in. Not interactive: routing is "the tab you have
        // focused in Warp", so the label just confirms you're on the right one.
        sessionLabel.translatesAutoresizingMaskIntoConstraints = false
        sessionLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        sessionLabel.textColor = .secondaryLabelColor
        sessionLabel.lineBreakMode = .byTruncatingTail
        sessionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = .tertiaryLabelColor

        keepOpenCheckbox.translatesAutoresizingMaskIntoConstraints = false
        keepOpenCheckbox.controlSize = .small
        keepOpenCheckbox.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        keepOpenCheckbox.target = self
        keepOpenCheckbox.action = #selector(keepOpenToggled(_:))
        keepOpenCheckbox.state = keepOpen ? .on : .off
        keepOpenCheckbox.toolTip = "Sending (↵) or copying (⌘⇧C) clears the draft without closing the composer"

        coachPicker.translatesAutoresizingMaskIntoConstraints = false
        coachPicker.isBordered = false
        coachPicker.controlSize = .small
        coachPicker.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        coachPicker.contentTintColor = .secondaryLabelColor
        coachPicker.toolTip = "Model for ⌘K checks"
        coachPicker.menu?.delegate = self // rebuilt on open: Claude logins can change
        refreshCoachPicker()

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

        // Coaching panel: a scrollable vertical stack (flipped document view so
        // content pins to the top), hidden until ⌘K.
        coachStack.orientation = .vertical
        coachStack.alignment = .leading
        coachStack.spacing = 6
        coachStack.translatesAutoresizingMaskIntoConstraints = false
        let coachDoc = FlippedView()
        coachDoc.translatesAutoresizingMaskIntoConstraints = false
        coachDoc.addSubview(coachStack)
        coachScroll.translatesAutoresizingMaskIntoConstraints = false
        coachScroll.drawsBackground = false
        coachScroll.hasVerticalScroller = true
        coachScroll.autohidesScrollers = true
        coachScroll.borderType = .noBorder
        coachScroll.documentView = coachDoc
        coachScroll.isHidden = true
        NSLayoutConstraint.activate([
            coachDoc.leadingAnchor.constraint(equalTo: coachScroll.contentView.leadingAnchor),
            coachDoc.trailingAnchor.constraint(equalTo: coachScroll.contentView.trailingAnchor),
            coachDoc.topAnchor.constraint(equalTo: coachScroll.contentView.topAnchor),
            coachStack.leadingAnchor.constraint(equalTo: coachDoc.leadingAnchor),
            coachStack.trailingAnchor.constraint(equalTo: coachDoc.trailingAnchor),
            coachStack.topAnchor.constraint(equalTo: coachDoc.topAnchor),
            coachStack.bottomAnchor.constraint(equalTo: coachDoc.bottomAnchor),
        ])

        footer.addSubview(sessionLabel)
        footer.addSubview(hintLabel)
        footer.addSubview(keepOpenCheckbox)
        footer.addSubview(dictateButton)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let container: NSView = blur
        container.addSubview(scroll)
        container.addSubview(grammarPanel)
        container.addSubview(coachScroll)
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
        // The coach picker shares the header row with × — the footer has no room
        // once the coach's longer hints show.
        container.addSubview(coachPicker)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            coachPicker.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            coachPicker.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
        ])

        // The text area prefers a fixed height (priority high, not required, so a
        // manual vertical window-resize can still stretch it). Without this the
        // scroll view is the only unconstrained element in the vertical chain and
        // greedily absorbs the window growth meant for the grammar panel —
        // collapsing the panel to height 0 (the bug that hid the suggestions).
        let scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 140)
        scrollHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 30), // below the header row
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollHeight,
            scroll.bottomAnchor.constraint(equalTo: grammarPanel.topAnchor, constant: -8),

            grammarPanel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grammarPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            grammarPanel.bottomAnchor.constraint(equalTo: coachScroll.topAnchor),

            coachScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            coachScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            coachScroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -10),

            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            separator.heightAnchor.constraint(equalToConstant: 1),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            footer.heightAnchor.constraint(equalToConstant: 18),

            sessionLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            sessionLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            sessionLabel.trailingAnchor.constraint(lessThanOrEqualTo: dictateButton.leadingAnchor, constant: -8),
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
        coachPanelHeight = coachScroll.heightAnchor.constraint(equalToConstant: 0)
        coachPanelHeight.isActive = true
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
        refreshCoachPicker()
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
        dismissCoach()
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
        dismissCoach()
        // Dictation mode stays on across sends; typing into the empty box turns it off.
        if let cur = currentPID { drafts[cur] = ""; draftsDictated[cur] = liveDictated } // the prompt was sent
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
        dismissCoach() // coaching describes the old text; editing returns to the draft
        if textView.string.isEmpty { flushUnsentCheck(for: currentPID ?? 0) } // draft abandoned
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
            guard let self, self.textView.string == text, self.coachState == nil else { return } // ignore stale
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
        growWindow(by: delta)
        if Self.debug {
            fputs("TypeFlow: setPanelHeight h=\(h) delta=\(delta) frameH=\(frame.size.height) panelFrame=\(grammarPanel.frame)\n", stderr)
        }
    }

    /// Grow (or shrink) the window downward, keeping the top edge fixed.
    private func growWindow(by delta: CGFloat) {
        var f = frame
        f.size.height += delta
        f.origin.y -= delta
        setFrame(f, display: true)
        contentView?.layoutSubtreeIfNeeded()
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
        for pid in unsentChecks.keys where pid != 0 && !alive.contains(pid) { flushUnsentCheck(for: pid) }
        drafts = drafts.filter { alive.contains($0.key) }
        tabNames = tabNames.filter { alive.contains($0.key) }
        draftsDictated = draftsDictated.filter { alive.contains($0.key) }
        if let cur = currentPID, !alive.contains(cur) { currentPID = nil }

        guard !sessions.isEmpty else {
            currentPID = nil
            updateSessionLabel(targetPID: nil)
            return
        }
        // A newly-spawned session becomes the current one — running `claude` in
        // a terminal should focus that session here, just like a new terminal
        // tab takes focus. `sorted` is newest-first, so this is the newest pid we
        // hadn't seen before. Per-session drafts mean the switch loses no input;
        // shouldAutoFocus only holds off while the user is mid-draft.
        let sorted = sessions.sorted(by: { $0.startTime > $1.startTime })
        let newSession = sorted.first { !previousPIDs.contains($0.pid) }
        if let newSession, shouldAutoFocus(newSession.pid) {
            switchTo(newSession.pid) // sets currentPID + refreshes the label
        } else if !isVisible {
            // While the composer is open, followTick owns the label (it tracks
            // the frontmost Warp tab — where the send actually lands). Writing it
            // here too would fight that 0.4s loop and flicker a wrong name when
            // the frontmost tab isn't the current session. Only set it when the
            // composer is closed, so it's correct the moment it opens.
            updateSessionLabel(targetPID: targetPID)
        }
    }

    /// Refresh the footer indicator to name the session we're on — `currentPID`
    /// if set, else the supplied target, else the newest. The tty is appended
    /// ONLY when two sessions share a folder, so the right one is identifiable.
    private func updateSessionLabel(targetPID: pid_t?) {
        guard !sessions.isEmpty else {
            sessionLabel.stringValue = "→ no Claude Code session"
            return
        }
        let grouped = Dictionary(grouping: sessions, by: { Self.sessionName(for: $0) })
        func label(for s: ClaudeSession) -> String {
            if let tabName = tabNames[s.pid] { return tabName }
            let name = Self.sessionName(for: s)
            if (grouped[name]?.count ?? 0) > 1 {
                return "\(name) (\((s.ttyPath as NSString).lastPathComponent))"
            }
            return name
        }
        let pid = currentPID ?? targetPID
        let session = sessions.first(where: { $0.pid == pid })
            ?? sessions.max(by: { $0.startTime < $1.startTime })
        guard let session else { return }
        sessionLabel.stringValue = "→ claude · \(label(for: session))"
    }

    /// Whether a newly-detected session should steal the composer's selection.
    /// We never yank the buffer out from under an in-progress draft in the open
    /// composer; otherwise (closed, or empty) the new session takes over.
    private func shouldAutoFocus(_ pid: pid_t) -> Bool {
        guard pid != currentPID else { return false }
        return !(isVisible && !textView.string.isEmpty)
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
        dismissCoach()
        updateSessionLabel(targetPID: pid)
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        // Re-review the draft we just switched to (no-op if it's empty).
        if !textView.string.isEmpty { updateGrammar() }
    }

    /// Poll Warp's focused tab; act only when the title actually changes. The send
    /// always lands in Warp's frontmost tab, so the footer mirrors that tab's
    /// title — even if it has no claude session — so the label always names where
    /// Enter will go. When the tab maps to a known claude session we also swap to
    /// that session's draft.
    @objc private func followTick() {
        let title = WarpInspector.focusedWindowTitle()
        // Prefer Warp's own record of the active tab: its cwd matches a session
        // exactly, and its custom name is what the user sees in the tab list.
        // claude rewrites the window title (spinner + summary), so the title is
        // only a fallback.
        let tab = WarpInspector.activeTab()
        // Re-resolve EVERY tick, not just when the title string changes: a new
        // `claude` session can start under an UNCHANGED Warp title (you switch to
        // a tab, then run claude in it). If we early-returned on an unchanged
        // title, the label would stay stuck on the raw tab name and never upgrade
        // to "claude · <name>" once the session appears. switchTo / setSessionLabel
        // are both idempotent, so re-running when nothing changed is a no-op.
        let matched = tab?.cwd.flatMap { sessionMatching(cwd: $0) }
            ?? title.flatMap { sessionMatching(warpTitle: $0) }
        let key = "\(tab?.name ?? "")|\(tab?.cwd ?? "")|\(title ?? "")"
        if Self.debug && key != lastWarpTitle {
            fputs("TypeFlow: followTick tab=\(tab?.name ?? "nil") cwd=\(tab?.cwd ?? "nil") warpTitle=\(title ?? "nil")\n", stderr)
        }
        lastWarpTitle = key
        if let pid = matched {
            tabNames[pid] = tab?.name
            switchTo(pid)
            updateSessionLabel(targetPID: pid) // switchTo is a no-op for the same pid; a rename still shows
        } else {
            setSessionLabel(warpTitle: tab?.name ?? title)
        }
    }

    /// Show where the send will land — the live Warp tab title — for a tab that
    /// doesn't map to a detected claude session. Keeps the footer honest about
    /// routing instead of leaving a stale name from the previous tab.
    private func setSessionLabel(warpTitle: String?) {
        if let t = warpTitle, !t.isEmpty {
            sessionLabel.stringValue = "→ \(t)"
        } else {
            updateSessionLabel(targetPID: nil)
        }
    }

    /// Match Warp's window title to a session. Warp prettifies titles — it
    /// inserts spaces at camelCase boundaries and changes case ("MyProject" →
    /// "My Project", "PhotoBox" → "Photo Box") — so we compare a normalized
    /// form (letters/digits only, lowercased) against the cwd basename first,
    /// then any ancestor path component.
    private func sessionMatching(warpTitle: String) -> pid_t? {
        let t = Self.normalize(warpTitle)
        guard !t.isEmpty else { return nil }
        // Basename match (tightest). Auto-follow only when EXACTLY one session's
        // folder matches the title; if two `claude` sessions share a folder the
        // title can't tell them apart, so we return nil and let the user's manual
        // dropdown pick stand instead of swapping to an arbitrary one.
        let byLeaf = sessions.filter {
            guard let cwd = $0.cwd else { return false }
            return Self.normalize((cwd as NSString).lastPathComponent) == t
        }
        if byLeaf.count > 1 { return nil }
        if let s = byLeaf.first { return s.pid }
        // Ancestor-path fallback, same one-or-none rule.
        let byAncestor = sessions.filter {
            guard let cwd = $0.cwd else { return false }
            return (cwd as NSString).pathComponents.contains { Self.normalize($0) == t }
        }
        if byAncestor.count > 1 { return nil }
        return byAncestor.first?.pid
    }

    /// Exact cwd match against the active Warp tab's pane. Two sessions in the
    /// same folder are ambiguous → nil (same one-or-none rule as titles).
    private func sessionMatching(cwd: String) -> pid_t? {
        let hits = sessions.filter { $0.cwd == cwd }
        return hits.count == 1 ? hits.first?.pid : nil
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

    // MARK: - English coach (⌘K)
    /// Debug only (`TYPEFLOW_DEMO_COACH=1`): open the composer with a canned coach
    /// result so the panel layout can be checked (and screenshotted) without a
    /// Codex call or a send.
    func showDemoCoach() {
        show()
        let draft = "give me a markdown with the information for this lesson. Don't add extra information."
        textView.string = draft
        let r = CoachResult(
            intent: "Ask for a Markdown document with this lesson's information, nothing extra.", score: 90,
            native: "Give me a Markdown document with the information for this lesson. Don’t add anything extra.",
            fixes: [
                CoachFix(original: "give", correction: "Give", reason: "capitalize first word",
                         category: "mechanics-punctuation-and-capitalization"),
                CoachFix(original: "a markdown", correction: "a Markdown document", reason: "name the thing",
                         category: "noun-phrase-structure"),
                CoachFix(original: "extra information", correction: "anything extra", reason: "natural phrasing",
                         category: "false-friends-and-calques"),
            ],
            why: "\"Markdown\" names the format; \"a Markdown document\" names the thing you want.",
            pattern: "Ask for the thing, then the format: \"a Markdown document\".", spanishTransfer: "")
        coachState = .result(r, draft: draft)
        renderCoach()
    }


    /// Ask the coach about the current draft. Runs only on demand — each check
    /// costs plan quota — and shows a loading row until the answer lands.
    /// ⌘K on a draft that already has a quick result re-checks it with the deeper
    /// (more natural, more expensive) model — the user decides when it's worth it.
    private func startCoach() {
        let draft = textView.string
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep(); return
        }
        var deep = false
        if case .result(let r, let d) = coachState, d == draft {
            guard !EnglishCoach.isDeep(r.model) else { NSSound.beep(); return } // already deep
            deep = true
        }
        textView.suggestion = nil
        ghostCompleter.cancel()
        clearGrammar() // the coach covers grammar too; one panel at a time
        coachTask?.cancel()
        coachState = .loading(draft: draft, deep: deep)
        renderCoach()
        coachTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.coach.check(draft, deep: deep)
                guard !Task.isCancelled, self.textView.string == draft else { return }
                self.coachState = .result(result, draft: draft)
                self.unsentChecks[self.currentPID ?? 0] = ComposerSend(
                    text: result.native,
                    draft: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                    dictated: self.liveDictated, coach: result, corrected: false,
                    cwd: self.sessions.first(where: { $0.pid == self.currentPID })?.cwd,
                    destination: .unsent)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.textView.string == draft else { return }
                self.coachState = .failed(error.localizedDescription)
            }
            self.renderCoach()
        }
    }

    /// Log a session's pending ⌘K check as unsent — its draft won't be sent.
    private func flushUnsentCheck(for pid: pid_t) {
        guard let check = unsentChecks.removeValue(forKey: pid) else { return }
        WingmanEnglishLog.record(check)
    }

    /// App quit: every pending check is abandoned.
    func flushUnsentChecks() {
        for pid in Array(unsentChecks.keys) { flushUnsentCheck(for: pid) }
    }

    private func dismissCoach() {
        guard coachState != nil || coachTask != nil else { return }
        coachTask?.cancel()
        coachTask = nil
        coach.cancel()
        coachState = nil
        renderCoach()
    }

    /// Rebuild the coaching panel for `coachState`, resize the window to fit, and
    /// swap the footer hint to the keys that apply right now.
    private func renderCoach() {
        coachStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width = max(200, frame.width - 40)
        var rows: [NSView] = []
        var hint = Self.defaultHint

        var removals: [(range: NSRange, slip: Bool)] = []
        switch coachState {
        case nil:
            break
        case .loading(_, let deep):
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let label = coachLabel(deep ? "Rewriting more naturally with \(CoachProvider.displayName(model: CoachProvider.current.deepModel))…" : "Checking your English with \(CoachProvider.displayName(model: CoachProvider.current.quickModel))…",
                                   size: 12, color: .secondaryLabelColor)
            let row = NSStackView(views: [spinner, label])
            row.spacing = 8
            rows.append(row)
            hint = "⌥↵ send without waiting   ⎋ cancel"
        case .failed(let message):
            rows.append(coachLabel("Couldn't check: \(message)", size: 12, color: .systemRed, width: width))
            hint = "↵ send   ⌘⇧C copy   ⌘K retry   ⎋ close panel"
        case .result(let r, let draft):
            rows += coachRows(r, draft: draft, width: width)
            if !r.isTranslation && !r.isClean { removals = TrackChanges.removedRanges(from: draft, to: r.native) }
            let deeper = EnglishCoach.isDeep(r.model) ? "" : "   ⌘K deeper"
            hint = r.isClean ? "↵ send   ⌘⇧C copy   ⎋ back to edit"
                : r.isTranslation ? "↵ send English   ⌥↵ mine   ⌘⇧C copy\(deeper)   ⎋ edit"
                : "↵ send corrected   ⌥↵ mine   ⌘⇧C copy\(deeper)   ⎋ edit"
        }

        textView.setCoachRemovals(removals) // cleared whenever there's no result
        for row in rows {
            coachStack.addArrangedSubview(row)
            // Full-width hairlines; constrained only once inside the stack (an
            // anchor pair with no common ancestor throws — see populateGrammarPanel).
            if row is SeparatorLine { row.widthAnchor.constraint(equalTo: coachStack.widthAnchor).isActive = true }
        }
        coachScroll.isHidden = rows.isEmpty
        hintLabel.stringValue = hint
        hintLabel.textColor = .tertiaryLabelColor // a pending "✓ Copied" flash ends here

        // Measure the stack at the panel's width, cap it, and grow the window.
        coachStack.layoutSubtreeIfNeeded()
        let content = rows.isEmpty ? 0
            : rows.reduce(0) { $0 + $1.fittingSize.height } + CGFloat(rows.count - 1) * coachStack.spacing
        let h = rows.isEmpty ? 0 : min(content + 4, Self.coachMaxHeight)
        let delta = h - coachExtraHeight
        if abs(delta) > 0.5 {
            coachExtraHeight = h
            coachPanelHeight.constant = h
            growWindow(by: delta)
        }
        coachScroll.documentView?.scroll(.zero)
    }

    /// The "track changes" layout: header (score + what the coach understood),
    /// the draft with its changes marked inline, one compact line per change,
    /// the learning line, and the plan's focus.
    private func coachRows(_ r: CoachResult, draft: String, width: CGFloat) -> [NSView] {
        var rows: [NSView] = []

        let header = NSMutableAttributedString()
        let scoreText = r.score.map { "\($0)/100" } ?? "Translation"
        // Neutral: green/yellow/red are reserved for the changes themselves.
        header.append(NSAttributedString(string: scoreText, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.labelColor]))
        let modelName = CoachProvider.displayName(model: r.model)
        if !modelName.isEmpty {
            let deeper = EnglishCoach.isDeep(r.model) ? ", deeper check" : ""
            header.append(NSAttributedString(string: "  · \(modelName)\(deeper)", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        if !r.intent.isEmpty {
            // The coach's reading of the draft — if it's wrong, the rewrite is too.
            header.append(NSAttributedString(string: "   Understood: " + r.intent, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        rows.append(attributedLabel(header, width: width))

        if r.isClean {
            rows.append(coachLabel("✓ Sounds natural. No changes needed.", size: 13, color: .systemGreen, width: width))
            return rows
        }

        // The draft is already in the text box above, with the coach's removals
        // marked there in red (see renderCoach). The panel opens with what Enter
        // sends: the corrected version, additions in green. A translation shares
        // no words with the Spanish, so it's shown plain.
        rows.append(SeparatorLine())
        rows.append(coachLabel(r.isTranslation ? "IN ENGLISH" : "CORRECTED", size: 10, weight: .semibold,
                               color: .tertiaryLabelColor))
        let sides = r.isTranslation ? nil : TrackChanges.sides(from: draft, to: r.native, size: 13)
        let corrected = sides.map { attributedLabel($0.corrected, width: width) }
            ?? coachLabel(r.native, size: 14, weight: .medium, color: .labelColor, width: width)
        corrected.isSelectable = true
        rows.append(corrected)

        // Plan + history from wingman-english's vault (local files, no model call).
        let insights = CoachInsights.snapshot()
        if !r.fixes.isEmpty {
            rows.append(SeparatorLine())
            rows.append(coachLabel("CHANGES", size: 10, weight: .semibold, color: .tertiaryLabelColor))
            var seenNow: [String: Int] = [:]
            for fix in r.fixes.prefix(8) {
                // A severity dot (red mistake / yellow slip); the text itself stays neutral.
                let slip = TrackChanges.slipCategories.contains(fix.category)
                let str = NSMutableAttributedString(string: "● ", attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: slip ? TrackChanges.slipColor : NSColor.systemRed])
                if fix.correction.isEmpty {
                    str.append(NSAttributedString(string: fix.original, attributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue]))
                } else {
                    str.append(NSAttributedString(string: fix.correction, attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]))
                }
                str.append(NSAttributedString(string: "    \(fix.reason) · \(CoachInsights.label(fix.category))", attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
                if let insights {
                    seenNow[fix.category, default: 0] += 1
                    var badges: [String] = []
                    if insights.targetForms.contains(fix.category) { badges.append("🎯") }
                    let total = insights.weekCounts[fix.category, default: 0] + seenNow[fix.category]!
                    if total >= CoachInsights.repeatThreshold, fix.category != "l1-switch" {
                        badges.append("↻ \(CoachInsights.ordinal(total)) this week")
                    }
                    if !badges.isEmpty {
                        str.append(NSAttributedString(string: "    " + badges.joined(separator: "  "), attributes: [
                            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.systemPurple]))
                    }
                }
                rows.append(attributedLabel(str, width: width))
            }
        }

        if !r.pattern.isEmpty || !r.why.isEmpty || !r.spanishTransfer.isEmpty {
            rows.append(SeparatorLine())
            if !r.pattern.isEmpty {
                rows.append(coachLabel("💡 " + r.pattern, size: 13, weight: .semibold, color: .labelColor, width: width))
            }
            if !r.why.isEmpty {
                rows.append(coachLabel(r.why, size: 12, color: .secondaryLabelColor, width: width))
            }
            if !r.spanishTransfer.isEmpty {
                rows.append(coachLabel("From Spanish: " + r.spanishTransfer, size: 11,
                                       color: .tertiaryLabelColor, width: width))
            }
        }
        if let insights, !insights.targetForms.isEmpty {
            let forms = insights.targetForms.map { insights.qualifiers[$0] ?? CoachInsights.label($0) }
                .joined(separator: " · ")
            rows.append(coachLabel("🎯 Focus\(insights.planIsDraft ? " (draft plan)" : ""): " + forms,
                                   size: 11, color: .systemPurple, width: width))
        }
        return rows
    }

    private func attributedLabel(_ text: NSAttributedString, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = text
        label.isSelectable = false
        label.preferredMaxLayoutWidth = width
        return label
    }

    private func coachLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                            color: NSColor, width: CGFloat? = nil) -> NSTextField {
        let label = width == nil ? NSTextField(labelWithString: text)
                                 : NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.isSelectable = false
        if let width { label.preferredMaxLayoutWidth = width }
        return label
    }

    // MARK: - Keyboard

    /// Enter submission goes through ComposerTextDelegate; Escape is handled
    /// here because the text view doesn't intercept it.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            handleEscape()
            return
        }
        super.keyDown(with: event)
    }

    /// ⌘K → check the draft with the English coach.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "k" {
            startCoach()
            return true
        }
        if mods == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c" {
            copyForElsewhere()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc closes the coaching panel first (back to editing); otherwise the composer.
    private func handleEscape() {
        if coachState != nil {
            dismissCoach()
            makeFirstResponder(textView)
        } else {
            hide()
        }
    }

    /// Enter. With a coaching result showing, sends the native-US version (or the
    /// draft itself when the coach found nothing to fix). While a check is still
    /// running, Enter waits — ⌥↵ sends the draft as-is without waiting.
    @objc func submit() {
        switch coachState {
        case .loading:
            NSSound.beep()
        case .result(let r, let draft) where draft == textView.string && !r.isClean:
            send(r.native, coach: r, corrected: true)
        default:
            send(textView.string, coach: currentCoachResult, corrected: false)
        }
    }

    /// ⌥Enter while coaching: send the draft exactly as written.
    private func submitOriginal() {
        send(textView.string, coach: currentCoachResult, corrected: false)
    }

    /// ⌘⇧C: put the text on the clipboard instead of sending it to Claude — for a
    /// quick correction to paste into another app. Same choice as Enter (the
    /// coach's version when there's a correction, else the draft). Like a send,
    /// the draft clears; with "keep open" on the composer stays up for the next
    /// one, otherwise it closes so focus returns to the previous app.
    private func copyForElsewhere() {
        let (raw, coach, corrected): (String, CoachResult?, Bool)
        switch coachState {
        case .loading:
            NSSound.beep(); return
        case .result(let r, let draft) where draft == textView.string && !r.isClean:
            (raw, coach, corrected) = (r.native, r, true)
        default:
            (raw, coach, corrected) = (textView.string, currentCoachResult, false)
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        WingmanEnglishLog.record(ComposerSend(
            text: text,
            draft: textView.string.trimmingCharacters(in: .whitespacesAndNewlines),
            dictated: liveDictated, coach: coach, corrected: corrected,
            cwd: nil, destination: .clipboard))
        unsentChecks[currentPID ?? 0] = nil
        clear()
        if keepOpen {
            makeFirstResponder(textView)
            flashHint("✓ Copied — paste it anywhere with ⌘V")
        } else {
            hide()
        }
    }

    /// Briefly replace the footer hint with a confirmation, then restore it.
    private func flashHint(_ message: String) {
        hintLabel.stringValue = message
        hintLabel.textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.hintLabel.stringValue == message else { return }
            self.hintLabel.textColor = .tertiaryLabelColor
            self.hintLabel.stringValue = Self.defaultHint
        }
    }

    /// The coach's result, if it was computed for exactly the visible draft.
    private var currentCoachResult: CoachResult? {
        if case .result(let r, let draft) = coachState, draft == textView.string { return r }
        return nil
    }

    private func send(_ raw: String, coach: CoachResult?, corrected: Bool) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        let send = ComposerSend(
            text: text,
            draft: textView.string.trimmingCharacters(in: .whitespacesAndNewlines),
            dictated: liveDictated, coach: coach, corrected: corrected,
            cwd: sessions.first(where: { $0.pid == currentPID })?.cwd)
        // If the send failed (e.g. Warp not running), keep the text and the
        // window so the user doesn't lose their prompt.
        guard onSubmit?(send) == true else { return }
        unsentChecks[currentPID ?? 0] = nil
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

    // MARK: - Coach picker

    /// A pull-down's first item is its title; the rest is the menu: one section
    /// per provider/account, one row per model, each row a complete choice.
    private func refreshCoachPicker() {
        let menu = coachPicker.menu!
        menu.removeAllItems()
        let current = CoachProvider.current
        menu.addItem(withTitle: "⌘K  " + current.shortLabel, action: nil, keyEquivalent: "")

        func section(_ title: String, _ choices: [CoachProvider]) {
            if menu.items.count > 1 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: title))
            for choice in choices {
                let item = menu.addItem(withTitle: choice.menuTitle,
                                        action: #selector(pickCoachProvider(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = choice
                item.subtitle = choice.menuSubtitle
                item.state = choice == current ? .on : .off
            }
        }
        section("Codex — ChatGPT plan", [.codex])

        var accounts = CoachProvider.claudeAccounts()
        if case .claude(let a, _) = current, !accounts.contains(a) { accounts.append(a) } // since removed
        for a in accounts {
            section("Claude — \(a)", CoachProvider.ClaudeModel.allCases.map { .claude(account: a, model: $0) })
        }
        if CoachProvider.antigravityInstalled || current == .antigravity {
            section("Antigravity — Google", [.antigravity])
        }
    }

    @objc private func pickCoachProvider(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? CoachProvider else { return }
        CoachProvider.current = provider
        refreshCoachPicker()
        makeFirstResponder(textView)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === coachPicker.menu { refreshCoachPicker() }
    }

    @objc private func keepOpenToggled(_ sender: NSButton) {
        keepOpen = (sender.state == .on)
        makeFirstResponder(textView) // keep typing focus after clicking the box
    }

    @objc private func startDictationClicked() {
        // startDictation: is the selector the system dictation shortcut invokes;
        // calling it on the focused text view starts Apple dictation in the box.
        // Mark this draft as dictated so the send carries the ;;v marker and
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
///   - Option+Return → while coaching, send the draft as written
///   - Escape       → dismiss ghost, else close coaching, else close the composer
///
/// Escape needs explicit handling because NSTextView normally maps it to
/// `cancelOperation:` (used to dismiss completion popups) and swallows the
/// event before it can reach the window's keyDown override.
/// Document view for the coaching scroll view — flipped so content pins to the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class ComposerTextDelegate: NSObject, NSTextViewDelegate {
    var onSubmit: (() -> Void)?
    /// ⌥Return while the coaching panel is up: send the draft as written.
    var onSubmitOriginal: (() -> Void)?
    var isCoachShowing: (() -> Bool)?
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
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            if mods.contains(.shift) {
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            }
            if mods.contains(.option), isCoachShowing?() == true {
                onSubmitOriginal?()
                return true
            }
            onSubmit?()
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // ⌥Return arrives here. While coaching it means "send mine";
            // otherwise keep the default (insert a newline).
            guard isCoachShowing?() == true else { return false }
            ghost?.suggestion = nil
            onSubmitOriginal?()
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
