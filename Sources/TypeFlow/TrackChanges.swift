import AppKit

/// Word-level "track changes" from the learner's draft to the coach's version,
/// like suggestions in Google Docs: removed words struck through in red, added
/// words in green, everything else as written. One sentence to read instead of
/// comparing two versions by eye.
enum TrackChanges {
    private enum Op {
        case same(String), removed(String), added(String)
    }

    /// The panel's color language — each color means one thing, so a learner can
    /// read it at a glance: red = a mistake in your text, yellow = a small slip
    /// (capitals, punctuation, spelling), green = what's new in the corrected
    /// version, purple = your wingman-english plan. Everything else is neutral.
    static let slipColor = NSColor.systemYellow
    static let slipCategories: Set<String> = ["mechanics-punctuation-and-capitalization",
                                              "spelling-and-variety-consistency"]

    /// Marks each changed token as a slip when the change is only punctuation or
    /// only capitalization (the same word, removed and re-added within one run).
    private static func slips(_ ops: [Op]) -> [Bool] {
        var flags = Array(repeating: false, count: ops.count)
        var k = 0
        while k < ops.count {
            if case .same = ops[k] { k += 1; continue }
            var end = k
            while end < ops.count { if case .same = ops[end] { break }; end += 1 }
            var removed: [String] = [], added: [String] = []
            for op in ops[k..<end] {
                if case .removed(let t) = op { removed.append(t.lowercased()) }
                if case .added(let t) = op { added.append(t.lowercased()) }
            }
            for idx in k..<end {
                switch ops[idx] {
                case .removed(let t): flags[idx] = isPunct(t) || added.contains(t.lowercased())
                case .added(let t): flags[idx] = isPunct(t) || removed.contains(t.lowercased())
                case .same: break
                }
            }
            k = end
        }
        return flags
    }

    private static func isPunct(_ t: String) -> Bool {
        t.unicodeScalars.allSatisfy { !CharacterSet.alphanumerics.contains($0) }
    }

    /// Above this many token pairs the LCS table gets slow; fall back to plain.
    private static let maxCells = 250_000

    /// The draft rewritten as tracked changes, or nil when a diff wouldn't help
    /// (too long, or nothing in common at all).
    static func attributed(from draft: String, to native: String, size: CGFloat) -> NSAttributedString? {
        let a = tokens(EnglishCoach.straight(draft)), b = tokens(EnglishCoach.straight(native))
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= maxCells else { return nil }
        let ops = diff(a, b)
        guard ops.contains(where: { if case .same = $0 { return true } else { return false } }) else { return nil }

        let base = NSFont.systemFont(ofSize: size)
        let styles: (Op) -> (String, [NSAttributedString.Key: Any]) = { op in
            switch op {
            case .same(let t):
                return (t, [.font: base, .foregroundColor: NSColor.labelColor])
            case .removed(let t):
                return (t, [.font: base, .foregroundColor: NSColor.systemRed.withAlphaComponent(0.85),
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue])
            case .added(let t):
                return (t, [.font: NSFont.systemFont(ofSize: size, weight: .semibold),
                            .foregroundColor: NSColor.systemGreen])
            }
        }
        let out = NSMutableAttributedString()
        var previous: String?
        for op in ops {
            let (text, attrs) = styles(op)
            if let previous, needsSpace(between: previous, and: text) {
                out.append(NSAttributedString(string: " ", attributes: [.font: base]))
            }
            out.append(NSAttributedString(string: text, attributes: attrs))
            previous = text
        }
        return out
    }

    /// The two sides of the comparison: the draft with removed words marked (red,
    /// struck), and the coach's version with added words marked (green). Read top
    /// to bottom — yours, then corrected — instead of one merged line.
    static func sides(from draft: String, to native: String, size: CGFloat)
        -> (mine: NSAttributedString, corrected: NSAttributedString)? {
        // Straight vs curly quotes are the same character to a reader, not a change.
        let a = tokens(EnglishCoach.straight(draft)), b = tokens(EnglishCoach.straight(native))
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= maxCells else { return nil }
        let ops = diff(a, b)
        let slip = slips(ops)
        let base = NSFont.systemFont(ofSize: size)
        func build(_ keep: (Op, Bool) -> (String, [NSAttributedString.Key: Any])?) -> NSAttributedString {
            let out = NSMutableAttributedString()
            var previous: String?
            for (n, op) in ops.enumerated() {
                guard let (text, attrs) = keep(op, slip[n]) else { continue }
                if let previous, needsSpace(between: previous, and: text) {
                    out.append(NSAttributedString(string: " ", attributes: [.font: base]))
                }
                out.append(NSAttributedString(string: text, attributes: attrs))
                previous = text
            }
            return out
        }
        let mine = build { op, isSlip in
            switch op {
            case .same(let t): return (t, [.font: base, .foregroundColor: NSColor.secondaryLabelColor])
            case .removed(let t):
                let c = isSlip ? slipColor : NSColor.systemRed
                return (t, [.font: base, .foregroundColor: c, .strikethroughStyle: NSUnderlineStyle.single.rawValue])
            case .added: return nil
            }
        }
        let corrected = build { op, isSlip in
            switch op {
            case .same(let t): return (t, [.font: NSFont.systemFont(ofSize: size + 1, weight: .medium),
                                           .foregroundColor: NSColor.labelColor])
            case .added(let t): return (t, [.font: NSFont.systemFont(ofSize: size + 1, weight: .bold),
                                            .foregroundColor: isSlip ? slipColor : NSColor.systemGreen])
            case .removed: return nil
            }
        }
        return (mine, corrected)
    }

    /// Character ranges in `current` that the coach removed or replaced from the
    /// checked `draft` — marked in the composer's own text box, so the panel
    /// doesn't repeat the draft. After the draft is edited, a mark stays only on
    /// a draft word that is still there: fix it by hand and its mark goes, and
    /// words typed since are never marked (the coach hasn't seen them).
    static func removedRanges(from draft: String, to native: String, in current: String)
        -> [(range: NSRange, slip: Bool)] {
        // `straight` swaps one character for one, so the ranges still index `current`.
        let a = tokens(EnglishCoach.straight(draft)), b = tokens(EnglishCoach.straight(native))
        let c = tokenRanges(EnglishCoach.straight(current))
        guard !a.isEmpty, !b.isEmpty, !c.isEmpty, a.count * b.count <= maxCells,
              a.count * c.count <= maxCells else { return [] }
        // Draft token index → slip flag, for each token the coach removed.
        let ops = diff(a, b)
        let slip = slips(ops)
        var removed: [Int: Bool] = [:]
        var i = 0
        for (n, op) in ops.enumerated() {
            switch op {
            case .same: i += 1
            case .removed: removed[i] = slip[n]; i += 1
            case .added: break
            }
        }
        // Walk the draft → current diff: a draft token still present keeps its mark.
        var ranges: [(NSRange, Bool)] = []
        var d = 0, k = 0
        for op in diff(a, c.map(\.0)) {
            switch op {
            case .same:
                if let s = removed[d] { ranges.append((c[k].1, s)) }
                d += 1; k += 1
            case .removed: d += 1
            case .added: k += 1
            }
        }
        return ranges
    }

    private static func tokenRanges(_ s: String) -> [(String, NSRange)] {
        let pattern = #"[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*|[^\s\p{L}\p{N}]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { (ns.substring(with: $0.range), $0.range) }
    }

    /// Words (keeping contractions and hyphenated words whole) and single
    /// punctuation marks; whitespace is dropped and re-inserted on render.
    private static func tokens(_ s: String) -> [String] {
        let pattern = #"[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*|[^\s\p{L}\p{N}]"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// Longest-common-subsequence diff; deletions are emitted before insertions
    /// within a changed run so each run reads "old → new".
    private static func diff(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [Op] = []
        var removed: [Op] = [], added: [Op] = []
        func flush() {
            // An added mark that attaches leftward ("Good, I'd") goes before the
            // removed words, so it sticks to the kept word, not a struck one.
            var lead: [Op] = []
            while case .added(let t)? = added.first, t.count == 1, let c = t.first, noSpaceBefore.contains(c),
                  !removed.isEmpty {
                lead.append(added.removeFirst())
            }
            ops += lead + removed + added; removed = []; added = []
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                flush(); ops.append(.same(a[i])); i += 1; j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                added.append(.added(b[j])); j += 1
            } else {
                removed.append(.removed(a[i])); i += 1
            }
        }
        flush()
        return ops
    }

    private static let noSpaceBefore: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "]", "}", "’", "”", "%", "…", "—"]
    private static let noSpaceAfter: Set<Character> = ["(", "[", "{", "“", "‘", "—", "/"]

    private static func needsSpace(between previous: String, and next: String) -> Bool {
        if let first = next.first, next.count == 1, noSpaceBefore.contains(first) { return false }
        if let last = previous.last, previous.count == 1, noSpaceAfter.contains(last) { return false }
        return true
    }
}

/// A 1-pt hairline used between sections of the coaching panel. Its height is
/// REQUIRED: with only an intrinsic size it was the weakest-hugging view in the
/// stack, so it absorbed slack — a tall gray block that pushed the score, the
/// tracked sentence and the changes out of view.
final class SeparatorLine: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    // Paint `bounds`, never `dirtyRect`: since macOS 14 views don't clip to
    // bounds by default, so dirtyRect can cover the rows above and below — and
    // `fill()` copies rather than blends, which erased their text.
    override func draw(_ dirtyRect: NSRect) {
        // separatorColor is nearly invisible on the HUD blur; a light hairline reads.
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        bounds.fill(using: .sourceOver)
    }
}
