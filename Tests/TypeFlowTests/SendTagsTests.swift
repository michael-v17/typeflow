import XCTest
@testable import TypeFlow

/// "Tag sends for the learning log": the provenance prefixes reach Warp only
/// when the setting is on, and it is off by default.
final class SendTagsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "TypeFlowTests.SendTags"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func send(corrected: Bool = false, reply: Bool = false, dictated: Bool = false) -> ComposerSend {
        ComposerSend(text: "Fix the failing test", draft: "fix the failing test",
                     dictated: dictated, coach: nil, corrected: corrected, cwd: nil, reply: reply)
    }

    /// Every combination of the four markers.
    private var allSends: [ComposerSend] {
        [false, true].flatMap { c in [false, true].flatMap { r in [false, true].map { d in
            send(corrected: c, reply: r, dictated: d)
        } } }
    }

    func testOffByDefault() {
        XCTAssertFalse(SendTags.isOn(defaults))
    }

    func testToggles() {
        SendTags.set(true, defaults)
        XCTAssertTrue(SendTags.isOn(defaults))
        SendTags.set(false, defaults)
        XCTAssertFalse(SendTags.isOn(defaults))
    }

    func testOffSendsTheTextWithNoPrefix() {
        for s in allSends {
            XCTAssertEqual(s.payload(tagging: false), "Fix the failing test")
            XCTAssertFalse(s.payload(tagging: false).contains(";;"))
        }
    }

    func testDefaultSettingSendsNoPrefix() {
        for s in allSends {
            XCTAssertEqual(s.payload(tagging: SendTags.isOn(defaults)), s.text)
        }
    }

    func testOnPrefixesTheMarkers() {
        XCTAssertEqual(send().payload(tagging: true), ";;tf Fix the failing test")
        XCTAssertEqual(send(corrected: true).payload(tagging: true), ";;tf+ Fix the failing test")
        XCTAssertEqual(send(reply: true).payload(tagging: true), ";;tf ;;re Fix the failing test")
        XCTAssertEqual(send(dictated: true).payload(tagging: true), ";;tf ;;v Fix the failing test")
        XCTAssertEqual(send(corrected: true, reply: true, dictated: true).payload(tagging: true),
                       ";;tf+ ;;re ;;v Fix the failing test")
    }
}
