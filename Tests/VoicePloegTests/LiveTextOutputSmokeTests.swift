import AppKit
import ApplicationServices
import XCTest
@testable import VoicePloeg

@MainActor
final class LiveTextOutputSmokeTests: XCTestCase {
    func testRealAccessibilityAndClipboardInsertionAndCursorProtection() async throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEPLOEG_LIVE_TEXT_FIXTURE"] else {
            throw XCTSkip("Set VOICEPLOEG_LIVE_TEXT_FIXTURE to the compiled disposable editor")
        }
        guard AXIsProcessTrusted() else { throw XCTSkip("Native smoke test needs existing Accessibility permission") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        defer { previousApp?.activate(options: []) }
        for mode in ["native", "--paste-only", "--rich-text", "--delayed-ax"] {
            let pasteOnly = mode == "--paste-only" || mode == "--rich-text"
            let richText = mode == "--rich-text"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = mode == "native" ? [] : [mode]
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            let controller = ActiveAppTextOutputController()
            var focused: AXUIElement?
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while focused == nil, ContinuousClock.now < deadline {
                focused = try? controller.verifiedFocusedElement(targetProcessID: process.processIdentifier)
                if focused == nil { try await Task.sleep(for: .milliseconds(50)) }
            }
            let element = try XCTUnwrap(focused)
            if pasteOnly {
                var settable = DarwinBoolean(true)
                XCTAssertEqual(AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable), .success)
                XCTAssertFalse(settable.boolValue, "Fixture must force the clipboard fallback")
            }
            let session = try FocusedLiveTextOutputSession(controller: controller,
                processID: process.processIdentifier, hotkey: .default, normalizesRichText: richText)
            defer { session.close() }
            var firstInsertionCompleted = false
            let firstInsertion = Task {
                try await session.insert("Hello.")
                firstInsertionCompleted = true
            }
            try await Task.sleep(for: .milliseconds(100))
            if mode == "--delayed-ax" { XCTAssertFalse(firstInsertionCompleted, "Fixture must delay AX delivery") }
            try session.validate() // Also check while a clipboard paste is pending.
            try await firstInsertion.value
            if pasteOnly {
                XCTAssertTrue(TextOutputTargetPolicy.areShortcutKeysReleased(CGEventSource.flagsState(.combinedSessionState)),
                    "Synthetic Command must not remain held between live phrases")
            }
            try await session.insert("Next phrase.")
            try session.validate()
            var value: CFTypeRef?
            XCTAssertEqual(AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value), .success)
            let expectedValue = richText ? "Hello. Next phrase." : "Draft Hello. Next phrase. tail"
            let observed = value as? String ?? ""
            XCTAssertEqual(richText ? LiveTextSnapshot.normalizeRichText(observed) : observed, expectedValue)
            var range = CFRange(location: 0, length: 0)
            let changedRange = try XCTUnwrap(AXValueCreate(.cfRange, &range))
            XCTAssertEqual(AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, changedRange), .success)
            do {
                try await session.insert("Must not appear")
                XCTFail("Cursor movement must suspend insertion")
            } catch {
                XCTAssertEqual(error.localizedDescription, UserFacingMessage.liveTargetChanged)
            }
            value = nil
            XCTAssertEqual(AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value), .success)
            let afterChange = value as? String ?? ""
            XCTAssertEqual(richText ? LiveTextSnapshot.normalizeRichText(afterChange) : afterChange, expectedValue)
        }
    }
}
