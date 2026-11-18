import AppKit
import XCTest
@testable import TypeFlow

/// TrackChanges: the word diff behind the coach panel and the composer's red marks.
final class TrackChangesTests: XCTestCase {
    private let draft = "the mock return an empty list"
    private let native = "the mock returns an empty list"

    /// The colors of every run whose attribute `key` is set, keyed by its text.
    private func marked(_ s: NSAttributedString, _ key: NSAttributedString.Key) -> [String: NSColor] {
        var out: [String: NSColor] = [:]
        s.enumerateAttribute(key, in: NSRange(location: 0, length: s.length)) { value, range, _ in
            guard value != nil else { return }
            let text = (s.string as NSString).substring(with: range)
            out[text] = s.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        }
        return out
    }

    func testSidesStrikeTheRemovedWordAndAddTheNewOne() throws {
        let (mine, corrected) = try XCTUnwrap(TrackChanges.sides(from: draft, to: native, size: 13))
        XCTAssertEqual(mine.string, draft)
        XCTAssertEqual(corrected.string, native)
        XCTAssertEqual(marked(mine, .strikethroughStyle), ["return": NSColor.systemRed])
        let added = corrected.attribute(.foregroundColor, at: (native as NSString).range(of: "returns").location,
                                        effectiveRange: nil) as? NSColor
        XCTAssertEqual(added, NSColor.systemGreen)
    }

    func testCapitalsAndPunctuationAreSlipsNotMistakes() throws {
        let (mine, corrected) = try XCTUnwrap(TrackChanges.sides(from: "hello world", to: "Hello world.", size: 13))
        XCTAssertEqual(marked(mine, .strikethroughStyle), ["hello": TrackChanges.slipColor])
        for word in ["Hello", "."] {
            let at = (corrected.string as NSString).range(of: word).location
            XCTAssertEqual(corrected.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor,
                           TrackChanges.slipColor, word)
        }
    }

    func testPunctuationAttachesToTheWordBeforeIt() throws {
        let (_, corrected) = try XCTUnwrap(TrackChanges.sides(from: "Good I'd do it", to: "Good, I'd do it", size: 13))
        XCTAssertEqual(corrected.string, "Good, I'd do it")
    }

    func testCurlyAndStraightQuotesAreTheSameWord() throws {
        let (mine, corrected) = try XCTUnwrap(TrackChanges.sides(from: "I don’t know", to: "I don't know", size: 13))
        XCTAssertTrue(marked(mine, .strikethroughStyle).isEmpty)
        XCTAssertEqual(corrected.string, "I don't know")
    }

    func testMergedLineIsNilWhenNothingIsShared() {
        XCTAssertNil(TrackChanges.attributed(from: "abc def", to: "xyz", size: 13))
        XCTAssertNil(TrackChanges.attributed(from: "", to: native, size: 13))
        XCTAssertEqual(TrackChanges.attributed(from: draft, to: native, size: 13)?.string,
                       "the mock return returns an empty list")
    }

    func testRemovedRangesMarkTheDraftWordInTheComposer() {
        let ranges = TrackChanges.removedRanges(from: draft, to: native, in: draft)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first.map { (draft as NSString).substring(with: $0.range) }, "return")
        XCTAssertEqual(ranges.first?.slip, false)
    }

    func testAMarkGoesWhenTheWordIsFixedByHand() {
        XCTAssertTrue(TrackChanges.removedRanges(from: draft, to: native, in: native).isEmpty)
    }

    func testWordsTypedAfterTheCheckAreNeverMarked() {
        let current = draft + " but return early"
        let ranges = TrackChanges.removedRanges(from: draft, to: native, in: current)
        XCTAssertEqual(ranges.map { $0.range.location }, [(draft as NSString).range(of: "return").location])
    }
}
