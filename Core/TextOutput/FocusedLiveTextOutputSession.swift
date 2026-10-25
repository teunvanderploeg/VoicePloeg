import AppKit
import ApplicationServices
import Foundation
import OSLog

struct LiveTextSnapshot: Equatable {
    let value: String
    let selection: NSRange

    func inserting(_ text: String) -> LiveTextSnapshot {
        let updated = (value as NSString).replacingCharacters(in: selection, with: text)
        return LiveTextSnapshot(
            value: updated,
            selection: NSRange(location: selection.location + (text as NSString).length, length: 0)
        )
    }

    /// Web composers expose placeholder newlines/zero-width spaces and may use
    /// NBSP or decomposed accents. Map the caret through the same normalization.
    var normalizedForRichText: LiveTextSnapshot {
        let normalizedValue = Self.normalizeRichText(value)
            .replacingOccurrences(of: "\n+$", with: "", options: .regularExpression)
        let source = value as NSString
        let prefix = Self.normalizeRichText(source.substring(to: selection.location))
        let selected = Self.normalizeRichText(source.substring(with: selection))
        let location = min((prefix as NSString).length, (normalizedValue as NSString).length)
        let length = min((selected as NSString).length, (normalizedValue as NSString).length - location)
        return LiveTextSnapshot(value: normalizedValue, selection: NSRange(location: location, length: length))
    }

    static func normalizeRichText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .precomposedStringWithCanonicalMapping
    }
}

struct LiveTextTargetGuard {
    private(set) var expected: LiveTextSnapshot
    private var pending: LiveTextSnapshot?
    private(set) var invalidated = false
    private let normalizesRichText: Bool
    var hasPendingInsertion: Bool { pending != nil }
    var pendingMetrics: (length: Int, selection: NSRange)? {
        guard let pending else { return nil }
        let snapshot = normalizesRichText ? pending.normalizedForRichText : pending
        return ((snapshot.value as NSString).length, snapshot.selection)
    }

    init(expected: LiveTextSnapshot, normalizesRichText: Bool = false) {
        self.expected = expected
        self.normalizesRichText = normalizesRichText
    }

    var insertionPrefix: String {
        let prefix = (expected.value as NSString).substring(to: expected.selection.location)
        return normalizesRichText ? LiveTextSnapshot.normalizeRichText(prefix) : prefix
    }

    mutating func invalidate() { invalidated = true }

    mutating func validate(focusMatches: Bool, snapshot: LiveTextSnapshot) throws {
        try validateFocus(focusMatches)
        // Text and selection can arrive in separate AX updates after our insert.
        // No new delivery is allowed until observation confirms the complete edit.
        if pending != nil { return }
        try validateForDelivery(focusMatches: focusMatches, snapshot: snapshot)
    }

    mutating func validateForDelivery(focusMatches: Bool, snapshot: LiveTextSnapshot) throws {
        try validateFocus(focusMatches)
        guard equivalent(snapshot, expected) else {
            invalidated = true
            throw LiveDictationError.targetChanged
        }
    }

    mutating func beginInsertion(_ text: String) {
        if normalizesRichText, expected.normalizedForRichText.value.isEmpty {
            // Empty contenteditables can place the caret after their placeholder
            // newline, then remove that placeholder as soon as text is pasted.
            pending = LiveTextSnapshot(value: text, selection: NSRange(location: (text as NSString).length, length: 0))
        } else {
            pending = expected.inserting(text)
        }
    }

    mutating func confirmInsertion(focusMatches: Bool, snapshot: LiveTextSnapshot) throws {
        guard try observeInsertion(focusMatches: focusMatches, snapshot: snapshot) else {
            invalidated = true
            throw LiveDictationError.insertionUnconfirmed
        }
    }

    mutating func observeInsertion(focusMatches: Bool, snapshot: LiveTextSnapshot) throws -> Bool {
        try validateFocus(focusMatches)
        guard let pending, equivalent(snapshot, pending) else { return false }
        // Keep the editor's actual representation for the next range replacement.
        expected = snapshot
        self.pending = nil
        return true
    }

    mutating func validateFocus(_ focusMatches: Bool) throws {
        guard !invalidated, focusMatches else {
            invalidated = true
            throw LiveDictationError.targetChanged
        }
    }

    private func equivalent(_ lhs: LiveTextSnapshot, _ rhs: LiveTextSnapshot) -> Bool {
        normalizesRichText ? lhs.normalizedForRichText == rhs.normalizedForRichText : lhs == rhs
    }
}

@MainActor
enum LiveTextInsertionConfirmation {
    static func wait(
        timeout: Duration = .seconds(2),
        observe: @MainActor () throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            try Task.checkCancellation()
            if try observe() { return }
            try await Task.sleep(for: .milliseconds(30))
        } while ContinuousClock.now < deadline
        throw LiveDictationError.insertionUnconfirmed
    }
}

private enum LiveTextObservationError: Error {
    case inconsistentSnapshot
}

/// Unlike final-paste mode, this session never activates an application or changes
/// a selection. A failed check permanently suspends insertion for this recording.
@MainActor
final class FocusedLiveTextOutputSession: LiveTextOutputSession {
    private static let pasteMarker: Int64 = 0x56504C495645
    private let logger = Logger(subsystem: "com.voiceploeg.app", category: "LiveTextOutput")
    private let controller: ActiveAppTextOutputController
    private let processID: pid_t
    private let element: AXUIElement
    private var target: LiveTextTargetGuard
    private var inputMonitor: Any?
    private var activationMonitor: NSObjectProtocol?
    private var observedLength = -1
    private var observedSelection = NSRange(location: 0, length: 0)

    init(
        controller: ActiveAppTextOutputController,
        processID: pid_t,
        hotkey: HotkeyCombination,
        normalizesRichText: Bool? = nil
    ) throws {
        guard AXIsProcessTrusted() else { throw TextOutputError.accessibilityUnavailable }
        self.controller = controller
        self.processID = processID
        element = try controller.verifiedFocusedElement(targetProcessID: processID, messagingTimeout: 0.2)
        AXUIElementSetMessagingTimeout(element, 0.2)
        let subrole = Self.stringAttribute(kAXSubroleAttribute, of: element)
        guard subrole != kAXSecureTextFieldSubrole else { throw LiveDictationError.unverifiableField }
        let role = Self.stringAttribute(kAXRoleAttribute, of: element)
        guard let role, [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else {
            throw LiveDictationError.unverifiableField
        }
        let snapshot = try Self.snapshot(element)
        guard snapshot.selection.length == 0 else { throw LiveDictationError.unverifiableField }
        let richText = normalizesRichText ?? TextOutputApplicationPolicy.prefersClipboardPaste(
            bundleIdentifier: NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
        )
        target = LiveTextTargetGuard(expected: snapshot, normalizesRichText: richText)
        inputMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.pasteMarker { return }
            if event.type == .keyDown {
                let combination = HotkeyCombination.from(event: event)
                if combination == hotkey || combination == .languageCycle { return }
            }
            // AppKit delivers event monitors on the main thread.
            MainActor.assumeIsolated { self?.target.invalidate() }
        }
        activationMonitor = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            MainActor.assumeIsolated {
                guard let self, activatedPID != self.processID else { return }
                self.target.invalidate()
            }
        }
    }

    func validate() throws {
        do {
            try validateApplication()
            let focused = try controller.verifiedFocusedElement(targetProcessID: processID, messagingTimeout: 0.2)
            try target.validateFocus(CFEqual(focused, element))
            if target.hasPendingInsertion { return }
            let snapshot = try Self.snapshot(element)
            try target.validate(focusMatches: CFEqual(focused, element), snapshot: snapshot)
        } catch TextOutputError.targetFocusUnavailable where target.hasPendingInsertion {
            // A web editor can briefly omit its focused AX element while applying
            // a paste. Application/manual-input checks still apply during the wait.
            try validateApplication()
        } catch {
            target.invalidate()
            throw LiveDictationError.targetChanged
        }
    }

    func insert(_ text: String) async throws {
        try validate()
        let payload = LiveTextFormatting.insertion(text, after: target.insertionPrefix)
        guard !payload.isEmpty else { return }
        target.beginInsertion(payload)
        let method = try await TextInsertionTransaction.insert(
            bundleIdentifier: NSRunningApplication(processIdentifier: processID)?.bundleIdentifier,
            insertUsingAccessibility: {
                try self.validateForDelivery()
                return try self.controller.insertUsingAccessibility(payload, targetProcessID: self.processID)
            },
            waitForShortcutRelease: {
                try await self.controller.waitForShortcutRelease()
                try self.validateForDelivery()
            },
            insertUsingClipboardPaste: {
                try await ClipboardPasteTransaction.paste(
                    payload,
                    pasteboard: .general,
                    verifyTarget: { try self.validateForDelivery() },
                    postPaste: { try ActiveAppTextOutputController.postPaste(eventSourceUserData: Self.pasteMarker) }
                )
            }
        )
        // Observe asynchronous editor updates without posting the phrase again.
        do {
            try await LiveTextInsertionConfirmation.wait { try self.observeInsertion() }
        } catch {
            if case LiveDictationError.insertionUnconfirmed = error {
                let expected = target.pendingMetrics
                let bundle = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier ?? "unknown"
                // Metadata only: never log the editor value or dictated text.
                logger.error("Live insertion unconfirmed: app=\(bundle, privacy: .public) method=\(method.rawValue, privacy: .public) expectedLength=\(expected?.length ?? -1) expectedCaret=\(expected?.selection.location ?? -1) observedLength=\(self.observedLength) observedCaret=\(self.observedSelection.location) observedSelectionLength=\(self.observedSelection.length)")
            }
            target.invalidate()
            throw error
        }
    }

    private func validateApplication() throws {
        try target.validateFocus(TextOutputTargetPolicy.isFrontmostTarget(
            targetProcessID: processID,
            frontmostProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ))
    }

    private func validateForDelivery() throws {
        try validateApplication()
        let focused = try controller.verifiedFocusedElement(targetProcessID: processID, messagingTimeout: 0.2)
        try target.validateForDelivery(focusMatches: CFEqual(focused, element), snapshot: Self.snapshot(element))
    }

    private func observeInsertion() throws -> Bool {
        try validateApplication()
        do {
            let focused = try controller.verifiedFocusedElement(targetProcessID: processID, messagingTimeout: 0.2)
            let snapshot = try Self.snapshot(element)
            observedLength = (snapshot.value as NSString).length
            observedSelection = snapshot.selection
            return try target.observeInsertion(focusMatches: CFEqual(focused, element), snapshot: snapshot)
        } catch LiveTextObservationError.inconsistentSnapshot {
            return false
        } catch TextOutputError.targetFocusUnavailable {
            return false
        } catch LiveDictationError.unverifiableField {
            return false
        }
    }

    func close() {
        target.invalidate()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        if let activationMonitor { NSWorkspace.shared.notificationCenter.removeObserver(activationMonitor) }
        inputMonitor = nil
        activationMonitor = nil
    }

    private static func snapshot(_ element: AXUIElement) throws -> LiveTextSnapshot {
        let (value, rawRange) = try snapshotAttributes(element)
        guard CFGetTypeID(rawRange) == AXValueGetTypeID() else {
            throw LiveDictationError.unverifiableField
        }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(rawRange, to: AXValue.self), .cfRange, &range) else {
            throw LiveDictationError.unverifiableField
        }
        guard
              range.location >= 0, range.length >= 0,
              range.location <= (value as NSString).length,
              range.length <= (value as NSString).length - range.location else {
            throw LiveTextObservationError.inconsistentSnapshot
        }
        return LiveTextSnapshot(value: value, selection: NSRange(location: range.location, length: range.length))
    }

    private static func snapshotAttributes(_ element: AXUIElement) throws -> (String, CFTypeRef) {
        // Read both in one AX message where supported to avoid observing a new
        // caret paired with the old text during an editor update.
        var attributes: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element, [kAXValueAttribute, kAXSelectedTextRangeAttribute] as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &attributes
        )
        if status == .success, let values = attributes as? [Any], values.count == 2,
           let value = values[0] as? String {
            let rawRange = values[1] as CFTypeRef
            if CFGetTypeID(rawRange) == AXValueGetTypeID(),
               AXValueGetType(unsafeDowncast(rawRange, to: AXValue.self)) == .cfRange {
                return (value, rawRange)
            }
        }
        var rawRange: CFTypeRef?
        guard let value = stringAttribute(kAXValueAttribute, of: element),
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rawRange) == .success,
              let rawRange else { throw LiveDictationError.unverifiableField }
        return (value, rawRange)
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
