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
    /// Pinned spell-checker identifier, chosen from what this machine offers.
    private var language: String

    init() {
        language = DraftLanguage.english.spellLanguage
        // Auto-detection OFF: macOS's own per-word guess let Spanish candidates
        // (and Spanish autocorrect) bleed into English prompts. The composer picks
        // the language per draft instead (`DraftLanguage`). Because its autocorrect
        // and spellcheck share NSSpellChecker.shared, this pins those too.
        checker.automaticallyIdentifiesLanguages = false
        checker.setLanguage(language)
    }

    /// Switch the shared checker — and with it the composer's autocorrect and
    /// spellcheck — to the draft's language.
    func setLanguage(_ draft: DraftLanguage) {
        language = draft.spellLanguage
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
