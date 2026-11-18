import Foundation

/// Deterministic autocorrect for common English contractions typed without the
/// apostrophe (e.g. "dont" → "don't", "im" → "I'm").
///
/// Deliberately a small *curated* map, NOT general autocorrect: these are coding
/// prompts, so we must never rewrite identifiers, flags, or filenames. Entries
/// that collide with real words or code tokens (`its`, `were`, `id`, `ill`,
/// `well`, `shell`, `lets`, …) are intentionally excluded.
enum ContractionCorrector {

    /// lowercase, apostrophe-less form → canonical contraction (straight ').
    /// Also includes the lone-pronoun fix "i" → "I".
    private static let map: [String: String] = [
        "i": "I",
        "dont": "don't", "doesnt": "doesn't", "didnt": "didn't",
        "cant": "can't", "wont": "won't",
        "wouldnt": "wouldn't", "couldnt": "couldn't", "shouldnt": "shouldn't",
        "mustnt": "mustn't",
        "isnt": "isn't", "arent": "aren't", "wasnt": "wasn't", "werent": "weren't",
        "hasnt": "hasn't", "havent": "haven't", "hadnt": "hadn't",
        "wouldve": "would've", "couldve": "could've", "shouldve": "should've",
        "im": "I'm", "ive": "I've",
        "youre": "you're", "youve": "you've", "youll": "you'll", "youd": "you'd",
        "theyre": "they're", "theyve": "they've", "theyll": "they'll", "theyd": "they'd",
        "weve": "we've", "wholl": "who'll", "whos": "who's",
        "whats": "what's", "thats": "that's", "whens": "when's",
        "wheres": "where's", "theres": "there's", "heres": "here's", "hows": "how's",
        "hes": "he's", "shes": "she's",
    ]

    /// The apostrophe-corrected form for `word`, or nil if it isn't a known
    /// contraction. Preserves a leading capital ("Dont" → "Don't"); I-words are
    /// always capitalized ("im" → "I'm").
    static func correction(for word: String) -> String? {
        guard let mapped = map[word.lowercased()] else { return nil }
        if mapped.hasPrefix("I") { return mapped }
        if let first = word.first, first.isUppercase {
            return mapped.prefix(1).uppercased() + mapped.dropFirst()
        }
        return mapped
    }

    /// A capital for the word just finished (a space or , ? ! ; : typed right
    /// after it, caret after that), when it starts a sentence — the draft's start,
    /// or after . ? ! and a space or newline — or is "i'm", "i've", "i'll", "i'd".
    /// "give me" → "Give me", "done. it works" → "done. It works": the fixes the
    /// coach flagged most. Only a plain lowercase word (letters, apostrophes), so
    /// "--force", "readme.md", "src/" or "iOS" stay as typed; not after "e.g.",
    /// "etc.", "p.m." or "...", nor after ":" (a command on the next line). A Spanish
    /// "¿" / "¡" may open the sentence. Returns the first letter's range and its
    /// capital, or nil.
    static func sentenceCapital(in text: NSString, caret: Int) -> (range: NSRange, replacement: String)? {
        func scalar(_ i: Int) -> Unicode.Scalar? { Unicode.Scalar(text.character(at: i)) }
        func isSpace(_ i: Int) -> Bool { scalar(i).map(CharacterSet.whitespacesAndNewlines.contains) ?? false }
        func isAny(_ i: Int, _ set: String) -> Bool { scalar(i).map(set.unicodeScalars.contains) ?? false }
        func isWordChar(_ i: Int) -> Bool {
            guard let s = scalar(i) else { return false }
            return CharacterSet.letters.contains(s) || s == "'" || s == "’"
        }

        // The word that ends at the boundary just typed; before a space it may
        // carry its own punctuation ("done. ", "why? ").
        guard caret >= 2, caret <= text.length, isSpace(caret - 1) || isAny(caret - 1, ",?!;:") else { return nil }
        var end = caret - 1
        if isSpace(caret - 1) { while end > 0, isAny(end - 1, ".?!,;:") { end -= 1 } }
        var start = end
        while start > 0, isWordChar(start - 1) { start -= 1 }
        guard start < end else { return nil }
        let word = text.substring(with: NSRange(location: start, length: end - start))
        guard let first = word.first, first.isLowercase, word == word.lowercased() else { return nil }
        let capital = (NSRange(location: start, length: (String(first) as NSString).length), String(first).uppercased())
        if ["i'm", "i've", "i'll", "i'd"].contains(EnglishCoach.straight(word)) { return capital }

        // A sentence start: nothing before it, or whitespace after . ? !
        var p = start
        while p > 0, isAny(p - 1, "¿¡") { p -= 1 }
        guard p == 0 || isSpace(p - 1) else { return nil } // "foo.bar", "2nd"
        while p > 0, isSpace(p - 1) { p -= 1 }
        if p == 0 { return capital }
        guard isAny(p - 1, ".?!") else { return nil }
        if isAny(p - 1, ".") {
            if p >= 2, isAny(p - 2, ".") { return nil } // "wait... then"
            var t = p - 1
            while t > 0, isWordChar(t - 1) || isAny(t - 1, ".") { t -= 1 }
            let before = text.substring(with: NSRange(location: t, length: p - 1 - t)).lowercased()
            if ["e.g", "i.e", "etc", "vs", "cf", "approx", "eg", "ie", "a.m", "p.m"].contains(before) { return nil }
        }
        return capital
    }
}
