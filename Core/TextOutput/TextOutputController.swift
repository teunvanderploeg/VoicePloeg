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
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
        let changeCount: Int
    }

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

        guard CFGetTypeID(focusedObject) == AXUIElementGetTypeID() else {
            return false
        }
        let focusedElement = unsafeBitCast(focusedObject, to: AXUIElement.self)

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
        let snapshot = snapshotPasteboard(pasteboard)

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

        if !snapshot.items.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                // Only restore if no one changed clipboard after our paste operation.
                guard pasteboard.changeCount == snapshot.changeCount + 1 else { return }
                self.restorePasteboard(pasteboard, from: snapshot)
            }
        }
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { partialResult, type in
                if let data = item.data(forType: type) {
                    partialResult[type] = data
                }
            }
        } ?? []

        return PasteboardSnapshot(items: items, changeCount: pasteboard.changeCount)
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, from snapshot: PasteboardSnapshot) {
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
