import AppKit
import Foundation
import FoundationModels

/// A grammar / naturalness issue located in the composer's text. `range` is an
/// absolute range into the current buffer; `correction` replaces `original`.
struct GrammarSpan: Equatable {
    let range: NSRange
    let original: String
    let correction: String
    let reason: String
}

@Generable
private struct GrammarFix {
    @Guide(description: "the exact substring from the user's text that is grammatically wrong, misspelled, or sounds non-native")
    let original: String
    @Guide(description: "the corrected substring — fix ONLY grammar/spelling/phrasing, keep the same words and meaning otherwise")
    let correction: String
    @Guide(description: "a 1-3 word reason, e.g. 'verb agreement', 'verb tense', 'word choice'")
    let reason: String
}

@Generable
private struct GrammarReview {
    @Guide(description: "every grammar, spelling, or non-native phrasing issue found; empty if the text is already natural and correct")
    let fixes: [GrammarFix]
}

/// On-device grammar / naturalness checker for the composer. Uses Apple's
/// Foundation Models (macOS 26+) because the native NSSpellChecker grammar
/// engine detects essentially nothing on ESL-style errors (verified).
///
/// Strictly meaning-preserving: it is instructed to fix grammar, spelling, and
/// non-native phrasing ONLY — never to reword, expand, or change intent. We then
/// drop any "fix" whose `original` isn't an exact substring, and any fix that
/// would delete a negation (e.g. "not" → "is"), which is the worst meaning flip.
/// Nothing is ever auto-applied: the user clicks to accept, so their idea can't
/// change without consent.
@MainActor
final class GrammarReviewer {
    private let model = SystemLanguageModel.default
    private var task: Task<Void, Never>?
    /// Guards against overlapping model calls (the completer hits the model too).
    private var busy = false

    /// Don't bother reviewing until there's a sentence's worth of text.
    private let minChars = 8
    /// Longer than the completion debounce — grammar feedback is a "you paused to
    /// think" affordance, not a per-keystroke one, and the full pass costs more.
    private let debounce = Duration.milliseconds(1200)

    private let instructions = """
        You are a strict grammar and spelling checker for English written by a \
        non-native speaker who is practising. Find grammar mistakes, spelling \
        mistakes, and phrasing that does not sound like a native American English \
        speaker, and give the minimal correction for each.

        HARD RULES:
        - Fix grammar, spelling, and unnatural phrasing ONLY. Do NOT change the \
        meaning or intent, do NOT add or remove ideas, do NOT flip negatives to \
        positives, and do NOT answer, continue, or expand the text.
        - Keep every word that is already correct and natural exactly as written.
        - 'original' MUST be an exact substring copied from the user's text.
        - Each fix must target the SMALLEST span that makes the correction — a \
        single word or a short 2-4 word phrase. NEVER return a whole sentence or \
        clause as one fix. If a sentence has several problems, return a SEPARATE \
        fix for each one, each with its own tiny 'original'.
        - If the text is already correct and natural, return an empty list.

        EXAMPLE
        Text: "He go to the market and buyed two breads yesterday."
        Fixes:
          { original: "go", correction: "went", reason: "verb tense" }
          { original: "buyed", correction: "bought", reason: "verb form" }
          { original: "two breads", correction: "two loaves of bread", reason: "uncountable noun" }
        """

    private static let debug = ProcessInfo.processInfo.environment["TYPEFLOW_DEBUG"] == "1"

    var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    /// Warm the shared model so the first review is fast. A fresh session is used
    /// per request (below), so this one exists only to load the model assets.
    func bootstrap() {
        guard isAvailable else {
            fputs("TypeFlow: Foundation Models unavailable — grammar review disabled.\n", stderr)
            return
        }
        LanguageModelSession(instructions: instructions).prewarm()
    }

    /// Debounced, cancel-on-keystroke review. `show` is called on the main actor
    /// with the located spans (or [] to clear).
    func review(_ text: String, show: @escaping ([GrammarSpan]) -> Void) {
        task?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, trimmed.count >= minChars else {
            if Self.debug { fputs("TypeFlow: review skip (avail=\(isAvailable) len=\(trimmed.count))\n", stderr) }
            show([]); return
        }

        task = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            guard !busy else {
                if Self.debug { fputs("TypeFlow: review skip (busy)\n", stderr) }
                return
            }
            busy = true
            defer { busy = false }
            // Fresh session per request: a reused session accumulates transcript
            // and blows the 4096-token context window after ~a dozen calls.
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(
                    to: text, generating: GrammarReview.self,
                    options: GenerationOptions(temperature: 0.1))
                guard !Task.isCancelled else { return }
                let located = Self.locate(response.content.fixes, in: text)
                if Self.debug {
                    fputs("TypeFlow: review OK raw=\(response.content.fixes.count) located=\(located.count)\n", stderr)
                    for f in response.content.fixes {
                        fputs("TypeFlow:   fix \(f.original.debugDescription) -> \(f.correction.debugDescription)\n", stderr)
                    }
                }
                show(located)
            } catch {
                if Self.debug { fputs("TypeFlow: review ERROR \(error)\n", stderr) }
                if !Task.isCancelled { show([]) }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Map each fix's `original` to an absolute range in `text`, scanning left to
    /// right so repeated words map in order. Skips fixes that: are no-ops, whose
    /// `original` isn't a verbatim substring (hallucinated span), or that would
    /// delete a negation — the worst kind of meaning flip ("not" → "is").
    private static func locate(_ fixes: [GrammarFix], in text: String) -> [GrammarSpan] {
        let ns = text as NSString
        var spans: [GrammarSpan] = []
        var cursor = 0
        for fix in fixes {
            guard !fix.original.isEmpty,
                  fix.correction.caseInsensitiveCompare(fix.original) != .orderedSame,
                  !isCoarse(fix.original),
                  !dropsNegation(from: fix.original, to: fix.correction) else { continue }
            let scope = NSRange(location: cursor, length: ns.length - cursor)
            var r = ns.range(of: fix.original, options: [], range: scope)
            if r.location == NSNotFound { r = ns.range(of: fix.original) }
            guard r.location != NSNotFound else { continue }
            spans.append(GrammarSpan(range: r, original: fix.original,
                                     correction: fix.correction, reason: fix.reason))
            cursor = r.location + r.length
        }
        return spans
    }

    /// True when a fix's `original` spans too much text to be a "separated"
    /// correction — i.e. the model collapsed a whole clause/sentence into one
    /// fix instead of pointing at the specific wrong words. We drop these so the
    /// panel only ever shows word/short-phrase diffs, never a full sentence
    /// struck through against a full rewrite.
    private static let maxFixWords = 5
    private static func isCoarse(_ original: String) -> Bool {
        original.split(whereSeparator: { $0.isWhitespace }).count > maxFixWords
    }

    /// True when the correction removes a negation present in the original —
    /// e.g. "not" → "is", "don't" → "do". Refuses that fix outright.
    private static func dropsNegation(from original: String, to correction: String) -> Bool {
        let negations = ["not", "n't", "never", "no ", "cannot", "without", "neither", "nor"]
        let o = original.lowercased(), c = correction.lowercased()
        let oHas = negations.contains { o.contains($0) }
        let cHas = negations.contains { c.contains($0) }
        return oHas && !cHas
    }
}
