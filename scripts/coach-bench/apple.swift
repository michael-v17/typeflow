import Foundation
import FoundationModels

@Generable struct Fix {
    var original: String
    var correction: String
    var reason: String
    @Guide(description: "category slug from the instructions")
    var category: String
}
@Generable struct Coach {
    var intent: String
    @Guide(description: "0-100", .range(0...100))
    var score: Int
    var native: String
    @Guide(.maximumCount(5))
    var fixes: [Fix]
    var why: String
    var pattern: String
    var spanish_transfer: String
}

let dir = NSString(string: "~/Library/Application Support/TypeFlow/coach").expandingTildeInPath
let instructions = try String(contentsOfFile: dir + "/coach.md", encoding: .utf8)
let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)!
guard case .available = SystemLanguageModel.default.availability else {
    fputs("unavailable: \(SystemLanguageModel.default.availability)\n", stderr); exit(2)
}
let session = LanguageModelSession(instructions: instructions)
let r = try await session.respond(to: text, generating: Coach.self, options: GenerationOptions(temperature: 0.1))
let c = r.content
let dict: [String: Any] = ["intent": c.intent, "score": c.score, "native": c.native,
    "fixes": c.fixes.map { ["original": $0.original, "correction": $0.correction, "reason": $0.reason, "category": $0.category] },
    "why": c.why, "pattern": c.pattern, "spanish_transfer": c.spanish_transfer]
print(String(data: try JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!)
