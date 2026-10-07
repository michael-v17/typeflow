import AppKit

/// An `NSTextView` that draws a gray, *non-committed* inline suggestion right
/// after the caret — the "ghost text" you accept with Tab.
///
/// The suggestion lives ONLY in the `suggestion` property, never in
/// `textStorage`. That is the whole trick: because the buffer is never polluted
/// with provisional text, undo, Delete/Backspace, IME marked text, word
/// boundaries, and `currentText()`/`submit()` all stay pristine. (This sidesteps
/// the exact state-machine bugs that the native `inlinePredictionType` path hit.)
///
/// Ghost text is only drawn when the caret is a collapsed insertion point at the
/// very END of the buffer — the only place a "continue what you're typing"
/// suggestion makes sense.
final class GhostTextView: NSTextView {

    /// The current inline suggestion (display-ready, including any leading
    /// space). `nil` or empty hides it.
    var suggestion: String? {
        didSet {
            if suggestion != oldValue { needsDisplay = true }
        }
    }

    /// Grammar / naturalness issues to underline (set via `setGrammarSpans`).
    private(set) var grammarSpans: [GrammarSpan] = [] {
        didSet { if grammarSpans != oldValue { needsDisplay = true } }
    }

    /// Replace the underlined grammar spans and refresh the hover tooltips that
    /// preview each suggestion. Spans whose range falls outside the buffer are
    /// dropped (stale after an edit).
    /// Marks what the coach removed, in place: red and struck through. Temporary
    /// attributes are display-only — the text, its undo stack, and what gets sent
    /// are untouched. Pass [] to clear.
    func setCoachRemovals(_ ranges: [(range: NSRange, slip: Bool)]) {
        guard let lm = layoutManager else { return }
        let length = textStorage?.length ?? 0
        let all = NSRange(location: 0, length: length)
        lm.removeTemporaryAttribute(.strikethroughStyle, forCharacterRange: all)
        lm.removeTemporaryAttribute(.strikethroughColor, forCharacterRange: all)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        // Yellow = a slip (capitals, punctuation); red = a language error.
        for (r, slip) in ranges where NSMaxRange(r) <= length {
            let color = slip ? TrackChanges.slipColor : NSColor.systemRed
            lm.addTemporaryAttributes([
                .foregroundColor: color,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: color,
            ], forCharacterRange: r)
        }
    }

    func setGrammarSpans(_ spans: [GrammarSpan]) {
        let length = textStorage?.length ?? 0
        grammarSpans = spans.filter { NSMaxRange($0.range) <= length }
        removeAllToolTips()
        guard let lm = layoutManager, let tc = textContainer else { return }
        for span in grammarSpans {
            let glyphRange = lm.glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            let tip = "\(span.original) → \(span.correction)  ·  \(span.reason)" as NSString
            addToolTip(rect, owner: tip, userData: nil)
        }
    }

    private var ghostAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? .systemFont(ofSize: 16),
         .foregroundColor: NSColor.placeholderTextColor] // adapts to light/dark
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawGrammarUnderlines()
        drawGhost()
    }

    /// Draw a thick orange underline beneath each flagged span — visually
    /// distinct from the system's red spell-check squiggle. Multi-line spans are
    /// handled per visual line via `enumerateEnclosingRects`.
    private func drawGrammarUnderlines() {
        guard !grammarSpans.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        NSColor.systemOrange.setStroke()
        let origin = textContainerOrigin
        for span in grammarSpans {
            let glyphRange = lm.glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
            lm.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: tc
            ) { rect, _ in
                let y = rect.maxY + origin.y - 1
                let path = NSBezierPath()
                path.lineWidth = 2
                path.move(to: NSPoint(x: rect.minX + origin.x, y: y))
                path.line(to: NSPoint(x: rect.maxX + origin.x, y: y))
                path.stroke()
            }
        }
    }

    private func drawGhost() {
        guard let suggestion, !suggestion.isEmpty,
              !hasMarkedText(),                                  // stay out of IME composition
              selectedRange().length == 0,                       // collapsed caret only
              selectedRange().location == (textStorage?.length ?? 0), // ...at end of buffer
              let origin = caretOriginInView()
        else { return }
        NSAttributedString(string: suggestion, attributes: ghostAttributes).draw(at: origin)
    }

    /// Top-left point (view coordinates) where the glyph after the caret would
    /// be laid out. Uses the TextKit 1 layout manager — fine here, since we no
    /// longer rely on the framework's inline-prediction overlay.
    private func caretOriginInView() -> NSPoint? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let length = textStorage?.length ?? 0
        lm.ensureLayout(for: tc)

        let rect: NSRect
        if length == 0 {
            rect = NSRect(x: 0, y: 0, width: 1, height: (font?.pointSize ?? 16) * 1.3)
        } else {
            // Rect of the last character; the next glyph starts at its maxX.
            let last = lm.boundingRect(forGlyphRange: NSRange(location: length - 1, length: 1),
                                       in: tc)
            rect = NSRect(x: last.maxX, y: last.minY, width: 1, height: last.height)
        }
        return NSPoint(x: rect.minX + textContainerOrigin.x,
                       y: rect.minY + textContainerOrigin.y)
    }

    /// Called when a printable key is typed into an empty buffer. Dictation never
    /// arrives via keyDown, so this means the next message is being typed.
    var onTypingIntoEmpty: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if string.isEmpty,
           event.modifierFlags.intersection([.command, .control]).isEmpty,
           let chars = event.characters, chars.unicodeScalars.contains(where: {
               CharacterSet.alphanumerics.union(.punctuationCharacters).contains($0)
           }) {
            onTypingIntoEmpty?()
        }
        super.keyDown(with: event)
    }

    // Keep the ghost in sync when the caret/selection moves (e.g. arrow keys).
    override func setSelectedRanges(_ ranges: [NSValue],
                                    affinity: NSSelectionAffinity,
                                    stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if suggestion != nil { needsDisplay = true }
    }
}
