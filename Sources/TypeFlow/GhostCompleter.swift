import Foundation
import FoundationModels

/// On-device completion source for the composer's inline ghost text.
///
/// Uses Apple's Foundation Models framework (macOS 26+) — the ~3B on-device
/// model. Everything runs locally; nothing leaves the machine, which keeps
/// TypeFlow's local-first constraint intact. Holds one debounced,
/// cancel-on-keystroke request at a time.
@MainActor
final class GhostCompleter {
    private let model = SystemLanguageModel.default
    private var task: Task<Void, Never>?
    /// Guards against overlapping model calls (grammar review hits the model too).
    private var busy = false

    /// Minimum prefix length before we bother asking for a completion.
    private let minPrefix = 4
    /// Idle time after the last keystroke before firing a request.
    private let debounce = Duration.milliseconds(300)

    // Few-shot framing: small on-device models otherwise treat a half-typed
    // sentence as a chat question and answer it ("Here are a few suggestions…")
    // instead of continuing it. Showing the Input→Continuation pattern makes them
    // imitate rather than converse.
    private let instructions = """
        You are an inline autocomplete (a Copilot-style ghost) for a developer \
        typing a prompt to an AI coding agent. Given the text so far after \
        "Input:", you FINISH the exact sentence they are in the middle of \
        writing, after "Continuation:".

        Your job is to complete THEIR intention — the thought they are clearly \
        already expressing — not to propose a new idea or the next sentence.

        Rules:
        - Output ONLY the words that come right after their text and finish the \
        current thought. It must read as one continuous sentence with the input.
        - Keep it short: usually just enough to finish the clause. A couple of \
        extra words are fine ONLY if they make the same intended idea complete.
        - Always English. NEVER repeat the input. NEVER explain, suggest, list \
        options, or add a preamble, a label, quotes, or a trailing colon.
        - If you can't tell what they intend, output nothing.

        Input: can you refactor this function to be more
        Continuation: readable and remove the duplicated logic

        Input: fix the bug where the modal doesn't
        Continuation: close when you click outside it

        Input: add a test that checks the parser handles empty
        Continuation: input without crashing

        Input: if someone wants to code in 2026 they need to know about
        Continuation: AI-assisted tooling and the fundamentals
        """

    var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    /// Warm the model once at app launch so the first real completion is fast.
    /// The composer is a persistent menu-bar app, so this stays hot for free.
    func bootstrap() {
        guard isAvailable else {
            fputs("TypeFlow: Foundation Models unavailable (\(model.availability)) — ghost text disabled.\n",
                  stderr)
            return
        }
        // A fresh session is used per request (a reused one accumulates transcript
        // and overflows the 4096-token window); this just warms the shared model.
        LanguageModelSession(instructions: instructions).prewarm()
    }

    /// Debounced. Cancels any in-flight request, waits out the debounce, then
    /// asks for a short continuation. `show` is invoked on the main actor with
    /// a display-ready suggestion (leading space added when continuing
    /// mid-sentence), or "" to clear.
    func requestCompletion(prefix: String, show: @escaping (String) -> Void) {
        task?.cancel()
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, trimmed.count >= minPrefix else { show(""); return }

        task = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, !busy else { return }
            busy = true
            defer { busy = false }
            // Fresh session per request — a reused session accumulates transcript
            // and overflows the context window after a dozen-ish calls.
            let session = LanguageModelSession(instructions: instructions)

            let tail = String(prefix.suffix(1000)) // keep well inside the context window
            do {
                // Mirror the few-shot format so the model fills "Continuation:"
                // rather than answering the fragment as a chat prompt.
                let response = try await session.respond(
                    to: "Input: \(tail)\nContinuation:",
                    options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 16))
                guard !Task.isCancelled else { return }

                var text = Self.clean(response.content)
                // Drop empties, chat/meta lapses, and plain echoes of the input.
                let echoed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased().hasSuffix(text.lowercased())
                guard !text.isEmpty, !Self.looksLikeMeta(text), !(echoed && text.count >= 3)
                else { show(""); return }

                // Add a leading space when gluing onto a mid-sentence word.
                if let last = prefix.last, !last.isWhitespace,
                   let first = text.first, first.isLetter || first.isNumber {
                    text = " " + text
                }
                show(text)
            } catch {
                // guardrailViolation / rateLimited / exceededContextWindowSize, etc.
                // Inline completion is best-effort: drop the ghost, never surface an error.
                if !Task.isCancelled { show("") }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - Output sanitizing

    /// Normalize raw model output: one line, strip an echoed "Continuation:"
    /// label and a single layer of wrapping quotes, trim.
    private static func clean(_ raw: String) -> String {
        // Keep only the first line: the model tends to keep going and spill extra
        // few-shot "Input:/Continuation:" pairs onto the following lines.
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nl = t.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            t = String(t[..<nl])
        }
        // Strip an echoed leading label.
        for label in ["Continuation:", "continuation:", "Output:", "You:"] where t.hasPrefix(label) {
            t = String(t.dropFirst(label.count))
        }
        // Cut anything from an inline new-example marker onward.
        for marker in ["Input:", "Continuation:"] {
            if let r = t.range(of: marker) { t = String(t[..<r.lowerBound]) }
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a single layer of wrapping quotes.
        if t.count >= 2, let f = t.first, let l = t.last,
           (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            t = String(t.dropFirst().dropLast())
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the output is the model lapsing into chat/assistant mode — a
    /// preamble, a meta description ("Here are a few suggestions…"), an echoed
    /// label, or a refusal — rather than a genuine continuation of the text.
    private static func looksLikeMeta(_ s: String) -> Bool {
        let l = s.lowercased()
        let prefixes = ["here are", "here's", "here is", "sure,", "sure!",
                        "certainly", "of course", "i'd be happy", "i can help",
                        "the continuation", "continuation:", "input:", "output:",
                        "you:", "text:"]
        if prefixes.contains(where: { l.hasPrefix($0) }) { return true }
        let substrings = ["suggestions for", "could follow", "following text",
                          "as an ai", "i'm sorry", "i cannot", "i am unable"]
        return substrings.contains(where: { l.contains($0) })
    }
}
