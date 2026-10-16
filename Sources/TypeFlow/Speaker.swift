import AppKit
import AVFoundation

/// The composer's ▶: reads text aloud with Apple's on-device voices, to hear how
/// the words sound. English uses the System voice (System Settings → Accessibility
/// → Read & Speak), so switching voices happens there; Spanish, or a System voice
/// in another language, gets the best installed voice (Premium › Enhanced › default).
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

    func speak(_ text: String, language: DraftLanguage) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice(for: language)
        // A little slower than conversational: the point is hearing each word.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        current = utterance
        isSpeaking = true
        synth.speak(utterance)
    }

    func stop() {
        guard isSpeaking else { return }
        current = nil
        synth.stopSpeaking(at: .immediate)
        finish()
    }

    private static func bestVoice(for language: DraftLanguage) -> AVSpeechSynthesisVoice? {
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
