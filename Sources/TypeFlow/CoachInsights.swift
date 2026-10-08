import Foundation

/// Local, model-free feedback for the coaching panel, read from wingman-english's
/// vault: which fixes hit the learner's plan (`plan.md` target forms), and which
/// kinds of mistake keep coming back (`corpus/typeflow/`, the last 7 days).
///
/// wingman-english owns the measurement — `/diagnose` finds the patterns and
/// `/focus` writes the plan. This only reflects them back at the moment of
/// writing, which is when a reminder can still change the sentence.
enum CoachInsights {
    struct Snapshot {
        /// Taxonomy slugs from the plan's target-form table, in plan order.
        let targetForms: [String]
        /// A row's own narrowing of its slug (`tense-and-aspect` — present perfect).
        let qualifiers: [String: String]
        /// The plan says it hasn't been approved by the learner yet.
        let planIsDraft: Bool
        /// Fixes per category over the last 7 days, before the current result.
        let weekCounts: [String: Int]
    }

    /// A pattern needs 3 occurrences before wingman-english will name it
    /// (diagnose.md, the sufficiency floor) — the repeat badge uses the same bar.
    static let repeatThreshold = 3

    static func snapshot() -> Snapshot? {
        guard let vault = WingmanEnglishLog.activeVault() else { return nil }
        let (forms, qualifiers, draft) = readPlan(vault.appendingPathComponent("plan.md"))
        return Snapshot(targetForms: forms, qualifiers: qualifiers, planIsDraft: draft,
                        weekCounts: weekCounts(vault.appendingPathComponent("corpus/typeflow")))
    }

    /// Short, readable names for the taxonomy slugs (the slug stays the key).
    static let labels: [String: String] = [
        "articles-and-determiners": "articles",
        "subject-and-pronoun-reference": "subjects & pronouns",
        "preposition-choice": "prepositions",
        "phrasal-verbs-and-particles": "phrasal verbs",
        "tense-and-aspect": "verb tenses",
        "verb-complementation": "verb patterns",
        "noun-phrase-structure": "noun phrases",
        "clause-word-order": "word order",
        "false-friends-and-calques": "Spanish-shaped phrasing",
        "register-and-discourse": "register & flow",
        "mechanics-punctuation-and-capitalization": "punctuation & capitals",
        "spelling-and-variety-consistency": "spelling",
        "l1-switch": "Spanish → English",
        "unclassified": "other",
    ]

    static func label(_ slug: String) -> String { labels[slug] ?? slug }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    // MARK: - Reading the vault

    /// Target forms = the first taxonomy slug in backticks on each TABLE ROW of
    /// the "Target forms" section. Only rows: the section's prose also names the
    /// forms moved to "watching", which are not targets. Matching the closed slug
    /// list rather than a column index keeps this working when /focus rewrites
    /// the table's columns.
    private static func readPlan(_ url: URL) -> ([String], [String: String], Bool) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ([], [:], false) }
        let isDraft = text.prefix(300).uppercased().contains("NOT YET APPROVED")
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## ") && $0.lowercased().contains("target form") })
        else { return ([], [:], isDraft) }
        let known = Set(EnglishCoach.categories)
        var forms: [String] = []
        var qualifiers: [String: String] = [:]
        for line in lines[(start + 1)...] {
            if line.hasPrefix("## ") { break }
            guard line.hasPrefix("|") else { continue }
            for cell in line.split(separator: "|").map(String.init) {
                let parts = cell.components(separatedBy: "`")
                guard parts.count >= 3, known.contains(parts[1]) else { continue }
                let slug = parts[1]
                if !forms.contains(slug) {
                    forms.append(slug)
                    // "`tense-and-aspect` — present perfect" → "present perfect"
                    let rest = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: " —-–"))
                    if !rest.isEmpty { qualifiers[slug] = rest }
                }
                break // one target per row
            }
        }
        return (forms, qualifiers, isDraft)
    }

    /// Counts fix categories in the last 7 daily files (named by local date).
    private static func weekCounts(_ dir: URL) -> [String: Int] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let cutoff = f.string(from: Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date())
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var counts: [String: Int] = [:]
        for name in files where name.hasSuffix(".jsonl") && String(name.prefix(10)) >= cutoff {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let coach = obj["coach"] as? [String: Any],
                      let fixes = coach["fixes"] as? [[String: Any]] else { continue }
                for fix in fixes {
                    if let cat = fix["category"] as? String { counts[cat, default: 0] += 1 }
                }
            }
        }
        return counts
    }
}
