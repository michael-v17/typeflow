import Foundation
import Translation

// ⌥⌘T's translator on the bench's Spanish drafts: Apple Translation, es → en,
// the same call as Translator.swift. Build: swiftc -O scripts/coach-bench/apple-translate.swift -o /tmp/tf-bench-translate
// Run: /tmp/tf-bench-translate scripts/coach-bench/translate.json
let path = CommandLine.arguments[1]
let drafts = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
let session = TranslationSession(installedSource: Locale.Language(identifier: "es"),
                                 target: Locale.Language(identifier: "en"))
for draft in drafts {
    let started = Date()
    let out = try await session.translate(draft).targetText
    print(String(format: "%.2fs  ", Date().timeIntervalSince(started)) + out)
}
