import XCTest
@testable import VoicePloeg

final class TextOutputTargetPolicyTests: XCTestCase {
    func testAcceptsMatchingFrontmostTargetForVerifiedPaste() {
        XCTAssertTrue(
            TextOutputTargetPolicy.isFrontmostTarget(
                targetProcessID: 42,
                frontmostProcessID: 42
            )
        )
    }

    func testRejectsDifferentFrontmostTargetForVerifiedPaste() {
        XCTAssertFalse(
            TextOutputTargetPolicy.isFrontmostTarget(
                targetProcessID: 42,
                frontmostProcessID: 7
            )
        )
    }

    func testAcceptsMatchingTargetFrontmostAndFocusedProcesses() {
        XCTAssertTrue(
            TextOutputTargetPolicy.isVerified(
                targetProcessID: 42,
                frontmostProcessID: 42,
                focusedProcessID: 42
            )
        )
    }

    func testRejectsDifferentFrontmostProcess() {
        XCTAssertFalse(
            TextOutputTargetPolicy.isVerified(
                targetProcessID: 42,
                frontmostProcessID: 7,
                focusedProcessID: 42
            )
        )
    }

    func testRejectsFocusedElementFromDifferentProcess() {
        XCTAssertFalse(
            TextOutputTargetPolicy.isVerified(
                targetProcessID: 42,
                frontmostProcessID: 42,
                focusedProcessID: 7
            )
        )
    }

    func testRejectsMissingProcessInformation() {
        XCTAssertFalse(
            TextOutputTargetPolicy.isVerified(
                targetProcessID: 42,
                frontmostProcessID: nil,
                focusedProcessID: nil
            )
        )
    }

    func testRejectsInvalidTargetProcess() {
        XCTAssertFalse(
            TextOutputTargetPolicy.isVerified(
                targetProcessID: 0,
                frontmostProcessID: 0,
                focusedProcessID: 0
            )
        )
    }
}
