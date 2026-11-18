import XCTest
@testable import TypeFlow

/// ⌘K reads its prompt and schema from Application Support. A new user has no
/// TypeFlow folder there: the app must create it with everything ⌘K needs.
@MainActor
final class CoachFilesTests: XCTestCase {
    func testFreshInstallGetsEveryCoachFile() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeFlowTests-\(UUID().uuidString)/Application Support")
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))

        let dir = try EnglishCoach.writeCoachFiles(under: base)
        XCTAssertEqual(dir.path, base.appendingPathComponent("TypeFlow/coach").path)

        for prompt in ["coach.md", "reply.md"] {
            let text = try String(contentsOf: dir.appendingPathComponent(prompt), encoding: .utf8)
            XCTAssertTrue(text.contains("Single-word false friends"), prompt)
            XCTAssertTrue(text.contains("actually = actualmente"), prompt)
            XCTAssertTrue(text.contains("eventually = eventualmente"), prompt)
            XCTAssertTrue(text.contains("assist = asistir"), prompt)
        }
        for schema in ["schema.json", "reply-schema.json"] {
            let data = try Data(contentsOf: dir.appendingPathComponent(schema))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(json?["type"] as? String, "object", schema)
        }

        // A second launch rewrites them in place.
        XCTAssertNoThrow(try EnglishCoach.writeCoachFiles(under: base))
    }
}
