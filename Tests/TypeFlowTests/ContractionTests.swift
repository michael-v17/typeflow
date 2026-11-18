import AppKit
import XCTest
@testable import TypeFlow

/// Contractions: the unambiguous list is fixed as you type, the real words never.
final class ContractionTests: XCTestCase {
    static let autoFixed: [String: String] = [
        "dont": "don't", "doesnt": "doesn't", "didnt": "didn't", "isnt": "isn't",
        "wasnt": "wasn't", "arent": "aren't", "werent": "weren't", "havent": "haven't",
        "hasnt": "hasn't", "couldnt": "couldn't", "wouldnt": "wouldn't",
        "shouldnt": "shouldn't", "im": "I'm", "ive": "I've",
    ]
    static let suggestionsOnly = ["cant", "wont", "ill", "id", "its", "were", "well", "hell", "shell"]

    func testExactlyTheUnambiguousListIsAutoFixed() {
        var expected = Self.autoFixed
        expected["i"] = "I" // the lone pronoun
        XCTAssertEqual(ContractionCorrector.autoFixes, expected)
    }

    func testEachUnambiguousEntryIsFixed() {
        for (word, fixed) in Self.autoFixed {
            XCTAssertEqual(ContractionCorrector.correction(for: word), fixed, word)
        }
    }

    func testCapitalIsKept() {
        XCTAssertEqual(ContractionCorrector.correction(for: "Dont"), "Don't")
        XCTAssertEqual(ContractionCorrector.correction(for: "Doesnt"), "Doesn't")
        XCTAssertEqual(ContractionCorrector.correction(for: "im"), "I'm")
        XCTAssertEqual(ContractionCorrector.correction(for: "Ive"), "I've")
    }

    func testAmbiguousRealWordsAreNeverAutoFixed() {
        for word in Self.suggestionsOnly {
            XCTAssertNil(ContractionCorrector.correction(for: word), word)
            XCTAssertNil(ContractionCorrector.correction(for: word.capitalized), word)
            XCTAssertTrue(ContractionCorrector.suggestOnly.contains(word), word)
        }
        XCTAssertTrue(ContractionCorrector.suggestOnly.isDisjoint(with: ContractionCorrector.autoFixes.keys))
    }

    func testOtherWordsAreLeftAlone() {
        for word in ["done", "do", "don", "doesn", "image", "shellcheck", "lets", "youre"] {
            XCTAssertNil(ContractionCorrector.correction(for: word), word)
        }
    }
}

/// The same lists, typed for real into the composer (offscreen, never shown):
/// key events go through NSTextView's input path like a keyboard's.
@MainActor
final class ComposerTypingTests: XCTestCase {
    private func type(_ text: String, into window: ComposerWindow) {
        for c in text {
            let s = String(c)
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: s,
                                     charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0)!
            window.textView.keyDown(with: e)
        }
    }

    func testTypingFixesOnlyTheUnambiguousList() {
        _ = NSApplication.shared
        let window = ComposerWindow { _ in true }
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeFirstResponder(window.textView)

        for (word, fixed) in ContractionTests.autoFixed {
            window.textView.string = ""
            type("so \(word) ", into: window)
            XCTAssertEqual(window.textView.string, "So \(fixed) ", word)
        }
        for word in ContractionTests.suggestionsOnly {
            window.textView.string = ""
            type("so \(word) ", into: window)
            XCTAssertEqual(window.textView.string, "So \(word) ", word)
        }
        // At the very start of the draft, then capitalized as a sentence start.
        window.textView.string = ""
        type("dont ", into: window)
        XCTAssertEqual(window.textView.string, "Don't ")
    }
}
