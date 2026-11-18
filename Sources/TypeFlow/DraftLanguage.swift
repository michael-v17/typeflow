import AppKit
import NaturalLanguage

/// The draft's language, for the composer's local helpers: English (the default)
/// or Spanish (a draft written to get a quick ⌘K translation). Spanish switches the
/// shared spell checker to Spanish and pauses the English-only helpers, so Spanish
/// words are no longer "corrected" into English.
enum DraftLanguage: String {
    case english = "EN", spanish = "ES"

    /// On-device guess, constrained to English vs Spanish. Nil when there isn't
    /// enough text to tell — the caller keeps the language it has. Spanish-only
    /// characters (ñ, ¿, ¡, accented vowels) decide it from the first word.
    static func detect(_ text: String) -> DraftLanguage? {
        if text.contains(where: { "ñÑ¿¡áéíóúÁÉÍÓÚ".contains($0) }) { return .spanish }
        let words = text.split(whereSeparator: { !$0.isLetter }).count
        guard words >= 2 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .spanish]
        recognizer.processString(text)
        guard let (lang, p) = recognizer.languageHypotheses(withMaximum: 1).first,
              p >= (words >= 3 ? 0.65 : 0.8) else { return nil }
        return lang == .spanish ? .spanish : .english
    }

    /// The identifier this machine's spell checker offers for the language.
    var spellLanguage: String {
        let available = NSSpellChecker.shared.availableLanguages
        switch self {
        case .english:
            return available.first(where: { $0 == "en_US" })
                ?? available.first(where: { $0 == "en" })
                ?? available.first(where: { $0.hasPrefix("en") }) ?? "en"
        case .spanish:
            return available.first(where: { $0 == "es" })
                ?? available.first(where: { $0.hasPrefix("es") }) ?? "es"
        }
    }
}
