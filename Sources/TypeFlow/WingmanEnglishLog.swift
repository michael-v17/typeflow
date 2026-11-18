import Foundation

/// Everything the composer knows about one send — what goes to Claude, plus what
/// wingman-english needs to learn from it.
struct ComposerSend {
    /// What is sent to Claude (the coach's version when `corrected`).
    let text: String
    /// What the user actually wrote.
    let draft: String
    let dictated: Bool
    /// The ⌘K result for this exact draft, if the user checked it.
    let coach: CoachResult?
    /// True when `text` is the coach's correction/translation rather than the draft.
    let corrected: Bool
    /// The Claude session's folder, when known (nil for a clipboard copy).
    let cwd: String?
    /// Where the text went: Claude (via Warp), the clipboard for use elsewhere,
    /// or nowhere — a ⌘K check whose draft was abandoned without a send or copy.
    var destination: Destination = .claude
    /// The draft answers a message pasted as context (⌘⇧V). The message itself is
    /// never logged or sent — only that this was a reply.
    var reply = false

    enum Destination: String, Encodable {
        case claude, clipboard, unsent
    }

    /// Provenance prefixes read by wingman-english's capture hook
    /// (`.claude/hooks/capture-prompt.mjs`, `PREFIXES`). Byte-identical
    /// cross-repo contract:
    ///   `;;tf+ ` the coach wrote the sent text → authorship `corrected`, never analysed
    ///   `;;tf `  typed in TypeFlow, sent as written → authorship `assisted`
    ///   `;;re `  a reply to a message given as context → `mode: "reply"`
    ///   `;;v `   dictated → modality `spoken`
    var marker: String {
        (corrected ? ";;tf+ " : ";;tf ") + (reply ? ";;re " : "") + (dictated ? ";;v " : "")
    }

    /// What is pasted into Warp: `text`, prefixed with `marker` only when the
    /// "Tag sends for the learning log" setting is on (off by default, so a
    /// public install sends exactly what the user wrote).
    func payload(tagging: Bool = SendTags.isOn()) -> String {
        tagging ? marker + text : text
    }
}

/// The "Tag sends for the learning log" setting: whether sends to Warp carry the
/// provenance prefixes (`ComposerSend.marker`). Off unless set — only someone
/// running wingman-english's capture hook needs them. Turn on with the ⋯ menu or
/// `defaults write <TypeFlow's bundle id> TypeFlowTagSends -bool true`.
enum SendTags {
    static let defaultsKey = "TypeFlowTagSends"
    static let title = "Tag sends for the learning log"

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey) // false when unset
    }

    static func set(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: defaultsKey)
    }
}

/// Writes the evidence the capture hook can't see: for every send or copy the
/// user checked with ⌘K, their own draft plus the coach's analysis, appended to
/// `<vault>/corpus/typeflow/YYYY-MM-DD.jsonl` in wingman-english's vault.
/// (A clipboard copy never reaches Claude, so the hook has no record of it at all.)
/// A check that is never sent or copied is logged too, once its draft is
/// abandoned (deleted, session gone, app quit), as `destination: "unsent"`.
///
/// The hook records what reached Claude; for a `;;tf+` send that's the coach's
/// text, so without this file the learner's actual attempt would be lost.
/// Unchecked sends need nothing here — the hook already has the full text.
///
/// Mirrors the hook's rules: no vault configured → write nothing (capture is
/// armed by /init-learner), excluded directories are skipped, and a vault owned
/// by another OS user is refused.
enum WingmanEnglishLog {
    typealias Send = ComposerSend
    /// The learning-log repo config (it holds `vaultPath`). No default: set it with
    /// `defaults write <TypeFlow's bundle id> WingmanEnglishConfig <path>`. Unset, it reads
    /// /dev/null, which holds no config, so nothing is logged.
    private static let repoConfig = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "WingmanEnglishConfig")
        .map { ($0 as NSString).expandingTildeInPath } ?? "/dev/null")

    private struct Record: Encodable {
        let ts: String
        let cwd: String?
        let kind = "prose"
        /// "corrected" (sent the coach's text, `;;tf+`), "original" (`;;tf`), or
        /// "none" (unsent check).
        let sent: String
        /// "claude" (the hook also has a raw record), "clipboard" or "unsent" (it doesn't).
        let destination: Send.Destination
        let modality: String
        /// The draft was typed in TypeFlow (Apple autocorrect + live underlines),
        /// so it is assisted, never `self` — same class as a `;;tf` message.
        let authorship = "assisted"
        let draft: String
        /// Omitted for an unsent check — nothing went anywhere.
        let sentText: String?
        let coach: CoachResult
        let coachModel: String
        /// `CoachProvider.logID`; a "local:" prefix means an on-device model.
        /// Omitted when unknown (the demo result).
        let coachProvider: String?
        /// "reply" when the draft answers a pasted message (its idea → the coach's
        /// reply; `coach.asked` keeps only each question's kind). Omitted otherwise.
        /// The message itself is never stored.
        let mode: String?

        enum CodingKeys: String, CodingKey {
            case ts, cwd, kind, sent, destination, modality, authorship, draft, coach, mode
            case sentText = "sent_text"
            case coachModel = "coach_model"
            case coachProvider = "coach_provider"
        }
    }

    /// Best-effort: a logging failure must never block or fail a send.
    static func record(_ send: ComposerSend) {
        guard let coach = send.coach,
              let vault = activeVault() else { return }
        if let cwd = send.cwd, isSkipped(cwd, vaultConfig(vault)) { return }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let record = Record(
            ts: iso.string(from: Date()), cwd: send.cwd,
            sent: send.destination == .unsent ? "none" : send.corrected ? "corrected" : "original",
            destination: send.destination,
            modality: send.dictated ? "spoken" : "written",
            draft: send.draft, sentText: send.destination == .unsent ? nil : send.text, coach: coach,
            coachModel: coach.model, coachProvider: coach.provider.isEmpty ? nil : coach.provider,
            mode: send.reply ? "reply" : nil)
        do {
            let dir = vault.appendingPathComponent("corpus/typeflow", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(localDate()).jsonl")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            var line = try encoder.encode(record)
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: file)
            }
        } catch {
            fputs("TypeFlow: wingman-english log failed: \(error)\n", stderr)
        }
    }

    // MARK: - Same resolution rules as capture-prompt.mjs

    /// The learner's vault, or nil when none is configured or it belongs to
    /// another OS user (the hook refuses those too).
    static func activeVault() -> URL? {
        guard let vault = resolveVault() else { return nil }
        if let owner = vaultConfig(vault)["owner"] as? String, owner != NSUserName() { return nil }
        return vault
    }

    /// `$WINGMAN_ENGLISH_VAULT`, else `vaultPath` from the repo's config.
    private static func resolveVault() -> URL? {
        if let env = ProcessInfo.processInfo.environment["WINGMAN_ENGLISH_VAULT"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        guard let path = json(at: repoConfig)?["vaultPath"] as? String else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// The vault's own config travels with the person and wins over the repo's.
    private static func vaultConfig(_ vault: URL) -> [String: Any] {
        json(at: vault.appendingPathComponent("wingman-english.json")) ?? json(at: repoConfig) ?? [:]
    }

    private static func isSkipped(_ cwd: String, _ cfg: [String: Any]) -> Bool {
        let list = cfg["skipCwds"] as? [String] ?? []
        return list.contains { entry in
            var abs = (entry as NSString).expandingTildeInPath
            while abs.count > 1 && abs.hasSuffix("/") { abs.removeLast() }
            return cwd == abs || cwd.hasPrefix(abs + "/")
        }
    }

    private static func json(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Local calendar date for the filename (bucket by `ts`, like the hook).
    private static func localDate() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
