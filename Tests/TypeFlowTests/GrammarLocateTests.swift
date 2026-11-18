import XCTest
@testable import TypeFlow

/// Local suggestions (the on-device grammar panel): which model fixes are shown.
@MainActor
final class GrammarLocateTests: XCTestCase {
    private func locate(_ text: String, _ fixes: [(String, String)]) -> [GrammarSpan] {
        GrammarReviewer.locate(fixes.map { .init(original: $0.0, correction: $0.1, reason: "r") }, in: text)
    }

    func testPartialWordDoesNotMatchInsideTheFinishedWord() {
        // A fix computed for "retur" must not land on "return" once it's typed.
        XCTAssertTrue(locate("Please return the value", [("retur", "return")]).isEmpty)
    }

    func testWholeWordStillMatches() {
        let spans = locate("Please retur the value", [("retur", "return")])
        XCTAssertEqual(spans.map(\.range), [NSRange(location: 7, length: 5)])
    }

    func testSkipsAnEarlierPartialMatchForALaterWholeWord() {
        let spans = locate("returning? retur it", [("retur", "return")])
        XCTAssertEqual(spans.map(\.range), [NSRange(location: 11, length: 5)])
    }

    func testPluralNounIsNotMadeSingular() {
        XCTAssertTrue(locate("The tests are failing", [("tests", "test")]).isEmpty)
        XCTAssertTrue(locate("Fix the boxes", [("boxes", "box")]).isEmpty)
        XCTAssertTrue(locate("Check the queries", [("queries", "query")]).isEmpty)
    }

    func testSingularIsKeptWhenTheSentenceAsksForIt() {
        XCTAssertEqual(locate("Add a tests for it", [("tests", "test")]).count, 1)
        XCTAssertEqual(locate("Each files is read", [("files", "file")]).count, 1)
    }

    func testUncountableNounIsMadeSingular() {
        XCTAssertEqual(locate("Thanks for the informations", [("informations", "information")]).count, 1)
        XCTAssertEqual(locate("Some advices please", [("advices", "advice")]).count, 1)
    }

    func testSingularToPluralIsAllowed() {
        XCTAssertEqual(locate("Run two test now", [("test", "tests")]).count, 1)
    }

    func testRealFixesStillShow() {
        let spans = locate("He go to the market", [("go", "goes")])
        XCTAssertEqual(spans.first?.range, NSRange(location: 3, length: 2))
    }

    func testNegationDropIsRefused() {
        XCTAssertTrue(locate("It is not ready", [("not ready", "ready")]).isEmpty)
    }
}
