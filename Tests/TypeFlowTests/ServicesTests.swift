import AppKit
import XCTest
@testable import TypeFlow

/// Right-click → "Correct with TypeFlow" / "Translate with TypeFlow": the
/// NSServices entries the app bundle declares (scripts/make-app.sh writes its
/// Info.plist) and the provider methods macOS calls with the selected text.
final class ServicesTests: XCTestCase {
    /// The NSServices array of the Info.plist that make-app.sh writes.
    private func declaredServices() throws -> [[String: Any]] {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/make-app.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "<?xml"))
        let end = try XCTUnwrap(text.range(of: "</plist>"))
        let xml = Data(text[start.lowerBound..<end.upperBound].utf8)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any])
        return try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
    }

    func testTheBundleDeclaresBothRightClickEntries() throws {
        let services = try declaredServices()
        let titles = services.compactMap { ($0["NSMenuItem"] as? [String: String])?["default"] }
        XCTAssertEqual(titles, ["Correct with TypeFlow", "Translate with TypeFlow"])
        XCTAssertEqual(services.compactMap { $0["NSMessage"] as? String }, ["correctSelection", "translateSelection"])
        for service in services {
            XCTAssertEqual(service["NSSendTypes"] as? [String], ["public.utf8-plain-text"])
        }
    }

    func testTheProviderAnswersEveryDeclaredMessage() throws {
        let provider = ServiceProvider()
        for message in try declaredServices().compactMap({ $0["NSMessage"] as? String }) {
            XCTAssertTrue(provider.responds(to: NSSelectorFromString(message + ":userData:error:")), message)
        }
    }

    /// A private, named pasteboard: the user's clipboard is never touched.
    private func pasteboard(_ text: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("TypeFlowTests-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString(text, forType: .string)
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    func testTheSelectionReachesCorrectAndTranslate() {
        let provider = ServiceProvider()
        var corrected: String?, translated: String?
        provider.onCorrect = { corrected = $0 }
        provider.onTranslate = { translated = $0 }
        var error: NSString?
        provider.correctSelection(pasteboard("can you explain me why"), userData: nil, error: &error)
        provider.translateSelection(pasteboard("¿dónde está la estación?"), userData: nil, error: &error)
        XCTAssertEqual(corrected, "can you explain me why")
        XCTAssertEqual(translated, "¿dónde está la estación?")
        XCTAssertNil(error)
    }

    func testABlankSelectionIsIgnored() {
        let provider = ServiceProvider()
        var calls = 0
        provider.onCorrect = { _ in calls += 1 }
        provider.onTranslate = { _ in calls += 1 }
        var error: NSString?
        provider.correctSelection(pasteboard("  \n "), userData: nil, error: &error)
        provider.translateSelection(pasteboard(""), userData: nil, error: &error)
        XCTAssertEqual(calls, 0)
    }
}
