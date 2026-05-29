import AppKit

/// Inline WORD completion: finishes the word you're currently typing
/// (e.g. "becom" → "become") using the system dictionary via `NSSpellChecker`.
///
/// Local, instant (a synchronous dictionary lookup — no debounce needed), and
/// multilingual: `automaticallyIdentifiesLanguages` lets it complete English and
/// Spanish without us picking a language. No LLM, no network, no rate limiting.
@MainActor
final class WordCompleter {
    private let checker = NSSpellChecker.shared
    private let tag = NSSpellChecker.uniqueSpellDocumentTag()
    /// Don't suggest until the partial word is at least this many letters.
    private let minPartial = 2
    /// Pinned English identifier — the composer is English-only by design. Chosen
    /// from what this machine's spell checker actually offers.
    private let language: String

    init() {
        let available = checker.availableLanguages
        language = available.first(where: { $0 == "en_US" })
            ?? available.first(where: { $0.hasPrefix("en") })
            ?? "en"
        // English-only: turn OFF auto-detection. Otherwise Spanish candidates
        // (and Spanish autocorrect) bleed into an English-only terminal. Because
        // the composer's autocorrect / spellcheck share NSSpellChecker.shared,
        // this also pins those to English.
        checker.automaticallyIdentifiesLanguages = false
        checker.setLanguage(language)
    }

    /// The gray suffix to display after the caret, or nil if there's no
    /// confident completion for the word currently being typed.
    func completion(in fullText: String, caret: Int) -> String? {
        let ns = fullText as NSString
        guard caret > 0, caret <= ns.length else { return nil }

        // Walk back from the caret over letters to find the current partial word.
        var start = caret
        while start > 0 {
            let unit = ns.character(at: start - 1)
            guard let scalar = Unicode.Scalar(unit),
                  CharacterSet.letters.contains(scalar) else { break }
            start -= 1
        }
        let length = caret - start
        guard length >= minPartial else { return nil }

        let range = NSRange(location: start, length: length)
        let typed = ns.substring(with: range)
        guard let candidates = checker.completions(
                forPartialWordRange: range, in: fullText,
                language: language, inSpellDocumentWithTag: tag),
              !candidates.isEmpty else { return nil }

        // First candidate that genuinely extends what was typed (case-insensitive
        // prefix), returning only the not-yet-typed suffix.
        for candidate in candidates where candidate.count > typed.count {
            if candidate.lowercased().hasPrefix(typed.lowercased()) {
                return String(candidate.dropFirst(typed.count))
            }
        }
        return nil
    }
}
