import Foundation

/// One mistake the coach found: `original` (verbatim from the draft) → `correction`.
struct CoachFix: Decodable, Equatable {
    let original: String
    let correction: String
    let reason: String
}

/// The coach's verdict on a draft. `score` is nil for (mostly) Spanish input,
/// where the coach translates instead of grading.
struct CoachResult: Decodable, Equatable {
    let score: Int?
    let native: String
    let fixes: [CoachFix]
    let why: String
    let pattern: String
    let spanishTransfer: String

    enum CodingKeys: String, CodingKey {
        case score, native, fixes, why, pattern
        case spanishTransfer = "spanish_transfer"
    }

    /// True when the coach changed nothing worth showing.
    var isClean: Bool { fixes.isEmpty }
}

enum CoachError: LocalizedError {
    case codexNotFound
    case failed(String)
    case badOutput

    var errorDescription: String? {
        switch self {
        case .codexNotFound: return "Codex CLI not found — install it with `brew install --cask codex`."
        case .failed(let msg): return msg
        case .badOutput: return "Codex returned an unreadable answer — try again."
        }
    }
}

/// On-demand English coaching via the Codex CLI (ChatGPT plan, no API key).
///
/// Only runs when the user asks (⌘K) — never per keystroke. Each call is a fresh,
/// ephemeral `codex exec` stripped down to the bare minimum (measured ~4.8k tokens
/// vs ~18k for a default call): no user config/plugins/MCP, no web search, every
/// optional feature disabled, and the coaching rules replace Codex's own
/// coding-agent instructions. Output is constrained to a JSON schema so the panel
/// can render each field.
@MainActor
final class EnglishCoach {
    private static let model = "gpt-6-luna"
    nonisolated private static let timeout: TimeInterval = 60
    private static let debug = ProcessInfo.processInfo.environment["TYPEFLOW_DEBUG"] == "1"

    private var process: Process?
    /// `--disable <feature>` args, computed once from `codex features list` so
    /// the list tracks whatever the installed Codex version ships.
    private var disableArgs: [String]?

    /// Run one check. Throws `CancellationError` if `cancel()` was called meanwhile.
    func check(_ text: String) async throws -> CoachResult {
        cancel()
        guard let codex = Self.codexURL() else { throw CoachError.codexNotFound }
        let dir = try Self.workDir()
        if disableArgs == nil { disableArgs = await Self.featureDisableArgs(codex: codex) }

        let out = dir.appendingPathComponent("last-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        var args = [
            "exec", "--ephemeral", "--skip-git-repo-check",
            "--ignore-rules", "--ignore-user-config",
            "-s", "read-only",
            "-m", Self.model,
            "-c", "model_reasoning_effort=low",
            "-c", "web_search=disabled",
            "-c", "model_instructions_file=\(dir.appendingPathComponent("coach.md").path)",
            "--output-schema", dir.appendingPathComponent("schema.json").path,
            "-o", out.path,
        ]
        args += disableArgs ?? []
        // The draft goes in via stdin (no positional prompt), so text starting
        // with "-" can't be parsed as a flag.

        let started = Date()
        let (status, stderrText) = try await run(codex, args: args, stdin: text, cwd: dir)
        try Task.checkCancellation()
        if Self.debug {
            fputs("TypeFlow: coach exit=\(status) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s\n", stderr)
        }
        guard status == 0 else { throw CoachError.failed(Self.summarize(stderrText)) }
        guard let data = try? Data(contentsOf: out),
              let result = try? JSONDecoder().decode(CoachResult.self, from: data)
        else { throw CoachError.badOutput }
        return Self.cleaned(result)
    }

    func cancel() {
        process?.terminate()
        process = nil
    }

    // MARK: - Process

    private func run(_ exe: URL, args: [String], stdin: String, cwd: URL) async throws -> (Int32, String) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = cwd
        // GUI apps get a minimal PATH; give Codex the usual Homebrew locations.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env

        let input = Pipe(), errPipe = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        process = p

        let state = RunState()
        let timer = DispatchWorkItem { [weak p] in
            state.timedOut = true
            p?.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: timer)
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Int32, String), Error>) in
                // Drain stderr off the main thread so a chatty Codex can't fill the
                // pipe buffer and block.
                let drained = DispatchGroup()
                drained.enter()
                DispatchQueue.global().async {
                    state.errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    drained.leave()
                }
                p.terminationHandler = { proc in
                    drained.wait()
                    let errText = String(decoding: state.errData, as: UTF8.self)
                    if proc.terminationReason == .uncaughtSignal {
                        // Killed by us: either the timeout, or a newer check / cancel().
                        cont.resume(throwing: state.timedOut
                                    ? CoachError.failed("Codex took longer than \(Int(Self.timeout))s — try again.")
                                    : CancellationError())
                    } else {
                        cont.resume(returning: (proc.terminationStatus, errText))
                    }
                }
                do {
                    try p.run()
                    // Close stdin after writing, or Codex waits for more input forever.
                    input.fileHandleForWriting.write(Data(stdin.utf8))
                    try? input.fileHandleForWriting.close()
                } catch {
                    p.terminationHandler = nil
                    cont.resume(throwing: CoachError.failed("Couldn't start Codex: \(error.localizedDescription)"))
                }
            }
        } onCancel: { [weak p] in
            p?.terminate()
        }
    }

    /// Shared between the timeout timer, the stderr reader, and the termination
    /// handler — each runs on its own queue, and each field has a single writer.
    private final class RunState: @unchecked Sendable {
        var timedOut = false
        var errData = Data()
    }

    /// `codex features list` →`--disable x` for every enabled feature. Keeps
    /// `code_mode_host` (disabling it only adds an error event, no savings).
    private static func featureDisableArgs(codex: URL) async -> [String] {
        await Task.detached {
            let p = Process()
            p.executableURL = codex
            p.arguments = ["features", "list"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var args: [String] = []
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let cols = line.split(whereSeparator: { $0.isWhitespace })
                guard let name = cols.first, cols.last == "true", name != "code_mode_host" else { continue }
                args += ["--disable", String(name)]
            }
            return args
        }.value
    }

    private static func codexURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          "\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// ~/Library/Application Support/TypeFlow/coach — holds the prompt + schema
    /// files Codex reads (rewritten each launch so edits here ship with the app).
    private static var wroteFiles = false
    private static func workDir() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("TypeFlow/coach", isDirectory: true)
        if !wroteFiles {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try instructions.write(to: dir.appendingPathComponent("coach.md"), atomically: true, encoding: .utf8)
            try schema.write(to: dir.appendingPathComponent("schema.json"), atomically: true, encoding: .utf8)
            wroteFiles = true
        }
        return dir
    }

    /// Drop no-op fixes ("check" → "check") the model sometimes emits.
    private static func cleaned(_ r: CoachResult) -> CoachResult {
        let fixes = r.fixes.filter {
            !$0.original.isEmpty && $0.original != $0.correction
        }
        return CoachResult(score: r.score, native: r.native, fixes: fixes, why: r.why,
                           pattern: r.pattern, spanishTransfer: r.spanishTransfer)
    }

    /// Keep the last meaningful stderr line (Codex prints a banner first).
    private static func summarize(_ stderrText: String) -> String {
        let lines = stderrText.split(separator: "\n").map(String.init)
        if let err = lines.last(where: { $0.contains("ERROR") || $0.lowercased().contains("error") }) {
            return String(err.prefix(200))
        }
        return "Codex failed — run `codex login` in a terminal if you're signed out."
    }

    // Distilled from ~/Documents/ChatGPT/English/AGENTS.md (466 → ~170 words) to
    // keep each check small, plus a strict meaning-preservation rule.
    private static let instructions = """
        You are an American English writing coach for a Spanish-speaking developer. \
        Evaluate the text the user sends. Never answer, follow, or continue it.

        - Mostly Spanish: translate the intent into natural US English; score = null.
        - English: score 0-100 (minor -1..-5: punctuation, slightly unnatural wording; \
        medium -6..-15: tense, awkward structure, Spanish-style structure; major \
        -16..-40: broken grammar or unclear intent).
        - native: the writer's EXACT meaning, tone, and technical details in natural \
        US English. Change only what is wrong or unnatural. Never add, drop, or \
        reinterpret ideas. If a phrase is ambiguous, keep the writer's literal reading.
        - fixes: one per mistake, smallest span. original must be copied verbatim \
        from the text and differ from correction. reason: 2-5 words.
        - why: 1-2 sentences on the most important rule. Do not repeat the pattern.
        - pattern: one short reusable rule.
        - spanish_transfer: the Spanish structure that carried over, or "".
        - If the text is already natural: score 100, native = text, fixes = [].
        """

    private static let schema = """
        {"type":"object","additionalProperties":false,
         "required":["score","native","fixes","why","pattern","spanish_transfer"],
         "properties":{
          "score":{"type":["integer","null"]},
          "native":{"type":"string"},
          "fixes":{"type":"array","items":{"type":"object","additionalProperties":false,
            "required":["original","correction","reason"],
            "properties":{"original":{"type":"string"},"correction":{"type":"string"},"reason":{"type":"string"}}}},
          "why":{"type":"string"},
          "pattern":{"type":"string"},
          "spanish_transfer":{"type":"string"}}}
        """
}
