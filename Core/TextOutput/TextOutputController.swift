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
    func insert(_ text: String) async throws -> TextInsertionMethod
}

enum TextOutputError: Error, LocalizedError {
    case emptyText
    case accessibilityUnavailable
    case insertionFailed

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "No text to insert"
        case .accessibilityUnavailable:
            return "Accessibility permission is missing"
        case .insertionFailed:
            return "Unable to insert text into focused app"
        }
    }
}

final class ActiveAppTextOutputController: TextOutputController {
    func insert(_ text: String) async throws -> TextInsertionMethod {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TextOutputError.emptyText
        }

        guard AXIsProcessTrusted() else {
            throw TextOutputError.accessibilityUnavailable
        }

        if insertUsingAccessibility(trimmed) {
            return .accessibility
        }

        try insertUsingClipboardPaste(trimmed)
        return .clipboardPaste
    }

    private func insertUsingAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )

        guard focusedStatus == .success, let focusedObject else {
            return false
        }

        let focusedElement = focusedObject as! AXUIElement

        let selectedStatus = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if selectedStatus == .success {
            return true
        }

        return false
    }

    private func insertUsingClipboardPaste(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw TextOutputError.insertionFailed
        }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)

        if let previousString {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                pasteboard.clearContents()
                pasteboard.setString(previousString, forType: .string)
            }
        }
    }
}
