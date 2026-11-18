import AppKit

/// ⌥⌘R's player, like macOS's Speak Selection controller: the app the text came
/// from, ⏸/▶, ■ and ×. ■, × or ⌥⌘R again stops and closes it; it also closes when
/// the reading ends. Non-activating, so the app you're in keeps the keyboard.
final class ReadAloudPanel: NSPanel {
    private let speaker = Speaker()
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()

    var isReading: Bool { speaker.isSpeaking }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 220, height: 80),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        buildContent()
        speaker.onFinish = { [weak self] in self?.orderOut(nil) }
    }

    override var canBecomeKey: Bool { false }

    private func buildContent() {
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        contentView = blur

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail

        let close = button("xmark", "Stop and close", #selector(stopClicked), size: 10)
        let stopButton = button("stop.fill", "Stop", #selector(stopClicked), size: 18)
        configure(pauseButton, "pause.fill", "Pause", #selector(pauseClicked), size: 18)

        let title = NSStackView(views: [icon, name])
        title.spacing = 6
        let controls = NSStackView(views: [pauseButton, stopButton])
        controls.spacing = 22
        let stack = NSStackView(views: [title, controls])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 28, bottom: 12, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        close.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        blur.addSubview(close)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            close.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 8),
            close.topAnchor.constraint(equalTo: blur.topAnchor, constant: 8),
        ])
    }

    private func button(_ symbol: String, _ tip: String, _ action: Selector, size: CGFloat) -> NSButton {
        let b = NSButton()
        configure(b, symbol, tip, action, size: size)
        return b
    }

    private func configure(_ b: NSButton, _ symbol: String, _ tip: String, _ action: Selector, size: CGFloat) {
        b.bezelStyle = .accessoryBarAction
        b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        b.contentTintColor = .labelColor
        b.toolTip = tip
        b.target = self
        b.action = action
    }

    /// Read `text` aloud and show the player under the mouse, with `app`'s name.
    func read(_ text: String, from app: NSRunningApplication?) {
        icon.image = app?.icon ?? NSApp.applicationIconImage
        name.stringValue = app?.localizedName ?? "TypeFlow"
        speaker.speak(text, language: DraftLanguage.detect(text) ?? .english)
        refreshPauseButton()
        place()
        orderFrontRegardless()
    }

    func stop() {
        speaker.stop() // onFinish closes the panel
        orderOut(nil)
    }

    @objc private func stopClicked() { stop() }

    @objc private func pauseClicked() {
        if speaker.isPaused { speaker.resume() } else { speaker.pause() }
        refreshPauseButton()
    }

    private func refreshPauseButton() {
        let paused = speaker.isPaused
        configure(pauseButton, paused ? "play.fill" : "pause.fill", paused ? "Resume" : "Pause",
                  #selector(pauseClicked), size: 18)
    }

    /// Just below the mouse, kept on its screen.
    private func place() {
        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? frame.size
        let mouse = NSEvent.mouseLocation
        let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 16)
        if origin.y < visible.minY { origin.y = mouse.y + 16 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
