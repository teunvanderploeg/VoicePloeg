import XCTest
@testable import VoicePloeg

@MainActor
final class LiveTextInsertionConfirmationTests: XCTestCase {
    func testDelayedEditorConfirmationWaitsWithoutReinserting() async throws {
        let original = LiveTextSnapshot(value: "", selection: NSRange(location: 0, length: 0))
        var target = LiveTextTargetGuard(expected: original)
        target.beginInsertion("Hello")
        var observations = 0
        try await LiveTextInsertionConfirmation.wait(timeout: .seconds(1)) {
            observations += 1
            let snapshot = observations < 4 ? original : original.inserting("Hello")
            return try target.observeInsertion(focusMatches: true, snapshot: snapshot)
        }
        XCTAssertEqual(observations, 4)
        XCTAssertEqual(target.expected.value, "Hello")
    }

    func testUnconfirmedDeliveryTimesOutRatherThanPretendingItSucceeded() async {
        do {
            try await LiveTextInsertionConfirmation.wait(timeout: .milliseconds(70)) { false }
            XCTFail("Expected an unconfirmed insertion")
        } catch {
            XCTAssertEqual(error.localizedDescription, UserFacingMessage.liveInsertionUnconfirmed)
        }
    }

    func testManualInteractionDuringConfirmationStopsImmediately() async {
        let original = LiveTextSnapshot(value: "", selection: NSRange(location: 0, length: 0))
        var target = LiveTextTargetGuard(expected: original)
        target.beginInsertion("Hello")
        var observations = 0
        do {
            try await LiveTextInsertionConfirmation.wait(timeout: .seconds(1)) {
                observations += 1
                target.invalidate()
                return try target.observeInsertion(focusMatches: true, snapshot: original.inserting("Hello"))
            }
            XCTFail("Expected target change")
        } catch {
            XCTAssertEqual(error.localizedDescription, UserFacingMessage.liveTargetChanged)
        }
        XCTAssertEqual(observations, 1)
    }
}
