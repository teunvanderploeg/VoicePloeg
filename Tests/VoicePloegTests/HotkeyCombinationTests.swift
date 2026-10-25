import Carbon
import XCTest
@testable import VoicePloeg

final class HotkeyCombinationTests: XCTestCase {
    func testReservedAndModifierOnlyUnsafeShortcutsAreRejected() {
        XCTAssertFalse(HotkeyCombination.languageCycle.isValidRecordingShortcut)
        XCTAssertFalse(HotkeyCombination(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: 0).isValidRecordingShortcut)
        XCTAssertFalse(HotkeyCombination(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(shiftKey)).isValidRecordingShortcut)
        XCTAssertTrue(HotkeyCombination.default.isValidRecordingShortcut)
    }

    func testSpecialKeyLabelsRemainReadable() {
        XCTAssertEqual(HotkeyCombination.default.displayText, "⌃⌥Space")
        XCTAssertEqual(HotkeyCombination(keyCode: UInt32(kVK_LeftArrow), carbonModifiers: UInt32(cmdKey)).displayText, "⌘←")
    }
}
