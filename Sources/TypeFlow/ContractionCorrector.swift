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
}
