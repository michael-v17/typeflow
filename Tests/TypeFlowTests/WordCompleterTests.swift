import AppKit
import XCTest
@testable import TypeFlow

/// WordCompleter: the gray suffix for the word being typed, from the system dictionary.
@MainActor
final class WordCompleterTests: XCTestCase {
    func testCompletesThePartialWordAtTheCaret() throws {
        let text = "so the toggles becom"
        let suffix = try XCTUnwrap(WordCompleter().completion(in: text, caret: (text as NSString).length))
        XCTAssertFalse(suffix.isEmpty)
        XCTAssertTrue(["become", "becomes", "becoming"].contains("becom" + suffix), "becom + \(suffix)")
    }

    func testOnlyTheLettersBeforeTheCaretCount() throws {
        let text = "becom later"
        let suffix = try XCTUnwrap(WordCompleter().completion(in: text, caret: 5))
        XCTAssertTrue(("becom" + suffix).hasPrefix("become"), "becom + \(suffix)")
    }

    func testNothingForFewerThanTwoLetters() {
        XCTAssertNil(WordCompleter().completion(in: "fix b", caret: 5))
    }

    func testNothingRightAfterASpaceOrPunctuation() {
        XCTAssertNil(WordCompleter().completion(in: "fix the ", caret: 8))
        XCTAssertNil(WordCompleter().completion(in: "fix it.", caret: 7))
    }

    func testNothingForACaretOutOfRange() {
        XCTAssertNil(WordCompleter().completion(in: "becom", caret: 0))
        XCTAssertNil(WordCompleter().completion(in: "becom", caret: 6))
    }

    func testNothingForAFinishedWordWithNoLongerForm() {
        XCTAssertNil(WordCompleter().completion(in: "xqzv", caret: 4))
    }
}
