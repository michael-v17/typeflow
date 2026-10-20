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
    /// Other sessions' ⌘K results, parked while their draft is out of view (the
    /// visible one is `coachState`). A correction stays through edits, tab
    /// switches and hides — until the next ⌘K, a send or copy, an emptied draft or ⎋.
    private var coachStates: [pid_t: CoachState] = [:]
    /// The latest ⌘K check per session that hasn't been sent or copied yet.
    /// Logged as unsent once its draft is abandoned; dropped on send/copy.
    private var unsentChecks: [pid_t: ComposerSend] = [:]
    private var coachTask: Task<Void, Never>?
    private let coachScroll = NSScrollView()
    private let coachStack = NSStackView()
    private var coachPanelHeight: NSLayoutConstraint!
    /// The text area's height — the base the panels add to. It hugs the draft
    /// (`fitTextHeight`): 3 lines when empty, up to `maxTextHeight`, then it scrolls.
    private var scrollHeight: NSLayoutConstraint!
    private static let widthKey = "TypeFlowComposerWidth"
    private static let textHeightKey = "TypeFlowComposerTextHeight"
    private static var savedTextHeight: CGFloat {
        let h = UserDefaults.standard.double(forKey: textHeightKey)
        return h > 0 ? h : 200
    }
    /// How tall the text area may grow. A vertical drag of the window sets it,
    /// remembered with the width (`rememberSize`).
    private var maxTextHeight: CGFloat = 200
    /// The text area's height when a live resize began, to tell a vertical drag
    /// from a width-only one.
    private var resizeStartTextHeight: CGFloat = 0
    private var coachExtraHeight: CGFloat = 0
    private static let coachMaxHeight: CGFloat = 360
    private static let defaultHint = "↵ send   ⌘K check English"
    /// The resting hint: the two main keys only; the full list is in the ⋯ menu.
    /// With a message to answer, ⌘K suggests a reply instead.
    private var idleHint: String {
        "↵ \(enterVerb)   ⌘K \(liveContext == nil ? "check English" : "suggest reply")"
    }
    /// What Enter does right now: send into Warp, or copy (terminal mode off).
    private var enterVerb: String { terminalMode ? "send" : "copy" }
    private static let debug = ProcessInfo.processInfo.environment["TYPEFLOW_DEBUG"] == "1"
    private let sessionLabel = NSTextField(labelWithString: "→ no Claude Code session")
    /// Footer pill: where Enter goes — Warp (terminal mode) or the clipboard. ⌘T.
    private let modeButton = NSButton()
    /// Footer `EN` / `ES`: the draft's detected language. Click to switch and lock it.
    private let langButton = NSButton()
    private var draftLanguage: DraftLanguage = .english
    /// Set by a click on `langButton`: detection stops until the draft is sent,
    /// copied or swapped for another session's.
    private var languageLocked = false
    private let hintLabel = NSTextField(labelWithString: ComposerWindow.defaultHint)
    /// Header ⋯: keep open, all desktops, Warp/Copy and the full shortcut list.
    private let moreButton = NSButton()
    /// Picks who runs ⌘K: Codex · Luna, or a Claude account + model.
    private let coachPicker = NSPopUpButton(frame: .zero, pullsDown: true)
    private let dictateButton = NSButton()
    /// ▶ / ⌥⌘S: read aloud what Enter would send; ■ while it reads.
    private let speakButton = NSButton()
    private let speaker = Speaker()
    /// Reply mode: the message being answered (⌘⇧V from the clipboard). With one
    /// set, ⌘K suggests a reply built from the draft's idea. Per session, like the
    /// draft; cleared on send. Never logged.
    private struct ReplyContext {
        enum Source: String { case text = "pasted text", screenshot }
        /// For a screenshot: what Vision read, shown in the box (may be empty).
        let text: String
        let source: Source
        /// A screenshot goes to the coach as an image too (PNG), so a diagram or a
        /// UI is understood, not just its words.
        var image: Data? = nil
    }
    private var contexts: [pid_t: ReplyContext] = [:]
    /// The visible session's context (mirrors contexts[currentPID], like liveDictated).
    private var liveContext: ReplyContext?
    private let replyButton = NSButton()
    private let contextBox = NSView()
    private let contextTitle = NSTextField(labelWithString: "")
    private let contextScroll = NSScrollView()
    private let contextText = NSTextView()
    private var contextHeight: NSLayoutConstraint!
    private var contextGap: NSLayoutConstraint!
    private var contextExtraHeight: CGFloat = 0
    private static let contextMaxTextHeight: CGFloat = 90
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

    private static let allDesktopsKey = "TypeFlowAllDesktops"
    /// On: the composer is on every desktop (Space) and stays where it was put —
    /// switching desktops leaves it in place, and ⌥Space doesn't re-center it.
    /// Persisted; default off.
    private var allDesktops: Bool {
        get { UserDefaults.standard.bool(forKey: Self.allDesktopsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.allDesktopsKey) }
    }

    private static let terminalModeKey = "TypeFlowTerminalMode"
    /// On: Enter sends into Warp's frontmost tab. Off: the composer is just a
    /// correction box — Enter copies (like ⌘⇧C) and nothing ever touches Warp,
    /// for writing a chat message elsewhere. Persisted; default on.
    private var terminalMode: Bool {
        get { (UserDefaults.standard.object(forKey: Self.terminalModeKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.terminalModeKey) }
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
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 300),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configureWindow()
        hideTitleBarChrome()
        buildContent()
        restoreSize()
        center()
        NotificationCenter.default.addObserver(self, selector: #selector(noteResizeStart),
                                               name: NSWindow.willStartLiveResizeNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(rememberSize),
                                               name: NSWindow.didEndLiveResizeNotification, object: self)
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
        applyDesktopBehavior()
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .utilityWindow
        minSize = NSSize(width: 560, height: 220)
    }

    private var textHeight: CGFloat { textView.enclosingScrollView?.frame.height ?? scrollHeight.constant }

    /// The text area's floor: 3 lines, so an empty draft doesn't take half the screen.
    private var minTextHeight: CGFloat {
        let font = textView.font ?? NSFont.systemFont(ofSize: 16)
        return ceil(NSLayoutManager().defaultLineHeight(for: font) * 3 + textView.textContainerInset.height * 2)
    }

    /// The draft's laid-out height, insets included.
    private var draftHeight: CGFloat {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return minTextHeight }
        lm.ensureLayout(for: tc)
        return ceil(lm.usedRect(for: tc).height + textView.textContainerInset.height * 2)
    }

    /// Open at the remembered width with the empty draft's 3 lines; the
    /// remembered text height is how far it grows. Clamped to the screen.
    private func restoreSize() {
        contentView?.layoutSubtreeIfNeeded()
        let chrome = frame.height - textHeight
        let saved = UserDefaults.standard.double(forKey: Self.widthKey)
        let visible = (screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let width = min(max(saved > 0 ? saved : 760, minSize.width), visible.width - 40)
        maxTextHeight = max(min(Self.savedTextHeight, visible.height - chrome - 120), minTextHeight)
        scrollHeight.constant = minTextHeight
        minSize.height = chrome + minTextHeight
        setContentSize(NSSize(width: width, height: chrome + scrollHeight.constant))
    }

    /// The text area hugs the draft: 3 lines when empty, a line more as it
    /// wraps, up to `maxTextHeight`, then it scrolls. Top edge fixed, like the panels.
    private func fitTextHeight() {
        guard !inLiveResize else { return } // the drag owns the size until it ends
        let content = draftHeight
        let target = min(max(content, minTextHeight), maxTextHeight)
        let delta = target - textHeight
        scrollHeight.constant = target
        if abs(delta) > 0.5 { growWindow(by: delta) }
        // It all fits: undo the scroll the text view made to show the caret.
        if content <= maxTextHeight, let scroll = textView.enclosingScrollView {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    @objc private func noteResizeStart() {
        resizeStartTextHeight = textHeight
    }

    /// After a manual resize: a vertical drag sets how far the text area grows,
    /// the width is kept, both remembered; then the text area fits the draft again.
    @objc private func rememberSize() {
        if abs(textHeight - resizeStartTextHeight) > 0.5 {
            maxTextHeight = max(textHeight, minTextHeight)
            UserDefaults.standard.set(maxTextHeight, forKey: Self.textHeightKey)
        }
        UserDefaults.standard.set(frame.width, forKey: Self.widthKey)
        fitTextHeight()
    }

    /// Default (.moveToActiveSpace): the composer floats above other windows but
    /// only on the desktop in use — ⌥Space brings it to the current Space, and
    /// another Space shows no stray TypeFlow window. "all desktops"
    /// (.canJoinAllSpaces): it's on every Space, so switching leaves it in place.
    private func applyDesktopBehavior() {
        collectionBehavior = [allDesktops ? .canJoinAllSpaces : .moveToActiveSpace,
                              .fullScreenAuxiliary, .transient]
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

        let initialSize = NSSize(width: 720, height: 200)
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

        modeButton.translatesAutoresizingMaskIntoConstraints = false
        modeButton.isBordered = false
        modeButton.bezelStyle = .accessoryBarAction
        modeButton.controlSize = .small
        modeButton.imagePosition = .imageLeading
        modeButton.target = self
        modeButton.action = #selector(toggleTerminalMode)
        modeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        langButton.translatesAutoresizingMaskIntoConstraints = false
        langButton.isBordered = false
        langButton.bezelStyle = .accessoryBarAction
        langButton.controlSize = .small
        langButton.target = self
        langButton.action = #selector(langButtonClicked)
        langButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        refreshLangButton()

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        // The session name gives way first, then the hint; the tool icons never do.
        hintLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)

        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.isBordered = false
        moreButton.bezelStyle = .accessoryBarAction
        moreButton.imagePosition = .imageOnly
        moreButton.image = NSImage(systemSymbolName: "ellipsis.circle",
                                   accessibilityDescription: "Options")
        moreButton.contentTintColor = .tertiaryLabelColor
        moreButton.toolTip = "Options and shortcuts"
        moreButton.target = self
        moreButton.action = #selector(showMoreMenu)

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
        dictateButton.toolTip = "Dictate (Apple dictation). Lit: this draft is sent as dictated (;;v); click to unmark"
        dictateButton.target = self
        dictateButton.action = #selector(startDictationClicked)

        speakButton.translatesAutoresizingMaskIntoConstraints = false
        speakButton.isBordered = false
        speakButton.bezelStyle = .accessoryBarAction
        speakButton.imagePosition = .imageOnly
        speakButton.image = NSImage(systemSymbolName: "play.fill",
                                    accessibilityDescription: "Read aloud")
        speakButton.contentTintColor = .tertiaryLabelColor
        speakButton.toolTip = "Read aloud (⌥⌘S): the correction if there is one, else the draft"
        speakButton.target = self
        speakButton.action = #selector(toggleSpeaking)

        speaker.onFinish = { [weak self] in self?.refreshSpeakButton() }

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

        footer.addSubview(modeButton)
        footer.addSubview(sessionLabel)
        footer.addSubview(hintLabel)
        footer.addSubview(dictateButton)
        footer.addSubview(langButton)
        footer.addSubview(speakButton)

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
        container.addSubview(moreButton)
        // Reply mode lives on the header row's left: the button that takes the
        // copied message, and under it the box showing that message.
        replyButton.translatesAutoresizingMaskIntoConstraints = false
        replyButton.isBordered = false
        replyButton.bezelStyle = .accessoryBarAction
        replyButton.controlSize = .small
        replyButton.image = NSImage(systemSymbolName: "arrowshape.turn.up.left",
                                    accessibilityDescription: "Reply to the copied message")
        replyButton.imagePosition = .imageLeading
        replyButton.attributedTitle = NSAttributedString(string: "Reply to copied message  ⌘⇧V", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        replyButton.contentTintColor = .secondaryLabelColor
        replyButton.toolTip = "Paste the message you're answering (text or a screenshot) — ⌘K then helps you reply to it"
        replyButton.target = self
        replyButton.action = #selector(pasteAsContext)
        container.addSubview(replyButton)
        buildContextBox()
        container.addSubview(contextBox)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            coachPicker.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            moreButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            moreButton.widthAnchor.constraint(equalToConstant: 18),
            moreButton.heightAnchor.constraint(equalToConstant: 18),
            coachPicker.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -6),
            replyButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            replyButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            replyButton.trailingAnchor.constraint(lessThanOrEqualTo: coachPicker.leadingAnchor, constant: -8),
            contextBox.topAnchor.constraint(equalTo: container.topAnchor, constant: 30),
            contextBox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            contextBox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])

        // The text area prefers a set height — the draft's (fitTextHeight) — at
        // priority high, not required, so a manual vertical window-resize can
        // still stretch it. Without this the
        // scroll view is the only unconstrained element in the vertical chain and
        // greedily absorbs the window growth meant for the grammar panel —
        // collapsing the panel to height 0 (the bug that hid the suggestions).
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: Self.savedTextHeight)
        scrollHeight.priority = .defaultHigh

        // Below the header row, or below the reply context when there is one.
        contextHeight = contextBox.heightAnchor.constraint(equalToConstant: 0)
        contextGap = scroll.topAnchor.constraint(equalTo: contextBox.bottomAnchor, constant: 0)
        NSLayoutConstraint.activate([
            contextHeight, contextGap,
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

            modeButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            modeButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            sessionLabel.leadingAnchor.constraint(equalTo: modeButton.trailingAnchor, constant: 6),
            sessionLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            sessionLabel.trailingAnchor.constraint(lessThanOrEqualTo: langButton.leadingAnchor, constant: -8),
            langButton.trailingAnchor.constraint(equalTo: speakButton.leadingAnchor, constant: -8),
            speakButton.trailingAnchor.constraint(equalTo: dictateButton.leadingAnchor, constant: -8),
            speakButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            speakButton.widthAnchor.constraint(equalToConstant: 16),
            speakButton.heightAnchor.constraint(equalToConstant: 16),
            langButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            dictateButton.trailingAnchor.constraint(equalTo: hintLabel.leadingAnchor, constant: -14),
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

    // MARK: - Reply context (⌘⇧V)

    /// "REPLYING TO · pasted text  ×" over the message, read-only and scrolling
    /// past a few lines. Zero height until a message is pasted.
    private func buildContextBox() {
        contextBox.translatesAutoresizingMaskIntoConstraints = false
        contextBox.wantsLayer = true
        contextBox.layer?.cornerRadius = 8
        contextBox.layer?.cornerCurve = .continuous
        contextBox.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        contextBox.isHidden = true

        contextTitle.translatesAutoresizingMaskIntoConstraints = false
        contextTitle.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        contextTitle.textColor = .tertiaryLabelColor
        contextTitle.lineBreakMode = .byTruncatingTail

        let remove = NSButton(title: "", target: self, action: #selector(removeContext))
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.isBordered = false
        remove.bezelStyle = .accessoryBarAction
        remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove the message")
        remove.imagePosition = .imageOnly
        remove.contentTintColor = .tertiaryLabelColor
        remove.toolTip = "Stop replying to this message"

        // Frame-based document view inside an autolayout scroll view, same as
        // the draft's text view (see buildContent).
        contextText.isEditable = false
        contextText.isSelectable = true
        contextText.isRichText = false
        contextText.drawsBackground = false
        contextText.font = NSFont.systemFont(ofSize: 12)
        contextText.textColor = .secondaryLabelColor
        contextText.textContainerInset = NSSize(width: 0, height: 2)
        contextText.isVerticallyResizable = true
        contextText.isHorizontallyResizable = false
        contextText.autoresizingMask = [.width]
        contextText.textContainer?.widthTracksTextView = true
        contextText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        contextScroll.translatesAutoresizingMaskIntoConstraints = false
        contextScroll.drawsBackground = false
        contextScroll.hasVerticalScroller = true
        contextScroll.autohidesScrollers = true
        contextScroll.borderType = .noBorder
        contextScroll.documentView = contextText

        contextBox.addSubview(contextTitle)
        contextBox.addSubview(remove)
        contextBox.addSubview(contextScroll)
        NSLayoutConstraint.activate([
            contextTitle.topAnchor.constraint(equalTo: contextBox.topAnchor, constant: 6),
            contextTitle.leadingAnchor.constraint(equalTo: contextBox.leadingAnchor, constant: 10),
            contextTitle.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -6),
            remove.centerYAnchor.constraint(equalTo: contextTitle.centerYAnchor),
            remove.trailingAnchor.constraint(equalTo: contextBox.trailingAnchor, constant: -6),
            remove.widthAnchor.constraint(equalToConstant: 14),
            remove.heightAnchor.constraint(equalToConstant: 14),
            contextScroll.topAnchor.constraint(equalTo: contextTitle.bottomAnchor, constant: 2),
            contextScroll.leadingAnchor.constraint(equalTo: contextBox.leadingAnchor, constant: 10),
            contextScroll.trailingAnchor.constraint(equalTo: contextBox.trailingAnchor, constant: -6),
            contextScroll.bottomAnchor.constraint(equalTo: contextBox.bottomAnchor, constant: -6),
        ])
    }

    /// ⌘⇧V / the header button: the clipboard's text becomes the message to answer.
    /// A screenshot (or a copied image file) is read on-device first.
    @objc private func pasteAsContext() {
        if ScreenText.clipboardIsImageOnly(), let image = ScreenText.clipboardImage() {
            readScreenshot(image)
            return
        }
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            NSSound.beep()
            flashHint("Copy the message you're answering first", color: .secondaryLabelColor)
            return
        }
        setContext(ReplyContext(text: text, source: .text))
        makeFirstResponder(textView)
    }

    /// OCR runs off the main thread (~0.5 s) to fill the box; the image itself
    /// goes to the coach too. The result lands only if the user is still on the
    /// same session.
    private func readScreenshot(_ image: CGImage) {
        let pid = currentPID
        hintLabel.stringValue = "Reading the screenshot…"
        hintLabel.textColor = .secondaryLabelColor
        Task { [weak self] in
            let text = (try? await ScreenText.recognize(image))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let png = ScreenText.uploadPNG(image)
            guard let self, self.currentPID == pid else { return }
            self.hintLabel.textColor = .tertiaryLabelColor
            self.hintLabel.stringValue = self.coachHint
            guard png != nil || !text.isEmpty else { NSSound.beep(); return }
            // No text is fine (a diagram, a photo): the coach still sees the image.
            self.setContext(ReplyContext(text: text, source: .screenshot, image: png))
            self.makeFirstResponder(self.textView)
        }
    }

    @objc private func removeContext() {
        setContext(nil)
        makeFirstResponder(textView)
    }

    /// A result was computed for the old context (or none), so it goes too.
    private func setContext(_ context: ReplyContext?) {
        liveContext = context
        dismissCoach()
        renderContext()
    }

    /// Show `liveContext` (or hide the box) and grow the window to fit, top edge fixed.
    private func renderContext() {
        var h: CGFloat = 0
        if let ctx = liveContext {
            let cut = ctx.text.count > EnglishCoach.contextLimit ? " · last \(EnglishCoach.contextLimit / 1000)k characters" : ""
            let sent = ctx.image != nil ? " · the coach sees the image" : ""
            contextTitle.stringValue = "REPLYING TO · \(ctx.source.rawValue)\(sent)\(cut)"
            contextText.string = ctx.text.isEmpty ? "(No text found. The coach will read the image.)" : ctx.text
            // Measure at the width the text will have once the box is laid out.
            let width = max(100, frame.width - 40 - 16)
            contextText.frame.size.width = width
            contextText.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            var textH: CGFloat = 16
            if let lm = contextText.layoutManager, let tc = contextText.textContainer {
                lm.ensureLayout(for: tc)
                textH = lm.usedRect(for: tc).height + 4
            }
            h = min(textH, Self.contextMaxTextHeight) + 28 // title + paddings
            contextText.scroll(.zero)
        }
        contextBox.isHidden = liveContext == nil
        if coachState == nil { hintLabel.stringValue = idleHint }
        contextHeight.constant = h
        contextGap.constant = h > 0 ? 8 : 0
        let total = h > 0 ? h + 8 : 0
        let delta = total - contextExtraHeight
        if abs(delta) > 0.5 {
            contextExtraHeight = total
            growWindow(by: delta)
        }
    }

    // MARK: - Behavior

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        if !allDesktops { center() } // on all desktops it stays where it was put
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        makeFirstResponder(textView)
        onShow?() // boost the session poll while we're open
        refreshCoachPicker()
        refreshTerminalMode()
    }

    func hide() {
        speaker.stop()
        stopFollowTimer()
        onHide?() // drop the session poll back to idle cadence
        if let cur = currentPID { // preserve draft
            drafts[cur] = textView.string; draftsDictated[cur] = liveDictated; contexts[cur] = liveContext
        }
        textView.suggestion = nil
        ghostCompleter.cancel()
        clearGrammar()
        if !showsCoachResult { dismissCoach() } // a correction waits for the composer to come back
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
        fitTextHeight()
        languageLocked = false
        refreshDraftLanguage()
        textView.suggestion = nil
        clearGrammar() // the sent prompt's suggestions don't belong to the empty draft
        dismissCoach()
        // Dictation mode stays on across sends; typing into the empty box turns it off.
        // The reply went out, so its message is done with.
        liveContext = nil
        renderContext()
        if let cur = currentPID { drafts[cur] = ""; draftsDictated[cur] = liveDictated; contexts[cur] = nil } // the prompt was sent
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
        if textView.string.isEmpty { // draft abandoned, and its correction with it
            flushUnsentCheck(for: currentPID ?? 0)
            dismissCoach()
        } else if case .failed = coachState {
            dismissCoach()
        } else if coachState != nil {
            // A correction stays up while the draft is edited — fixing the marked
            // words by hand is the point. Only its marks and Enter's meaning move.
            refreshCoachMarks()
            hintLabel.stringValue = coachHint
        }
        refreshDraftLanguage()
        autocorrectContraction()
        fitTextHeight()
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
        guard draftLanguage == .english else { grammarReviewer.cancel(); return } // English-only reviewer
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
        guard !isCorrecting, draftLanguage == .english else { return }
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
        // Both completers are English-only; a Spanish draft gets no ghost.
        guard sel.length == 0, sel.location == ns.length, draftLanguage == .english else {
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
        contexts = contexts.filter { alive.contains($0.key) }
        coachStates = coachStates.filter { alive.contains($0.key) }
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
        if let cur = currentPID {
            drafts[cur] = textView.string; draftsDictated[cur] = liveDictated; contexts[cur] = liveContext
            if showsCoachResult { coachStates[cur] = coachState } // back when its tab is
        }
        currentPID = pid
        textView.string = drafts[pid] ?? ""
        fitTextHeight()
        languageLocked = false
        refreshDraftLanguage()
        liveDictated = draftsDictated[pid] ?? false
        liveContext = contexts[pid]
        refreshDictateButton()
        renderContext()
        textView.suggestion = nil
        clearGrammar() // the previous session's suggestions don't apply to this draft
        // A running check belongs to the draft we left; this one's correction, if
        // it has one, comes back with it.
        coachTask?.cancel()
        coachTask = nil
        coach.cancel()
        coachState = coachStates.removeValue(forKey: pid)
        renderCoach()
        updateSessionLabel(targetPID: pid)
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        // Re-review the draft we just switched to (no-op if it's empty).
        if !textView.string.isEmpty && coachState == nil { updateGrammar() }
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
    /// Debug only (`TYPEFLOW_DEMO_COACH=1`, or `=reply` for reply mode): open the
    /// composer with a canned coach result so the panel layout can be checked (and
    /// screenshotted) without a Codex call or a send.
    func showDemoCoach(reply: Bool = false) {
        show()
        if reply { showDemoReply(); return }
        let draft = "give me a markdown with the information for this lesson. Don't add extra information."
        textView.string = draft
        fitTextHeight()
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


    private func showDemoReply() {
        setContext(ReplyContext(text: """
            Two caveats:
            - One thing may stay: iOS shows its saved picture of the app during its own zoom.
            - Only your phone can verify this: the simulator can't show the real shield.

            Should I go ahead and put a Release build on your iPhone when it's ready?
            """, source: .text))
        let draft = "yes but first test it in the simulator to make sure nothing breaks"
        textView.string = draft
        fitTextHeight()
        let r = CoachResult(
            intent: "Agree, but test in the simulator first.", score: 82,
            native: "Yes, but test it in the simulator first to make sure nothing breaks.",
            fixes: [CoachFix(original: "yes but", correction: "Yes, but", reason: "capitalize, add comma",
                             category: "mechanics-punctuation-and-capitalization")],
            why: "It's a yes-no question, so the answer leads and the condition follows.",
            pattern: "Yes-no question: lead with yes or no, then the condition.", spanishTransfer: "",
            model: "gpt-6-luna", provider: "codex",
            asked: [CoachQuestion(question: "Put a Release build on your iPhone when it's ready?",
                                  kind: "yes-no", answered: true, note: "")])
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
        if case .result(let r, let d) = coachState, !isEdited(since: d) {
            guard !EnglishCoach.isDeep(r.model) else { NSSound.beep(); return } // already deep
            deep = true
        }
        let context = liveContext.map { EnglishCoach.Context(text: $0.text, image: $0.image) }
        textView.suggestion = nil
        ghostCompleter.cancel()
        clearGrammar() // the coach covers grammar too; one panel at a time
        coachTask?.cancel()
        coachState = .loading(draft: draft, deep: deep)
        renderCoach()
        coachTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.coach.check(draft, deep: deep, context: context)
                // Edits made while it ran don't void it: it lands as a correction
                // of the draft it saw. A session switch or ⎋ cancels it.
                guard !Task.isCancelled else { return }
                self.coachState = .result(result, draft: draft)
                self.unsentChecks[self.currentPID ?? 0] = ComposerSend(
                    text: result.native,
                    draft: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                    dictated: self.liveDictated, coach: result, corrected: false,
                    cwd: self.sessions.first(where: { $0.pid == self.currentPID })?.cwd,
                    destination: .unsent, reply: context != nil)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
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

    private var showsCoachResult: Bool {
        if case .result = coachState { return true }
        return false
    }

    /// The draft changed since `draft` was checked — a space or newline at the
    /// ends doesn't count.
    private func isEdited(since draft: String) -> Bool {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return trim(draft) != trim(textView.string)
    }

    /// The footer keys that apply to what's on screen now.
    private var coachHint: String {
        switch coachState {
        case nil:
            return idleHint
        case .loading:
            return "⌥↵ \(enterVerb) without waiting   ⎋ cancel"
        case .failed:
            return "↵ \(enterVerb)   ⌘K retry"
        case .result(let r, let draft):
            // Edited: ⌘K checks the new text; otherwise it re-checks this one deeper.
            let recheck = isEdited(since: draft) ? "   ⌘K check again"
                : EnglishCoach.isDeep(r.model) || r.isClean(for: draft) ? "" : "   ⌘K deeper"
            let sendWhat = r.isReply ? "reply" : r.isTranslation ? "English" : "corrected"
            return r.isClean(for: draft) ? "↵ \(enterVerb)\(recheck)"
                : "↵ \(enterVerb) \(sendWhat)   ⌥↵ mine\(recheck)"
        }
    }

    /// Mark in the text box what the coach removed (red, struck), only on the
    /// draft's words that are still there — so the marks fade as they're fixed
    /// by hand. Cleared whenever there's no result.
    private func refreshCoachMarks() {
        var marks: [(range: NSRange, slip: Bool)] = []
        if case .result(let r, let draft) = coachState, !r.isTranslation, !r.isClean(for: draft) {
            marks = TrackChanges.removedRanges(from: draft, to: r.native, in: textView.string)
        }
        textView.setCoachRemovals(marks)
    }

    /// Rebuild the coaching panel for `coachState`, resize the window to fit, and
    /// swap the footer hint to the keys that apply right now.
    private func renderCoach() {
        coachStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width = max(200, frame.width - 40)
        var rows: [NSView] = []

        switch coachState {
        case nil:
            break
        case .loading(_, let deep):
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let model = CoachProvider.displayName(model: deep ? CoachProvider.current.deepModel
                                                              : CoachProvider.current.quickModel)
            let doing = liveContext != nil ? (deep ? "Rewriting your reply more naturally" : "Drafting your reply")
                : (deep ? "Rewriting more naturally" : "Checking your English")
            let label = coachLabel("\(doing) with \(model)…", size: 12, color: .secondaryLabelColor)
            let row = NSStackView(views: [spinner, label])
            row.spacing = 8
            rows.append(row)
        case .failed(let message):
            rows.append(coachLabel("Couldn't check: \(message)", size: 12, color: .systemRed, width: width))
        case .result(let r, let draft):
            rows += coachRows(r, draft: draft, width: width)
        }

        refreshCoachMarks()
        for row in rows {
            coachStack.addArrangedSubview(row)
            // Full-width hairlines; constrained only once inside the stack (an
            // anchor pair with no common ancestor throws — see populateGrammarPanel).
            if row is SeparatorLine { row.widthAnchor.constraint(equalTo: coachStack.widthAnchor).isActive = true }
        }
        coachScroll.isHidden = rows.isEmpty
        hintLabel.stringValue = coachHint
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

        if let asked = r.asked, !asked.isEmpty {
            rows.append(SeparatorLine())
            rows.append(coachLabel("ASKED", size: 10, weight: .semibold, color: .tertiaryLabelColor))
            for q in asked {
                let str = NSMutableAttributedString(string: q.answered ? "✓ " : "✗ ", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: q.answered ? NSColor.systemGreen : NSColor.systemOrange])
                str.append(NSAttributedString(string: q.question, attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
                str.append(NSAttributedString(string: "    \(q.kind)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
                if !q.answered, !q.note.isEmpty {
                    str.append(NSAttributedString(string: " · \(q.note)", attributes: [
                        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemOrange]))
                }
                rows.append(attributedLabel(str, width: width))
            }
        }

        if r.isClean(for: draft) {
            let msg = r.isReply ? "✓ Your reply answers it naturally. No changes needed."
                : "✓ Sounds natural. No changes needed."
            rows.append(coachLabel(msg, size: 13, color: .systemGreen, width: width))
            return rows
        }

        // The draft is already in the text box above, with the coach's removals
        // marked there in red (see renderCoach). The panel opens with what Enter
        // sends: the corrected version, additions in green. A translation shares
        // no words with the Spanish, so it's shown plain.
        rows.append(SeparatorLine())
        rows.append(coachLabel(r.isReply ? (r.isTranslation ? "REPLY IN ENGLISH" : "REPLY")
                               : r.isTranslation ? "IN ENGLISH" : "CORRECTED", size: 10, weight: .semibold,
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
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "t" {
            toggleTerminalMode()
            return true
        }
        if mods == [.command, .option], event.keyCode == 1 { // ⌥⌘S (⌥ changes the character)
            toggleSpeaking()
            return true
        }
        if mods == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c" {
            copyForElsewhere()
            return true
        }
        if mods == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "v" {
            pasteAsContext()
            return true
        }
        // The draft is plain text and can't take an image, so ⌘V of a screenshot
        // means "reply to this".
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "v",
           ScreenText.clipboardIsImageOnly(), let image = ScreenText.clipboardImage() {
            readScreenshot(image)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc closes the coaching panel first; otherwise the composer.
    private func handleEscape() {
        if speaker.isSpeaking {
            speaker.stop()
        } else if coachState != nil {
            dismissCoach()
            makeFirstResponder(textView)
        } else {
            hide()
        }
    }

    /// What Enter (and ⌘⇧C) puts out: with a correction showing, the coach's
    /// version — even after the draft was edited under it, so the corrected
    /// option stays while the marked words are fixed by hand — or the draft
    /// itself when there was nothing to fix. nil while a check is running.
    private func outgoing() -> (text: String, coach: CoachResult?, corrected: Bool, draft: String)? {
        let text = textView.string
        switch coachState {
        case .loading:
            return nil
        case .result(let r, let draft) where !r.isClean(for: draft):
            return (r.native, r, true, draft)
        case .result(let r, let draft):
            return (text, r, false, draft)
        default:
            return (text, nil, false, text)
        }
    }

    /// Enter. While a check is still running, Enter waits — ⌥↵ sends the draft
    /// as-is without waiting.
    @objc func submit() {
        guard let out = outgoing() else { NSSound.beep(); return }
        send(out.text, coach: out.coach, corrected: out.corrected, draft: out.draft)
    }

    /// ⌥Enter while coaching: send the text box as it is. Edited under a
    /// correction, it was rewritten from the marked fixes, so it goes as
    /// coach-corrected (`;;tf+`) and the checked draft stays the writer's attempt
    /// in the log — the copied fixes never count as their own English.
    private func submitOriginal() {
        if case .result(let r, let draft) = coachState, isEdited(since: draft) {
            return send(textView.string, coach: r, corrected: !r.isClean(for: draft), draft: draft)
        }
        send(textView.string, coach: currentCoachResult, corrected: false)
    }

    /// ⌘⇧C: put the text on the clipboard instead of sending it to Claude — for a
    /// quick correction to paste into another app. Same choice as Enter. Like a
    /// send, the draft clears; with "keep open" on the composer stays up for the
    /// next one, otherwise it closes so focus returns to the previous app.
    private func copyForElsewhere() {
        guard let out = outgoing() else { NSSound.beep(); return }
        copy(out.text, coach: out.coach, corrected: out.corrected, draft: out.draft)
    }

    /// The copy itself — ⌘⇧C, and Enter / ⌥↵ when terminal mode is off. Logged
    /// to wingman-english as `destination: "clipboard"` when ⌘K checked it.
    /// `draft` is what the writer wrote, when not the text box (see `outgoing`).
    private func copy(_ raw: String, coach: CoachResult?, corrected: Bool, draft: String? = nil) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        WingmanEnglishLog.record(ComposerSend(
            text: text,
            draft: (draft ?? textView.string).trimmingCharacters(in: .whitespacesAndNewlines),
            dictated: liveDictated, coach: coach, corrected: corrected,
            cwd: nil, destination: .clipboard, reply: liveContext != nil))
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
    private func flashHint(_ message: String, color: NSColor = .systemGreen) {
        hintLabel.stringValue = message
        hintLabel.textColor = color
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.hintLabel.stringValue == message else { return }
            self.hintLabel.textColor = .tertiaryLabelColor
            self.hintLabel.stringValue = self.coachHint
        }
    }

    /// The coach's result, if it was computed for exactly the visible draft.
    private var currentCoachResult: CoachResult? {
        if case .result(let r, let draft) = coachState, !isEdited(since: draft) { return r }
        return nil
    }

    private func send(_ raw: String, coach: CoachResult?, corrected: Bool, draft: String? = nil) {
        guard terminalMode else { return copy(raw, coach: coach, corrected: corrected, draft: draft) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        let send = ComposerSend(
            text: text,
            draft: (draft ?? textView.string).trimmingCharacters(in: .whitespacesAndNewlines),
            dictated: liveDictated, coach: coach, corrected: corrected,
            cwd: sessions.first(where: { $0.pid == currentPID })?.cwd, reply: liveContext != nil)
        // If the send failed (e.g. Warp not running), keep the text and the
        // window so the user doesn't lose their prompt.
        speaker.stop()
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

    // MARK: - Draft language

    /// Re-detect the draft's language (unless locked) and apply a change. An empty
    /// draft starts over in English; too little text to tell keeps the current one.
    private func refreshDraftLanguage() {
        guard !languageLocked else { return }
        let text = textView.string
        let detected = text.isEmpty ? .english : (DraftLanguage.detect(text) ?? draftLanguage)
        if detected != draftLanguage { applyDraftLanguage(detected) }
    }

    private func applyDraftLanguage(_ lang: DraftLanguage) {
        draftLanguage = lang
        wordCompleter.setLanguage(lang)
        // Re-run spellcheck so the underlines match the new language.
        textView.isContinuousSpellCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        if lang != .english {
            textView.suggestion = nil
            ghostCompleter.cancel()
            clearGrammar()
        }
        refreshLangButton()
    }

    /// Click: switch to the other language and lock it for this draft.
    @objc private func langButtonClicked() {
        languageLocked = true
        applyDraftLanguage(draftLanguage == .english ? .spanish : .english)
        if draftLanguage == .english { updateGrammar() }
        makeFirstResponder(textView)
    }

    private func refreshLangButton() {
        let spanish = draftLanguage == .spanish
        let color: NSColor = spanish ? .controlAccentColor : .tertiaryLabelColor
        langButton.attributedTitle = NSAttributedString(
            string: draftLanguage.rawValue + (languageLocked ? " 🔒" : ""),
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: spanish ? .semibold : .regular),
                         .foregroundColor: color])
        langButton.toolTip = (languageLocked ? "Locked for this draft. " : "Detected automatically. ")
            + "Spell check and autocorrect follow it; Spanish pauses the English-only helpers. Click to switch and lock."
    }

    /// ⌘T / the footer pill: switch Enter between Warp and the clipboard.
    @objc private func toggleTerminalMode() {
        terminalMode.toggle()
        refreshTerminalMode()
        makeFirstResponder(textView)
    }

    /// Sync the pill, session label, hints and Warp tab-following with the mode.
    /// Copy mode hides the session — nothing is going to Warp — and stops the
    /// follow poll, which only exists to name where a send lands.
    private func refreshTerminalMode() {
        let on = terminalMode
        modeButton.image = NSImage(systemSymbolName: on ? "terminal" : "doc.on.clipboard",
                                   accessibilityDescription: nil)
        let color: NSColor = on ? .secondaryLabelColor : .controlAccentColor
        modeButton.attributedTitle = NSAttributedString(string: on ? "Warp" : "Copy", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: on ? .regular : .semibold), .foregroundColor: color])
        modeButton.contentTintColor = color
        modeButton.toolTip = on
            ? "Terminal mode: ↵ sends to the Claude session in Warp's front tab. ⌘T → copy mode"
            : "Copy mode: ↵ copies the text to paste anywhere; nothing goes to Warp. ⌘T → terminal mode"
        sessionLabel.isHidden = !on
        hintLabel.stringValue = coachHint
        if on, isVisible {
            lastWarpTitle = nil   // force the first poll to follow
            followTick()
            startFollowTimer()
        } else {
            stopFollowTimer()
        }
    }

    // MARK: - ⋯ menu

    /// Settings that rarely change, and every shortcut — the footer only names
    /// the two main keys.
    @objc private func showMoreMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func toggle(_ title: String, _ on: Bool, _ action: Selector, tip: String) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            item.toolTip = tip
        }
        toggle("Keep open after sending", keepOpen, #selector(keepOpenToggled),
               tip: "Sending (↵) or copying (⌘⇧C) clears the draft without closing the composer")
        toggle("Show on all desktops", allDesktops, #selector(allDesktopsToggled),
               tip: "On every desktop, where you left it. Off: it opens centered on the desktop you're on")
        toggle("Send to Warp  (⌘T)", terminalMode, #selector(toggleTerminalMode),
               tip: "Off: ↵ copies the text to paste anywhere; nothing goes to Warp")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Shortcuts", action: nil, keyEquivalent: "").isEnabled = false
        for line in ["⌘K\tcheck English / suggest reply", "⇧↵\tnewline", "⌥↵\tsend as typed",
                     "⌘⇧C\tcopy", "⌘⇧V\treply to copied message", "⌥⌘S\tread aloud",
                     "⌘T\tWarp / copy", "⎋\tclose panel, then composer"] {
            let item = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            let tabs = NSMutableParagraphStyle()
            tabs.tabStops = [NSTextTab(textAlignment: .left, location: 44)]
            item.attributedTitle = NSAttributedString(string: "  " + parts[0] + "\t" + parts[1], attributes: [
                .font: NSFont.menuFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: tabs])
            item.isEnabled = false
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.maxY + 4), in: moreButton)
        makeFirstResponder(textView)
    }

    @objc private func keepOpenToggled() {
        keepOpen.toggle()
    }

    @objc private func allDesktopsToggled() {
        allDesktops.toggle()
        applyDesktopBehavior()
    }

    @objc private func startDictationClicked() {
        // Lit already: the click un-marks the draft instead of dictating again.
        if liveDictated {
            liveDictated = false
            refreshDictateButton()
            makeFirstResponder(textView)
            return
        }
        // startDictation: is the selector the system dictation shortcut invokes;
        // calling it on the focused text view starts Apple dictation in the box.
        // Mark this draft as dictated so the send carries the ;;v marker and
        // the observer runs its dictation-misrecognition + naturalness analysis.
        liveDictated = true
        refreshDictateButton()
        makeFirstResponder(textView)
        textView.perform(Selector(("startDictation:")), with: nil)
    }

    /// ▶ / ■ / ⌥⌘S: read aloud what Enter would send — the correction or
    /// suggested reply when there is one, the draft as typed otherwise — or stop.
    @objc private func toggleSpeaking() {
        if speaker.isSpeaking { return speaker.stop() }
        guard let text = outgoing()?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { NSSound.beep(); return }
        // The coach's version is English even for a Spanish draft, so go by the text read.
        speaker.speak(text, language: DraftLanguage.detect(text) ?? draftLanguage)
        refreshSpeakButton()
        makeFirstResponder(textView)
    }

    private func refreshSpeakButton() {
        let on = speaker.isSpeaking
        speakButton.image = NSImage(systemSymbolName: on ? "stop.fill" : "play.fill",
                                    accessibilityDescription: on ? "Stop reading" : "Read aloud")
        speakButton.contentTintColor = on ? .controlAccentColor : .tertiaryLabelColor
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

