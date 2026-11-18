import AVFoundation
import XCTest
@testable import TypeFlow

/// ⌥⌘R and every ▶: how text is split into spoken phrases, and that the voice
/// the app picks really produces speech. The audio is rendered into buffers,
/// never played.
final class SpeakerTests: XCTestCase {
    private func phrases(_ text: String) -> [String] { Speaker.phrases(text).map(\.0) }

    func testSentencesBecomePhrasesWithALongerPauseAtTheEnd() {
        let p = Speaker.phrases("First sentence. Second one.")
        XCTAssertEqual(p.map(\.0), ["First sentence.", "Second one."])
        XCTAssertEqual(p.map(\.1), [0.3, 0.6])
    }

    func testMarkdownMarksAreNotRead() {
        XCTAssertEqual(phrases("## Results\n- **Tests** pass.\n- Build is `green` now."),
                       ["Results", "Tests pass.", "Build is green now."])
    }

    func testAHardWrappedSentenceIsReadAsOne() {
        XCTAssertEqual(phrases("This sentence was hard\nwrapped across two lines."),
                       ["This sentence was hard wrapped across two lines."])
    }

    func testRulesAndTableBordersAreSkipped() {
        XCTAssertEqual(phrases("━━━━━━\n|---|---|\n"), [])
    }

    /// Renders `text` with `voice` into buffers and returns the frame count.
    private func renderedFrames(_ text: String, _ voice: AVSpeechSynthesisVoice) -> Int {
        let synth = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        var frames = 0
        let done = expectation(description: "rendered")
        synth.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { done.fulfill() } else { frames += Int(pcm.frameLength) }
        }
        wait(for: [done], timeout: 20)
        return frames
    }

    func testTheEnglishVoiceSpeaks() throws {
        let voice = try XCTUnwrap(Speaker.bestVoice(for: .english))
        XCTAssertTrue(voice.language.hasPrefix("en"), voice.language)
        XCTAssertGreaterThan(renderedFrames("The build is green.", voice), 0)
    }

    func testTheSpanishVoiceSpeaks() throws {
        guard let voice = Speaker.bestVoice(for: .spanish), voice.language.hasPrefix("es") else {
            throw XCTSkip("no Spanish voice installed on this Mac")
        }
        XCTAssertGreaterThan(renderedFrames("La compilación está en verde.", voice), 0)
    }
}
