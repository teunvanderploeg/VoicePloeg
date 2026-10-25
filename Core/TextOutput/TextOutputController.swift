import AppKit
import ApplicationServices
import Foundation

enum TextInsertionMethod: String {
    case accessibility
    case simulatedTyping
    case clipboardPaste
}

@MainActor
protocol TextOutputController {
    func insert(_ text: String, targetProcessID: pid_t) async throws -> TextInsertionMethod
}

enum TextOutputError: Error, LocalizedError {
    case emptyText
    case accessibilityUnavailable
    case insertionFailed
    case targetApplicationUnavailable
    case targetActivationFailed
    case targetFocusUnavailable
    case shortcutKeysHeld

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "No text to insert"
        case .accessibilityUnavailable:
            return "Accessibility permission is missing"
        case .insertionFailed:
            return "Unable to insert text into focused app"
        case .targetApplicationUnavailable:
            return "The original target app is no longer available. The transcript was saved in History."
        case .targetActivationFailed:
            return "The original target app could not be brought to the front. The transcript was saved in History."
        case .targetFocusUnavailable:
            return "The original target app no longer has a verified text focus. The transcript was saved in History."
        case .shortcutKeysHeld:
            return UserFacingMessage.releaseShortcutKeys
        }
    }
}

enum TextOutputTargetPolicy {
    static func areShortcutKeysReleased(_ flags: CGEventFlags) -> Bool {
        flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }

    static func isFrontmostTarget(
        targetProcessID: pid_t,
        frontmostProcessID: pid_t?
    ) -> Bool {
        targetProcessID > 0 && frontmostProcessID == targetProcessID
    }

    static func isVerified(
        targetProcessID: pid_t,
        frontmostProcessID: pid_t?,
        focusedProcessID: pid_t?
    ) -> Bool {
        isFrontmostTarget(
            targetProcessID: targetProcessID,
            frontmostProcessID: frontmostProcessID
        )
            && focusedProcessID == targetProcessID
    }
}

final class ActiveAppTextOutputController: TextOutputController {
    func insert(_ text: String, targetProcessID: pid_t) async throws -> TextInsertionMethod {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TextOutputError.emptyText
        }

        guard AXIsProcessTrusted() else {
            throw TextOutputError.accessibilityUnavailable
        }

        try await activateAndVerifyTarget(processID: targetProcessID)

        do {
            if try insertUsingAccessibility(trimmed, targetProcessID: targetProcessID) {
                return .accessibility
            }
        } catch TextOutputError.targetFocusUnavailable {
            // Some complex editors, including Word, do not expose a settable
            // focused text element even though they accept a regular paste.
        }

        try await waitForShortcutRelease()
        try await insertUsingClipboardPaste(trimmed, targetProcessID: targetProcessID)
        return .clipboardPaste
    }

    private func activateAndVerifyTarget(processID: pid_t) async throws {
        guard processID > 0, let app = NSRunningApplication(processIdentifier: processID), !app.isTerminated else {
            throw TextOutputError.targetApplicationUnavailable
        }

        let needsActivation = frontmostProcessID() != processID
        if needsActivation {
            _ = app.activate(options: [])
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while frontmostProcessID() != processID, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        guard frontmostProcessID() == processID else {
            throw TextOutputError.targetActivationFailed
        }

        if needsActivation {
            // Frontmost status can change before the editor restores its first responder.
            try await Task.sleep(for: .milliseconds(200))
            guard frontmostProcessID() == processID else {
                throw TextOutputError.targetActivationFailed
            }
        }
    }

    private func waitForShortcutRelease() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !TextOutputTargetPolicy.areShortcutKeysReleased(
            CGEventSource.flagsState(.combinedSessionState)
        ) {
            guard ContinuousClock.now < deadline else {
                throw TextOutputError.shortcutKeysHeld
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func insertUsingAccessibility(_ text: String, targetProcessID: pid_t) throws -> Bool {
        let focusedElement = try verifiedFocusedElement(targetProcessID: targetProcessID)
        var isSettable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        )
        guard settableStatus == .success, isSettable.boolValue else {
            return false
        }

        let selectedStatus = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return selectedStatus == .success
    }

    private func verifiedFocusedElement(targetProcessID: pid_t) throws -> AXUIElement {
        let targetApplication = AXUIElementCreateApplication(targetProcessID)
        var focusedObject: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            targetApplication,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )

        guard focusedStatus == .success, let focusedObject else {
            throw TextOutputError.targetFocusUnavailable
        }

        guard CFGetTypeID(focusedObject) == AXUIElementGetTypeID() else {
            throw TextOutputError.targetFocusUnavailable
        }
        let focusedElement = unsafeDowncast(focusedObject, to: AXUIElement.self)

        var focusedProcessID = pid_t(0)
        let processStatus = AXUIElementGetPid(focusedElement, &focusedProcessID)
        guard
            processStatus == .success,
            TextOutputTargetPolicy.isVerified(
                targetProcessID: targetProcessID,
                frontmostProcessID: frontmostProcessID(),
                focusedProcessID: focusedProcessID
            )
        else {
            throw TextOutputError.targetFocusUnavailable
        }

        return focusedElement
    }

    private func frontmostProcessID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func insertUsingClipboardPaste(_ text: String, targetProcessID: pid_t) async throws {
        try await ClipboardPasteTransaction.paste(
            text,
            pasteboard: .general,
            verifyTarget: {
                guard TextOutputTargetPolicy.isFrontmostTarget(
                    targetProcessID: targetProcessID,
                    frontmostProcessID: self.frontmostProcessID()
                ) else {
                    throw TextOutputError.targetActivationFailed
                }
            },
            postPaste: { try Self.postPaste(to: targetProcessID) }
        )
    }

    private static func postPaste(to targetProcessID: pid_t) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw TextOutputError.insertionFailed
        }

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else {
            throw TextOutputError.insertionFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(targetProcessID)
        keyUp.postToPid(targetProcessID)
    }
}

@MainActor
enum ClipboardPasteTransaction {
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    static func paste(
        _ text: String,
        pasteboard: NSPasteboard,
        verifyTarget: () throws -> Void,
        postPaste: () throws -> Void,
        waitForPaste: () async -> Void = {
            // Posting an event does not mean the receiving editor has read the clipboard.
            // Keep it available longer for busy editors, without blocking the main thread.
            // Once posted, cancellation must not shorten the clipboard's lifetime.
            await Task {
                try? await Task.sleep(for: .seconds(1))
            }.value
        }
    ) async throws {
        try Task.checkCancellation()
        try verifyTarget()
        let snapshot = snapshotPasteboard(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restorePasteboard(pasteboard, from: snapshot)
            throw TextOutputError.insertionFailed
        }
        let transcriptChangeCount = pasteboard.changeCount
        defer {
            // Never overwrite something copied by the user while the paste was pending.
            if pasteboard.changeCount == transcriptChangeCount {
                restorePasteboard(pasteboard, from: snapshot)
            }
        }
        try verifyTarget()
        try postPaste()
        await waitForPaste()
    }

    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { partialResult, type in
                if let data = item.data(forType: type) {
                    partialResult[type] = data
                }
            }
        } ?? []

        return PasteboardSnapshot(items: items)
    }

    private static func restorePasteboard(_ pasteboard: NSPasteboard, from snapshot: PasteboardSnapshot) {
        let items = snapshot.items.compactMap { rawItem -> NSPasteboardItem? in
            guard !rawItem.isEmpty else { return nil }
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in rawItem {
                pasteboardItem.setData(data, forType: type)
            }
            return pasteboardItem
        }

        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }
}
