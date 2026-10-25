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

    var isValidRecordingShortcut: Bool {
        keyCode <= 127 && carbonModifiers & UInt32(cmdKey | controlKey | optionKey) != 0 && self != .languageCycle
    }

    private static func keyLabel(for keyCode: UInt32) -> String {
        let special: [Int: String] = [kVK_Space: "Space", kVK_Return: "Return", kVK_Escape: "Esc",
            kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_ForwardDelete: "Forward Delete",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
        if let label = special[Int(keyCode)] { return label }
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "Key(\(keyCode))" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        let layout = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKey: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKey,
            characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return "Key(\(keyCode))" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

enum GlobalHotkeyError: Error, LocalizedError {
    case registrationFailed(OSStatus)
    case invalidCombination

    var errorDescription: String? {
        switch self {
        case .invalidCombination: return UserFacingMessage.hotkeyReserved
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
    var registrationWarning: String? { get }
    var onTrigger: (() -> Void)? { get set }
    var onLanguageCycleTrigger: (() -> Void)? { get set }
    func register(_ combination: HotkeyCombination) throws
}

extension GlobalHotkeyManaging {
    var registrationWarning: String? { nil }
}

final class GlobalHotkeyService: GlobalHotkeyManaging {
    private let signature = OSType(0x56504C47) // 'VPLG'

    // Slot IDs
    private let recordingID: UInt32 = 1
    private let languageID:  UInt32 = 2

    private var startupError: OSStatus?
    private var languageRegistrationError: OSStatus?
    var registrationWarning: String? {
        languageRegistrationError.map { UserFacingMessage.languageHotkeyRegistrationFailed($0) }
    }
    private var registeredCombination: HotkeyCombination?
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
        guard combination.isValidRecordingShortcut else { throw GlobalHotkeyError.invalidCombination }
        if let startupError { throw GlobalHotkeyError.registrationFailed(startupError) }
        guard combination != registeredCombination else { return }
        var replacement: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: recordingID)
        let status = RegisterEventHotKey(
            combination.keyCode,
            combination.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &replacement
        )
        guard status == noErr else { throw GlobalHotkeyError.registrationFailed(status) }
        unregisterRecordingHotkey()
        recordingHotKeyRef = replacement
        registeredCombination = combination
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

        let status = InstallEventHandler(
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
        if status != noErr { startupError = status }
    }

    private func registerLanguageHotkey() {
        let hotKeyID = EventHotKeyID(signature: signature, id: languageID)
        let status = RegisterEventHotKey(
            HotkeyCombination.languageCycle.keyCode,
            HotkeyCombination.languageCycle.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &languageHotKeyRef
        )
        if status != noErr { languageRegistrationError = status }
    }

    private func unregisterRecordingHotkey() {
        registeredCombination = nil
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
