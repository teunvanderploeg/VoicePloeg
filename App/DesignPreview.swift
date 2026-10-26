import CoreAudio
import Foundation
import AppKit
import PloegKit
import SwiftUI

/// Explicit, read-only visual QA mode. It never constructs the real capture,
/// hotkey, text-output or transcription services.
enum VoiceDesignPreviewMode: String, Equatable {
    case settings, menu

    static func resolve(arguments: [String], info: [String: Any]) -> Self? {
        if arguments.contains("--design-preview-menu") { return .menu }
        if arguments.contains("--design-preview") { return .settings }
        guard info["PloegDesignPreview"] as? Bool == true else { return nil }
        return (info["PloegDesignPreviewMode"] as? String)
            .flatMap { Self(rawValue: $0.lowercased()) } ?? .settings
    }
}

@MainActor
enum VoiceDesignPreview {
    private static var window: NSWindow?

    static func bringToFront() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func show(_ coordinator: AppCoordinator, mode: VoiceDesignPreviewMode) {
        let content: AnyView
        if mode == .menu {
            content = AnyView(MenuBarRoot(coordinator: coordinator).disabled(true))
        } else {
            content = AnyView(SettingsView(coordinator: coordinator).frame(minWidth: 860, minHeight: 620))
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = UserFacingMessage.previewTitle
        window.setContentSize(NSSize(width: mode == .menu ? 320 : 1000,
                                     height: mode == .menu ? 520 : 720))
        window.backgroundColor = PloegTheme.canvasNS
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    static func coordinator() -> AppCoordinator {
        let defaults = PreviewMemoryDefaults()
        defaults.set("en", forKey: "settings.selectedLanguage")
        defaults.set("preview-whisper", forKey: "settings.defaultDictationModelID")
        defaults.set("preview-whisper", forKey: "settings.automaticDictationModelID")
        defaults.set("preview-whisper", forKey: "settings.selectedWhisperModelID")
        defaults.set(true, forKey: "settings.liveDictationEnabled")
        let settings = AppSettings(userDefaults: defaults)
        let model = SpeechModelDescriptor(
            id: "preview-whisper", displayName: UserFacingMessage.previewModelName,
            sizeBytes: 142_000_000, languageSupport: ["en", "nl", "auto"], precision: "Q5",
            acquisition: .singleFile(url: URL(string: "https://example.invalid/preview-model")!, sha256: nil)
        )
        let previewRoot = URL(fileURLWithPath: "/__VoicePloegDesignPreview__", isDirectory: true)
        let coordinator = AppCoordinator(
            settings: settings,
            modelManager: ModelManager(fileManager: PreviewFileManager(), modelsDirectoryURL: previewRoot, catalog: [model]),
            permissionController: PreviewPermissions(),
            recordingController: PreviewRecorder(),
            textOutputController: PreviewTextOutput(),
            hotkeyService: PreviewHotkeys(),
            audioInputDeviceManager: PreviewDevices(),
            recordingFeedbackPlayer: PreviewFeedback(),
            crisperRuntimeManager: CrisperRuntimeManager(rootURL: previewRoot),
            barkRuntimeManager: BarkRuntimeManager(rootURL: previewRoot),
            transcriber: PreviewTranscriber(),
            isDesignPreview: true
        )
        coordinator.availableInputDevices = PreviewDevices().availableInputDevices()
        coordinator.lastTranscript = UserFacingMessage.previewTranscript
        return coordinator
    }
}

/// Overrides every persistence entry point used by AppSettings. Values remain in
/// this object; the standard preferences domain is never read or modified.
final class PreviewMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: "VoicePloeg.DesignPreview.MemoryOnly")! }
    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    override func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    override func removeObject(forKey key: String) { _ = lock.withLock { values.removeValue(forKey: key) } }
}

private final class PreviewFileManager: FileManager, @unchecked Sendable {
    override func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]? = nil) throws {}
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        [.size: NSNumber(value: 142_000_000)]
    }
}

@MainActor
private final class PreviewPermissions: PermissionController {
    func requestMicrophoneIfNeeded() async -> Bool { false }
    func requestAccessibilityIfNeeded(prompt: Bool) -> Bool { false }
    func currentStatus() -> PermissionStatus { .init(microphoneGranted: true, accessibilityGranted: true) }
    func accessibilityDiagnostics() -> AccessibilityDiagnostics {
        .init(trustedLegacy: true, trustedWithOptionsNoPrompt: true,
              bundleID: "design-preview", bundlePath: "", executablePath: "", processIdentifier: 0)
    }
    func openAccessibilitySettings() {}
    func openMicrophoneSettings() {}
}

private struct PreviewRecorder: RecordingController {
    func start() async throws {}
    func stop() async throws -> [Float] { [] }
}

private actor PreviewTranscriber: ManagedSpeechTranscribing {
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptResult {
        throw CancellationError()
    }
    func preloadModel(at modelURL: URL, backend: SpeechBackend) async throws {}
    func unloadBarkModel() async {}
    func unloadCrisperModel() async {}
    func releasePreloadedModels() async {}
}

@MainActor
private final class PreviewTextOutput: TextOutputController {
    func insert(_ text: String, targetProcessID: pid_t) async throws -> TextInsertionMethod {
        throw CancellationError()
    }
}

private final class PreviewHotkeys: GlobalHotkeyManaging {
    var onTrigger: (() -> Void)?
    var onLanguageCycleTrigger: (() -> Void)?
    func register(_ combination: HotkeyCombination) throws {}
}

private struct PreviewDevices: AudioInputDeviceManaging {
    func availableInputDevices() -> [AudioInputDevice] {
        [.init(id: 1, name: UserFacingMessage.previewMicrophoneName,
               transportType: kAudioDeviceTransportTypeBuiltIn)]
    }
    func defaultInputDeviceID() -> AudioDeviceID? { 1 }
    func setDefaultInputDeviceID(_ id: AudioDeviceID) throws {}
    func setInputDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void) {}
}

@MainActor
private struct PreviewFeedback: RecordingFeedbackPlayer {
    func playStartCue() {}
    func playStopCue() {}
}
