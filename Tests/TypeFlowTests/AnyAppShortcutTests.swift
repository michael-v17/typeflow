import Carbon.HIToolbox
import XCTest
@testable import TypeFlow

/// The any-app hotkeys: ⌥⌘E correct, ⌥⌘K quick fix, ⌥⌘T translate, ⌥⌘R read aloud.
/// Nothing is registered here (that would take the keys from the running app);
/// the app registers exactly this table.
final class AnyAppShortcutTests: XCTestCase {
    private static let letters: [UInt32: String] = [
        UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_R): "R",
    ]

    func testTheFourShortcutsAreOptionCommandEKTR() {
        let keys = AnyAppShortcut.allCases.map { Self.letters[$0.keyCode] }
        XCTAssertEqual(keys, ["E", "K", "T", "R"])
        for shortcut in AnyAppShortcut.allCases {
            XCTAssertEqual(shortcut.modifiers, UInt32(cmdKey | optionKey), "\(shortcut)")
        }
    }

    func testEachMenuLineNamesItsRegisteredKey() {
        for shortcut in AnyAppShortcut.allCases {
            let letter = Self.letters[shortcut.keyCode] ?? "?"
            XCTAssertTrue(shortcut.menuLine.contains("⌥⌘" + letter), shortcut.menuLine)
        }
    }

    func testNoneTakesTheComposerHotkey() {
        let composer = (UInt32(kVK_Space), UInt32(optionKey))
        for shortcut in AnyAppShortcut.allCases {
            XCTAssertFalse(shortcut.keyCode == composer.0 && shortcut.modifiers == composer.1, "\(shortcut)")
        }
        XCTAssertEqual(Set(AnyAppShortcut.allCases.map(\.keyCode)).count, AnyAppShortcut.allCases.count)
    }
}
