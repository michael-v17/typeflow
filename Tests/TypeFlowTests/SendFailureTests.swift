import AppKit
import XCTest
@testable import TypeFlow

/// A send whose ⌃G didn't open Warp's Rich Input stops before typing anything
/// and keeps the text in the composer.
@MainActor
final class SendFailureTests: XCTestCase {
    typealias S = RichInputCheck.Snapshot

    func testMessageIsVerbatim() {
        XCTAssertEqual(WarpInjector.InjectError.richInputMessage, "Couldn't open Warp's input — text kept")
        XCTAssertEqual(String(describing: WarpInjector.InjectError.richInputNotOpened),
                       "Couldn't open Warp's input — text kept")
    }

    func testOpenedOnlyWhenTheEditorAppears() {
        let closed = S(editorMenuEnabled: false, focusedRole: "AXTextArea", focusedValueLength: 3000, focusedHash: 1)
        let open = S(editorMenuEnabled: true, focusedRole: "AXTextArea", focusedValueLength: 0, focusedHash: 2)
        XCTAssertTrue(RichInputCheck.opened(from: closed, to: open))
        XCTAssertFalse(RichInputCheck.opened(from: closed, to: closed)) // ⌃G went to claude (vim)
        XCTAssertFalse(RichInputCheck.opened(from: open, to: open))     // an editor already had focus
        XCTAssertFalse(RichInputCheck.opened(from: open, to: closed))   // ⌃G closed it
    }

    func testUnknownStateIsNeverTakenAsOpened() {
        let unknown = S()
        let open = S(editorMenuEnabled: true)
        XCTAssertFalse(RichInputCheck.opened(from: unknown, to: open))
        XCTAssertFalse(RichInputCheck.opened(from: unknown, to: unknown))
    }

    func testComposerKeepsTheTextAndOffersCopy() {
        _ = NSApplication.shared
        let window = ComposerWindow { _ in false }
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.textView.string = "Rename the helper"

        window.showSendFailure("Rename the helper", activate: false)
        XCTAssertEqual(window.textView.string, "Rename the helper")
        XCTAssertEqual(window.sendFailureShown?.message, "Couldn't open Warp's input — text kept")
        XCTAssertEqual(window.sendFailureShown?.copyVisible, true)

        // Editing the kept text clears the message.
        window.textView.insertText("!", replacementRange: NSRange(location: 17, length: 0))
        XCTAssertNil(window.sendFailureShown)
    }
}
