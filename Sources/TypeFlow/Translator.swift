import Foundation
import NaturalLanguage
import Translation

/// English ↔ Spanish with Apple's Translation framework: on-device, free, offline
/// once the languages are downloaded (System Settings → General → Language &
/// Region → Translation Languages).
enum Translator {
    enum Failure: LocalizedError {
        case notDownloaded, unsupported
        var errorDescription: String? {
            switch self {
            case .notDownloaded:
                return "English ↔ Spanish isn't downloaded yet. Get it in System Settings → General → Language & Region → Translation Languages."
            case .unsupported:
                return "Apple Translation can't translate between English and Spanish on this Mac."
            }
        }
    }

    /// The other language: English → Spanish, Spanish → English.
    static func translate(_ text: String) async throws -> (text: String, from: DraftLanguage, to: DraftLanguage) {
        let from = source(of: text)
        let to: DraftLanguage = from == .english ? .spanish : .english
        let source = Locale.Language(identifier: from == .english ? "en" : "es")
        let target = Locale.Language(identifier: to == .english ? "en" : "es")
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: break
        case .supported: throw Failure.notDownloaded
        default: throw Failure.unsupported
        }
        let session = TranslationSession(installedSource: source, target: target)
        return (try await session.translate(text).targetText, from, to)
    }

    /// The first translation in a process takes 2–3 s, later ones ~0.7 s:
    /// translate a word at launch so the first ⌥⌘T is already fast.
    static func warmUp() {
        Task.detached(priority: .utility) { _ = try? await translate("Hello there") }
    }

    /// `DraftLanguage.detect` waits for 2+ words; a single word gets the
    /// recognizer's best guess, English when it can't tell.
    private static func source(of text: String) -> DraftLanguage {
        if let lang = DraftLanguage.detect(text) { return lang }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .spanish]
        recognizer.processString(text)
        return recognizer.dominantLanguage == .spanish ? .spanish : .english
    }
}
