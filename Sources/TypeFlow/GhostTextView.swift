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

    private var ghostAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? .systemFont(ofSize: 16),
         .foregroundColor: NSColor.placeholderTextColor] // adapts to light/dark
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawGhost()
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

    // Keep the ghost in sync when the caret/selection moves (e.g. arrow keys).
    override func setSelectedRanges(_ ranges: [NSValue],
                                    affinity: NSSelectionAffinity,
                                    stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if suggestion != nil { needsDisplay = true }
    }
}
