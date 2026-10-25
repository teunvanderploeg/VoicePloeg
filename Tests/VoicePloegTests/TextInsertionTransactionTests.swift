import XCTest
@testable import VoicePloeg

@MainActor
final class TextInsertionTransactionTests: XCTestCase {
    func testOpenAIComposersPasteWithoutAttemptingAccessibilityWrites() async throws {
        for bundleIdentifier in ["com.openai.codex", "com.openai.chat"] {
            var steps: [String] = []
            let method = try await TextInsertionTransaction.insert(
                bundleIdentifier: bundleIdentifier,
                insertUsingAccessibility: {
                    XCTFail("Must use the composer's paste handler even if AX would report success")
                    return true
                },
                waitForShortcutRelease: { steps.append("release") },
                insertUsingClipboardPaste: { steps.append("paste") }
            )

            XCTAssertEqual(method, .clipboardPaste)
            XCTAssertEqual(steps, ["release", "paste"])
        }
    }

    func testOtherAppsKeepAccessibilityInsertion() async throws {
        for bundleIdentifier in ["com.apple.TextEdit", "com.google.Chrome", "com.openai.codex.other", nil] {
            let method = try await TextInsertionTransaction.insert(
                bundleIdentifier: bundleIdentifier,
                insertUsingAccessibility: { true },
                waitForShortcutRelease: { XCTFail("No shortcut is needed after AX insertion") },
                insertUsingClipboardPaste: { XCTFail("Must not insert the transcript twice") }
            )

            XCTAssertEqual(method, .accessibility)
        }
    }

    func testUnsupportedAccessibilityFallsBackToPaste() async throws {
        var steps: [String] = []
        let method = try await TextInsertionTransaction.insert(
            bundleIdentifier: "com.apple.TextEdit",
            insertUsingAccessibility: {
                steps.append("accessibility")
                return false
            },
            waitForShortcutRelease: { steps.append("release") },
            insertUsingClipboardPaste: { steps.append("paste") }
        )

        XCTAssertEqual(method, .clipboardPaste)
        XCTAssertEqual(steps, ["accessibility", "release", "paste"])
    }

    func testMissingAccessibilityFocusStillAllowsPaste() async throws {
        var pasted = false
        let method = try await TextInsertionTransaction.insert(
            bundleIdentifier: nil,
            insertUsingAccessibility: { throw TextOutputError.targetFocusUnavailable },
            waitForShortcutRelease: {},
            insertUsingClipboardPaste: { pasted = true }
        )

        XCTAssertEqual(method, .clipboardPaste)
        XCTAssertTrue(pasted)
    }

    func testHeldShortcutPreventsPasteInOpenAIComposers() async {
        do {
            _ = try await TextInsertionTransaction.insert(
                bundleIdentifier: "com.openai.codex",
                insertUsingAccessibility: { XCTFail("Must not write through AX"); return true },
                waitForShortcutRelease: { throw TextOutputError.shortcutKeysHeld },
                insertUsingClipboardPaste: { XCTFail("Must wait for the shortcut to be released") }
            )
            XCTFail("Expected shortcutKeysHeld")
        } catch {
            guard case TextOutputError.shortcutKeysHeld = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAccessibilityFailureDoesNotPasteIntoChangedTarget() async {
        do {
            _ = try await TextInsertionTransaction.insert(
                bundleIdentifier: "com.apple.TextEdit",
                insertUsingAccessibility: { throw TextOutputError.targetActivationFailed },
                waitForShortcutRelease: { XCTFail("Must stop after target verification fails") },
                insertUsingClipboardPaste: { XCTFail("Must not paste after target verification fails") }
            )
            XCTFail("Expected targetActivationFailed")
        } catch {
            guard case TextOutputError.targetActivationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
