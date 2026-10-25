import XCTest
@testable import VoicePloeg

final class LiveTextTargetGuardTests: XCTestCase {
    private let original = LiveTextSnapshot(value: "Draft", selection: NSRange(location: 5, length: 0))

    func testRichTextPlaceholderNewlineAndNonbreakingSpacesAreConfirmed() throws {
        let emptyEditor = LiveTextSnapshot(value: "\n", selection: NSRange(location: 0, length: 0))
        var target = LiveTextTargetGuard(expected: emptyEditor, normalizesRichText: true)
        target.beginInsertion("Hello world.")
        let delivered = LiveTextSnapshot(value: "Hello\u{00A0}world.", selection: NSRange(location: 12, length: 0))
        try target.confirmInsertion(focusMatches: true, snapshot: delivered)
        XCTAssertEqual(target.expected, delivered)
        XCTAssertEqual(target.insertionPrefix, "Hello world.")
        target.beginInsertion(" Again.")
        let next = LiveTextSnapshot(value: "Hello world. Again.\n", selection: NSRange(location: 19, length: 0))
        try target.confirmInsertion(focusMatches: true, snapshot: next)
        XCTAssertEqual(target.expected, next)
    }

    func testEmptyRichTextCaretAfterPlaceholderDoesNotRequirePhantomLeadingNewline() throws {
        var target = LiveTextTargetGuard(expected: LiveTextSnapshot(value: "\n", selection: NSRange(location: 1, length: 0)),
            normalizesRichText: true)
        target.beginInsertion("Hello.")
        try target.confirmInsertion(focusMatches: true,
            snapshot: LiveTextSnapshot(value: "Hello.", selection: NSRange(location: 6, length: 0)))
    }

    func testRichTextNormalizationMapsUTF16CaretWithoutBreakingEmoji() throws {
        let value = "Cafe\u{0301} 👩‍💻\u{200B}"
        let snapshot = LiveTextSnapshot(value: value, selection: NSRange(location: (value as NSString).length, length: 0))
        let normalized = snapshot.normalizedForRichText
        XCTAssertEqual(normalized.value, "Café 👩‍💻")
        XCTAssertEqual(normalized.selection.location, ("Café 👩‍💻" as NSString).length)
        var target = LiveTextTargetGuard(expected: snapshot, normalizesRichText: true)
        XCTAssertEqual(target.insertionPrefix, "Café 👩‍💻")
        target.beginInsertion(" hello")
        let delivered = LiveTextSnapshot(value: "Café 👩‍💻 hello\n", selection: NSRange(location: ("Café 👩‍💻 hello" as NSString).length, length: 0))
        try target.confirmInsertion(focusMatches: true, snapshot: delivered)
    }

    func testPendingObservationWaitsForTextAndCaretButDeliveryStillChecksOriginal() throws {
        var target = LiveTextTargetGuard(expected: original)
        target.beginInsertion(" hello")
        let textBeforeCaret = LiveTextSnapshot(value: "Draft hello", selection: original.selection)
        try target.validate(focusMatches: true, snapshot: textBeforeCaret)
        XCTAssertFalse(try target.observeInsertion(focusMatches: true, snapshot: textBeforeCaret))
        XCTAssertTrue(try target.observeInsertion(focusMatches: true, snapshot: original.inserting(" hello")))

        var changedBeforeDelivery = LiveTextTargetGuard(expected: original)
        changedBeforeDelivery.beginInsertion(" hello")
        XCTAssertThrowsError(try changedBeforeDelivery.validateForDelivery(focusMatches: true, snapshot: textBeforeCaret))
    }

    func testRichTextNormalizationDoesNotAcceptDifferentWordsOrMovedCaret() {
        for changed in [LiveTextSnapshot(value: "Draft wrong", selection: NSRange(location: 11, length: 0)),
                        LiveTextSnapshot(value: "Draft hello\n", selection: NSRange(location: 0, length: 0))] {
            var target = LiveTextTargetGuard(expected: original, normalizesRichText: true)
            target.beginInsertion(" hello")
            XCTAssertThrowsError(try target.confirmInsertion(focusMatches: true, snapshot: changed))
        }
    }

    func testNativeEditorsKeepExactWhitespaceChecks() {
        var target = LiveTextTargetGuard(expected: original)
        target.beginInsertion(" hello")
        XCTAssertThrowsError(try target.confirmInsertion(focusMatches: true,
            snapshot: LiveTextSnapshot(value: "Draft hello\n", selection: NSRange(location: 11, length: 0))))
    }

    func testCursorTextOrFieldChangeSuspendsSessionEvenAfterReturning() {
        let changes = [
            (true, LiveTextSnapshot(value: "Draft", selection: NSRange(location: 0, length: 0))),
            (true, LiveTextSnapshot(value: "Edit!", selection: NSRange(location: 5, length: 0))),
            (false, original)
        ]
        for (focusMatches, snapshot) in changes {
            var target = LiveTextTargetGuard(expected: original)
            XCTAssertThrowsError(try target.validate(focusMatches: focusMatches, snapshot: snapshot))
            XCTAssertThrowsError(try target.validate(focusMatches: true, snapshot: original))
        }
    }

    func testPollingDuringPasteAcceptsPendingDeliveryAndThenCommitsOnce() throws {
        var target = LiveTextTargetGuard(expected: original)
        let delivered = original.inserting(" hello")
        target.beginInsertion(" hello")
        // The capture loop can validate both before and after the receiving app
        // consumes a posted paste event, while clipboard restoration is waiting.
        try target.validate(focusMatches: true, snapshot: original)
        try target.validate(focusMatches: true, snapshot: delivered)
        try target.confirmInsertion(focusMatches: true, snapshot: delivered)
        XCTAssertEqual(target.expected, delivered)
        try target.validate(focusMatches: true, snapshot: delivered)
        XCTAssertThrowsError(try target.validate(focusMatches: true, snapshot: original))
    }

    func testUnconfirmedDeliveryAndManualInteractionDuringPasteCannotBeRetried() {
        var unconfirmed = LiveTextTargetGuard(expected: original)
        unconfirmed.beginInsertion(" hello")
        XCTAssertThrowsError(try unconfirmed.confirmInsertion(focusMatches: true, snapshot: original))
        XCTAssertThrowsError(try unconfirmed.validate(focusMatches: true, snapshot: original))

        var interrupted = LiveTextTargetGuard(expected: original)
        interrupted.beginInsertion(" hello")
        interrupted.invalidate()
        XCTAssertThrowsError(try interrupted.confirmInsertion(focusMatches: true, snapshot: original.inserting(" hello")))
    }

    func testRepeatedWordsArePreservedWhenEachInsertionIsConfirmed() throws {
        var target = LiveTextTargetGuard(expected: original)
        for _ in 0 ..< 2 {
            let delivered = target.expected.inserting(" yes")
            target.beginInsertion(" yes")
            try target.confirmInsertion(focusMatches: true, snapshot: delivered)
        }
        XCTAssertEqual(target.expected.value, "Draft yes yes")
    }
}
