import XCTest
@testable import VoicePloeg

final class LiveTextFormattingTests: XCTestCase {
    func testPhraseSpacingRespectsExistingWhitespaceAndPunctuation() {
        XCTAssertEqual(LiveTextFormatting.insertion("Hello", after: ""), "Hello")
        XCTAssertEqual(LiveTextFormatting.insertion("  again.\n", after: "Hello"), " again.")
        XCTAssertEqual(LiveTextFormatting.insertion("Next", after: "Hello. "), "Next")
        XCTAssertEqual(LiveTextFormatting.insertion("Next", after: "Hello.\n"), "Next")
        XCTAssertEqual(LiveTextFormatting.insertion("inside", after: "("), "inside")
        XCTAssertEqual(LiveTextFormatting.insertion(", please.", after: "Yes"), ", please.")
        XCTAssertEqual(LiveTextFormatting.insertion(" \n", after: "Hello"), "")
    }

    func testInsertionPreservesFollowingTextAndUsesUTF16CursorOffsets() {
        let snapshot = LiveTextSnapshot(value: "Hi 👋!", selection: NSRange(location: 5, length: 0))
        let updated = snapshot.inserting(" there")
        XCTAssertEqual(updated.value, "Hi 👋 there!")
        XCTAssertEqual(updated.selection, NSRange(location: 11, length: 0))
    }
}
