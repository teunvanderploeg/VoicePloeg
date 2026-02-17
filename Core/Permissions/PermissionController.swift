import AVFoundation
import ApplicationServices
import AppKit
import Foundation

struct PermissionStatus {
    let microphoneGranted: Bool
    let accessibilityGranted: Bool
}

struct AccessibilityDiagnostics {
    let trustedLegacy: Bool
    let trustedWithOptionsNoPrompt: Bool
    let bundleID: String
    let bundlePath: String
    let executablePath: String
    let processIdentifier: Int32
}

@MainActor
protocol PermissionController {
    func requestMicrophoneIfNeeded() async -> Bool
    func requestAccessibilityIfNeeded(prompt: Bool) -> Bool
    func currentStatus() -> PermissionStatus
    func accessibilityDiagnostics() -> AccessibilityDiagnostics
    func openAccessibilitySettings()
}

final class SystemPermissionController: PermissionController {
    func requestMicrophoneIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func requestAccessibilityIfNeeded(prompt: Bool) -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func currentStatus() -> PermissionStatus {
        let microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibilityGranted = trustedAccessibility()
        return PermissionStatus(
            microphoneGranted: microphoneGranted,
            accessibilityGranted: accessibilityGranted
        )
    }

    func accessibilityDiagnostics() -> AccessibilityDiagnostics {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let noPromptOptions = [promptKey: false] as CFDictionary

        return AccessibilityDiagnostics(
            trustedLegacy: AXIsProcessTrusted(),
            trustedWithOptionsNoPrompt: AXIsProcessTrustedWithOptions(noPromptOptions),
            bundleID: Bundle.main.bundleIdentifier ?? "unknown",
            bundlePath: Bundle.main.bundlePath,
            executablePath: Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments.first ?? "unknown",
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func trustedAccessibility() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let noPromptOptions = [promptKey: false] as CFDictionary
        return AXIsProcessTrusted() || AXIsProcessTrustedWithOptions(noPromptOptions)
    }
}
