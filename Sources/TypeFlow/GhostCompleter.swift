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
    private var session: LanguageModelSession?
    private var task: Task<Void, Never>?

    /// Minimum prefix length before we bother asking for a completion.
    private let minPrefix = 4
    /// Idle time after the last keystroke before firing a request.
    private let debounce = Duration.milliseconds(300)

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
        let s = LanguageModelSession(instructions: """
            You autocomplete the user's in-progress prompt to an AI coding agent.
            Given the text so far, output ONLY a short, natural continuation — a \
            few words, at most one clause — that should directly follow it. Do \
            not repeat their text, do not add quotes or any preamble. If you have \
            nothing useful to add, output nothing.
            """)
        s.prewarm()
        session = s
    }

    /// Debounced. Cancels any in-flight request, waits out the debounce, then
    /// asks for a short continuation. `show` is invoked on the main actor with
    /// a display-ready suggestion (leading space added when continuing
    /// mid-sentence), or "" to clear.
    func requestCompletion(prefix: String, show: @escaping (String) -> Void) {
        task?.cancel()
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, let session, trimmed.count >= minPrefix else { show(""); return }

        task = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            // One request per session — skip if the previous one is still going.
            guard !session.isResponding else { return }

            let tail = String(prefix.suffix(1000)) // keep well inside the context window
            do {
                let response = try await session.respond(
                    to: tail,
                    options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 16))
                guard !Task.isCancelled else { return }

                var text = response.content
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { show(""); return }

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
}
