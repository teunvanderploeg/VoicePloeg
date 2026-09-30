import Carbon
import Cocoa
import Foundation

struct HotkeyCombination: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let `default` = HotkeyCombination(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(controlKey | optionKey)
    )

    static let languageCycle = HotkeyCombination(
        keyCode: UInt32(kVK_ANSI_L),
        carbonModifiers: UInt32(controlKey | optionKey)
    )

    var displayText: String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.keyLabel(for: keyCode))
        return parts.joined()
    }

    static func from(event: NSEvent) -> HotkeyCombination {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return HotkeyCombination(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)
    }

    private static func keyLabel(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space:
            return "Space"
        case kVK_Return:
            return "Return"
        case kVK_Escape:
            return "Esc"
        case kVK_ANSI_L:
            return "L"
        default:
            if let scalar = UnicodeScalar(Int(keyCode) + 0x41), scalar.properties.isAlphabetic {
                return String(scalar)
            }
            return "Key(\(keyCode))"
        }
    }
}

enum GlobalHotkeyError: Error, LocalizedError {
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .registrationFailed(status):
            return "Hotkey registration failed with status \(status)"
        }
    }
}

/// Manages all global Carbon hotkeys for the app through a single shared event handler.
///
/// Carbon's `InstallEventHandler` installs a handler on an event target. When you
/// install multiple handlers for the same event class/kind on the same target, each
/// handler is called in a chain. This works, but it becomes fragile when handlers are
/// removed and re-added independently. The safe pattern is one handler that dispatches
/// by `EventHotKeyID.id`.
protocol GlobalHotkeyManaging: AnyObject {
    var onTrigger: (() -> Void)? { get set }
    var onLanguageCycleTrigger: (() -> Void)? { get set }
    func register(_ combination: HotkeyCombination) throws
}

final class GlobalHotkeyService: GlobalHotkeyManaging {
    private let signature = OSType(0x56504C47) // 'VPLG'

    // Slot IDs
    private let recordingID: UInt32 = 1
    private let languageID:  UInt32 = 2

    private var eventHandler: EventHandlerRef?
    private var recordingHotKeyRef: EventHotKeyRef?
    private var languageHotKeyRef:  EventHotKeyRef?

    /// Fired when the recording hotkey is pressed.
    var onTrigger: (() -> Void)?
    /// Fired when the language-cycle hotkey (⌃⌥L) is pressed.
    var onLanguageCycleTrigger: (() -> Void)?

    init() {
        installSharedHandler()
        // Language cycle hotkey is fixed — register it once at startup.
        registerLanguageHotkey()
    }

    deinit {
        unregisterRecordingHotkey()
        unregisterLanguageHotkey()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    // MARK: - Public API

    func register(_ combination: HotkeyCombination) throws {
        unregisterRecordingHotkey()

        let hotKeyID = EventHotKeyID(signature: signature, id: recordingID)
        let status = RegisterEventHotKey(
            combination.keyCode,
            combination.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &recordingHotKeyRef
        )
        guard status == noErr else {
            throw GlobalHotkeyError.registrationFailed(status)
        }
    }

    func unregister() {
        unregisterRecordingHotkey()
    }

    // MARK: - Private helpers

    private func installSharedHandler() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData, let eventRef else { return noErr }
                let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == service.signature else { return noErr }

                switch hotKeyID.id {
                case service.recordingID: service.onTrigger?()
                case service.languageID:  service.onLanguageCycleTrigger?()
                default: break
                }
                return noErr
            },
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandler
        )
    }

    private func registerLanguageHotkey() {
        let hotKeyID = EventHotKeyID(signature: signature, id: languageID)
        RegisterEventHotKey(
            HotkeyCombination.languageCycle.keyCode,
            HotkeyCombination.languageCycle.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &languageHotKeyRef
        )
    }

    private func unregisterRecordingHotkey() {
        if let ref = recordingHotKeyRef {
            UnregisterEventHotKey(ref)
            recordingHotKeyRef = nil
        }
    }

    private func unregisterLanguageHotkey() {
        if let ref = languageHotKeyRef {
            UnregisterEventHotKey(ref)
            languageHotKeyRef = nil
        }
    }
}
