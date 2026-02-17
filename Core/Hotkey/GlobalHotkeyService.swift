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

final class GlobalHotkeyService {
    private let signature = OSType(0x56504C47) // VPLG
    private let id: UInt32 = 1

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    var onTrigger: (() -> Void)?

    deinit {
        unregister()
    }

    func register(_ combination: HotkeyCombination) throws {
        unregister()

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else { return noErr }
                let `self` = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
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

                if status == noErr, hotKeyID.signature == self.signature, hotKeyID.id == self.id {
                    self.onTrigger?()
                }
                return noErr
            },
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandler
        )

        guard installStatus == noErr else {
            throw GlobalHotkeyError.registrationFailed(installStatus)
        }

        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let registerStatus = RegisterEventHotKey(
            UInt32(combination.keyCode),
            UInt32(combination.carbonModifiers),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            throw GlobalHotkeyError.registrationFailed(registerStatus)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}
