import AppKit
import XCTest
@testable import VoicePloeg

@MainActor
final class ClipboardPasteTransactionTests: XCTestCase {
    func testCancellationAfterPostingDoesNotRestoreClipboardBeforeEditorReadsIt() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Original", forType: .string)
        var posted = false
        let paste = Task {
            try await ClipboardPasteTransaction.paste(
                "Transcript", pasteboard: pasteboard, verifyTarget: {},
                postPaste: {
                    posted = true
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        }
        while !posted { await Task.yield() }

        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(pasteboard.string(forType: .string), "Transcript")
        try await paste.value
        XCTAssertEqual(pasteboard.string(forType: .string), "Original")
    }

    func testTranscriptRemainsAvailableUntilDelayedPasteFinishes() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Original clipboard", forType: .string)
        var posted = false
        var receivedText: String?

        try await ClipboardPasteTransaction.paste(
            "Transcript",
            pasteboard: pasteboard,
            verifyTarget: {},
            postPaste: { posted = true },
            waitForPaste: {
                XCTAssertTrue(posted)
                // Emulate an editor that handles the key event on a later run-loop turn.
                await Task.yield()
                receivedText = pasteboard.string(forType: .string)
            }
        )

        XCTAssertEqual(receivedText, "Transcript")
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard")
    }

    func testDoesNotOverwriteNewlyCopiedContent() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Original clipboard", forType: .string)

        try await ClipboardPasteTransaction.paste(
            "Transcript",
            pasteboard: pasteboard,
            verifyTarget: {},
            postPaste: {},
            waitForPaste: {
                pasteboard.clearContents()
                pasteboard.setString("New copy", forType: .string)
            }
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "New copy")
    }

    func testRestoresAllOriginalClipboardTypes() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let richText = Data("{\\rtf1 Original}".utf8)
        let item = NSPasteboardItem()
        item.setString("Original", forType: .string)
        item.setData(richText, forType: .rtf)
        pasteboard.writeObjects([item])

        try await ClipboardPasteTransaction.paste(
            "Transcript", pasteboard: pasteboard, verifyTarget: {}, postPaste: {}, waitForPaste: {}
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "Original")
        XCTAssertEqual(pasteboard.data(forType: .rtf), richText)
    }

    func testRestoresAnOriginallyEmptyClipboard() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        try await ClipboardPasteTransaction.paste(
            "Transcript", pasteboard: pasteboard, verifyTarget: {}, postPaste: {}, waitForPaste: {}
        )

        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
    }

    func testFocusChangeBeforePostingAbortsAndRestoresClipboard() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Original", forType: .string)
        var checks = 0

        do {
            try await ClipboardPasteTransaction.paste(
                "Transcript",
                pasteboard: pasteboard,
                verifyTarget: {
                    checks += 1
                    if checks == 2 { throw TextOutputError.targetActivationFailed }
                },
                postPaste: { XCTFail("Must not paste after focus changes") },
                waitForPaste: { XCTFail("Must not wait for an unposted paste") }
            )
            XCTFail("Expected targetActivationFailed")
        } catch {
            guard case TextOutputError.targetActivationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(pasteboard.string(forType: .string), "Original")
    }

    func testPostingFailureRestoresClipboard() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Original", forType: .string)

        do {
            try await ClipboardPasteTransaction.paste(
                "Transcript", pasteboard: pasteboard, verifyTarget: {},
                postPaste: { throw TextOutputError.insertionFailed },
                waitForPaste: { XCTFail("Must not wait after posting fails") }
            )
            XCTFail("Expected insertionFailed")
        } catch {
            guard case TextOutputError.insertionFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(pasteboard.string(forType: .string), "Original")
    }
}
