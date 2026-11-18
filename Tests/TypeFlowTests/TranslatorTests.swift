import NaturalLanguage
import XCTest
@testable import TypeFlow

/// ⌥⌘T / right-click → Translate: a real English ↔ Spanish translation with
/// Apple's on-device Translation framework. Skipped (not failed) on a Mac where
/// the two languages aren't downloaded yet.
final class TranslatorTests: XCTestCase {
    private func translate(_ text: String) async throws -> (text: String, from: DraftLanguage, to: DraftLanguage) {
        do {
            return try await Translator.translate(text)
        } catch Translator.Failure.notDownloaded {
            throw XCTSkip("English ↔ Spanish isn't downloaded on this Mac (Translation Languages)")
        }
    }

    private func language(of text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .spanish]
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    func testEnglishBecomesSpanish() async throws {
        let r = try await translate("The tests have been failing since yesterday because the mock returns an empty list.")
        XCTAssertEqual(r.from, .english)
        XCTAssertEqual(r.to, .spanish)
        XCTAssertEqual(language(of: r.text), .spanish, r.text)
    }

    func testSpanishBecomesEnglish() async throws {
        let r = try await translate("Las pruebas fallan desde ayer porque el mock devuelve una lista vacía.")
        XCTAssertEqual(r.from, .spanish)
        XCTAssertEqual(r.to, .english)
        XCTAssertEqual(language(of: r.text), .english, r.text)
        XCTAssertTrue(r.text.lowercased().contains("yesterday"), r.text)
    }
}
