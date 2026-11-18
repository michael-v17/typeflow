import AppKit
import AVFoundation
import NaturalLanguage

/// The composer's ▶, the translation card's ▶ and ⌥⌘R's player: reads text aloud
/// with Apple's on-device voices, to hear how the words sound. English uses the
/// System voice (System Settings → Accessibility → Read & Speak), so switching
/// voices happens there; Spanish, or a System voice in another language, gets the
/// best installed voice (Premium › Enhanced › default).
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    /// Finished or stopped.
    var onFinish: (() -> Void)?
    private(set) var isSpeaking = false

    private let synth = AVSpeechSynthesizer()
    /// The utterance playing; callbacks for an earlier, stopped one are ignored.
    private var current: AVSpeechUtterance?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// A sentence or line at a time, a beat apart, so text — terminal output with
    /// bullets, headings and no periods included — doesn't run together.
    func speak(_ text: String, language: DraftLanguage) {
        stop()
        let voice = Self.bestVoice(for: language)
        let phrases = Self.phrases(text)
        for (phrase, pause) in phrases.isEmpty ? [(text, 0)] : phrases {
            let utterance = AVSpeechUtterance(string: phrase)
            utterance.voice = voice
            // Slower than conversational: the point is hearing each word.
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
            utterance.postUtteranceDelay = pause
            current = utterance // the last one: its end is the end
            synth.speak(utterance)
        }
        isSpeaking = true
    }

    /// Sentences, each with the pause after it: a short one, a longer one at the
    /// end of a paragraph, heading or bullet. Markdown marks are dropped; a line
    /// starting lowercase continues the one before (a hard-wrapped sentence).
    static func phrases(_ text: String) -> [(String, TimeInterval)] {
        var blocks: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let bullet = raw.range(of: #"^\s*([-*•+]|\d+[.)])\s"#, options: .regularExpression) != nil
            var line = raw.replacingOccurrences(of: #"[*`#|>_~━─═]+"#, with: " ", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*([-•+]|\d+[.)])\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard line.rangeOfCharacter(from: .alphanumerics) != nil else { continue }
            if !bullet, raw.trimmingCharacters(in: .whitespaces).first?.isLowercase == true, let last = blocks.last {
                blocks[blocks.count - 1] = last + " " + line
            } else {
                blocks.append(line)
            }
        }
        var phrases: [(String, TimeInterval)] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        for block in blocks {
            tokenizer.string = block
            let sentences = tokenizer.tokens(for: block.startIndex..<block.endIndex)
                .map { block[$0].trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for (i, sentence) in sentences.enumerated() {
                phrases.append((sentence, i == sentences.count - 1 ? 0.6 : 0.3))
            }
        }
        return phrases
    }

    private(set) var isPaused = false

    /// At the end of the word, so it picks up cleanly.
    func pause() {
        guard isSpeaking, !isPaused else { return }
        isPaused = synth.pauseSpeaking(at: .word)
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        synth.continueSpeaking()
    }

    func stop() {
        guard isSpeaking else { return }
        current = nil
        synth.stopSpeaking(at: .immediate)
        finish()
    }

    static func bestVoice(for language: DraftLanguage) -> AVSpeechSynthesisVoice? {
        let prefix = language == .spanish ? "es" : "en"
        // NSSpeechSynthesizer is deprecated, but it's still the only way to read
        // the System voice; if it ever stops resolving, the quality pick takes over.
        if let system = AVSpeechSynthesisVoice(identifier: NSSpeechSynthesizer.defaultVoice.rawValue),
           system.language.hasPrefix(prefix) {
            return system
        }
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        let preferred = language == .spanish ? "es-ES" : "en-US"
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            v.quality.rawValue * 2 + (v.language == preferred ? 1 : 0)
        }
        return candidates.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: preferred)
    }

    private func finish() {
        guard isSpeaking else { return }
        isSpeaking = false
        isPaused = false
        current = nil
        onFinish?()
    }

    // MARK: AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [self] in
            guard utterance === current else { return }
            finish()
        }
    }
}
