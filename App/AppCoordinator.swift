import Combine
import Foundation
import AppKit

enum InputRoutingError: Error, LocalizedError {
    case preferredInputUnavailable

    var errorDescription: String? {
        switch self {
        case .preferredInputUnavailable:
            return UserFacingMessage.preferredInputUnavailable
        }
    }
}

@MainActor
final class AppCoordinator: ObservableObject {
    @Published var state: AppState = .idle
    @Published var permissionStatus: PermissionStatus
    @Published var accessibilityDiagnostics: AccessibilityDiagnostics
    @Published var lastTranscript: String = ""
    @Published var isDownloadingModel = false
    @Published var availableInputDevices: [AudioInputDevice] = []

    var settings: AppSettings
    var modelManager: ModelManager

    private let permissionController: PermissionController
    private let recordingController: RecordingController
    private let transcriber: SpeechTranscriber
    private let textOutputController: TextOutputController
    private let hotkeyService: GlobalHotkeyService
    private let audioInputDeviceManager: AudioInputDeviceManaging
    private let recordingFeedbackPlayer: RecordingFeedbackPlayer

    private var cancellables = Set<AnyCancellable>()
    private var previousDefaultInputDeviceID: UInt32?
    private var outputTargetProcessID: pid_t?

    init(
        settings: AppSettings,
        modelManager: ModelManager,
        permissionController: PermissionController,
        recordingController: RecordingController,
        textOutputController: TextOutputController,
        hotkeyService: GlobalHotkeyService,
        audioInputDeviceManager: AudioInputDeviceManaging,
        recordingFeedbackPlayer: RecordingFeedbackPlayer
    ) {
        self.settings = settings
        self.modelManager = modelManager
        self.permissionController = permissionController
        self.recordingController = recordingController
        self.textOutputController = textOutputController
        self.hotkeyService = hotkeyService
        self.audioInputDeviceManager = audioInputDeviceManager
        self.recordingFeedbackPlayer = recordingFeedbackPlayer

        transcriber = WhisperCppTranscriber(cliPathProvider: { settings.whisperCLIPath })
        permissionStatus = permissionController.currentStatus()
        accessibilityDiagnostics = permissionController.accessibilityDiagnostics()

        hotkeyService.onTrigger = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.toggleRecording()
            }
        }

        settings.$hotkey
            .removeDuplicates()
            .sink { [weak self] hotkey in
                self?.register(hotkey)
            }
            .store(in: &cancellables)

        settings.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        register(settings.hotkey)
        refreshInputDevices()
    }

    convenience init() {
        self.init(
            settings: AppSettings(),
            modelManager: ModelManager(),
            permissionController: SystemPermissionController(),
            recordingController: AudioCaptureService(),
            textOutputController: ActiveAppTextOutputController(),
            hotkeyService: GlobalHotkeyService(),
            audioInputDeviceManager: AudioInputDeviceManager(),
            recordingFeedbackPlayer: SystemRecordingFeedbackPlayer()
        )
    }

    func toggleRecording() async {
        switch state {
        case .idle, .error:
            await startRecording()
        case .listening:
            await stopRecordingAndTranscribe()
        case .processing:
            return
        }
    }

    func refreshPermissions() {
        permissionStatus = permissionController.currentStatus()
        accessibilityDiagnostics = permissionController.accessibilityDiagnostics()
    }

    func refreshInputDevices() {
        availableInputDevices = audioInputDeviceManager.availableInputDevices()
    }

    func preferredInputDevice() -> AudioInputDevice? {
        guard let id = settings.preferredInputDeviceID else { return nil }
        return availableInputDevices.first(where: { $0.id == id })
    }

    func effectiveRecordingInputDevice() -> AudioInputDevice? {
        if let preferred = preferredInputDevice() {
            return preferred
        }

        guard let currentID = audioInputDeviceManager.defaultInputDeviceID() else {
            return nil
        }
        return availableInputDevices.first(where: { $0.id == currentID })
    }

    func shouldShowBluetoothInputWarning() -> Bool {
        settings.warnOnBluetoothInput && effectiveRecordingInputDevice()?.isBluetooth == true
    }

    func currentDefaultInputDeviceName() -> String {
        guard let currentID = audioInputDeviceManager.defaultInputDeviceID() else {
            return "Unknown"
        }

        if let device = availableInputDevices.first(where: { $0.id == currentID }) {
            return device.name
        }
        return "Audio Device \(currentID)"
    }

    func requestAccessibilityPermission() {
        _ = permissionController.requestAccessibilityIfNeeded(prompt: true)
        refreshPermissions()
    }

    func openAccessibilitySettings() {
        permissionController.openAccessibilitySettings()
    }

    func copyTranscriptToClipboard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
    }

    func clearTranscriptHistory() {
        settings.clearTranscriptHistory()
    }

    func downloadSelectedModel() async {
        guard let item = modelManager.catalog.first(where: { $0.id == settings.selectedModelID }) else {
            state = .error(message: UserFacingMessage.selectedModelNotFound)
            return
        }

        isDownloadingModel = true
        defer { isDownloadingModel = false }

        do {
            let localURL = try await modelManager.ensureModelAvailable(item)
            settings.activeModelPath = localURL.path
            state = .idle
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    private func startRecording() async {
        captureOutputTargetApp()

        let micGranted = await permissionController.requestMicrophoneIfNeeded()
        permissionStatus = permissionController.currentStatus()

        guard micGranted else {
            state = .error(message: UserFacingMessage.microphonePermissionDenied)
            return
        }

        do {
            refreshInputDevices()
            try applyPreferredInputDeviceIfNeeded()
            await settleAfterInputDeviceSwitchIfNeeded()
            if
                settings.warnOnBluetoothInput,
                let effectiveInput = effectiveRecordingInputDevice(),
                effectiveInput.isBluetooth
            {
                restorePreviousInputDeviceIfNeeded()
                state = .error(message: UserFacingMessage.bluetoothInputBlocked(effectiveInput.name))
                return
            }
            try await recordingController.start()
            recordingFeedbackPlayer.playStartCue()
            state = .listening(startedAt: Date())
        } catch {
            restorePreviousInputDeviceIfNeeded()
            state = .error(message: userFacingRecordingError(error))
        }
    }

    private func stopRecordingAndTranscribe() async {
        state = .processing

        do {
            let samples = try await recordingController.stop()
            recordingFeedbackPlayer.playStopCue()
            restorePreviousInputDeviceIfNeeded()

            let modelURL = try await resolveModelURL()
            try await transcriber.loadModel(at: modelURL)
            let language = settings.selectedLanguage == "auto" ? nil : settings.selectedLanguage
            let result = try await transcriber.transcribe(samples: samples, language: language)

            lastTranscript = result.text
            let trimmedTranscript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTranscript.isEmpty {
                settings.addTranscriptToHistory(trimmedTranscript, maxItems: ReleaseConfig.maxTranscriptHistoryItems)
                await activateOutputTargetAppIfNeeded()
                _ = try await textOutputController.insert(result.text)
            }

            outputTargetProcessID = nil
            state = .idle
        } catch {
            restorePreviousInputDeviceIfNeeded()
            outputTargetProcessID = nil
            state = .error(message: error.localizedDescription)
        }
    }

    private func resolveModelURL() async throws -> URL {
        if
            let path = settings.activeModelPath,
            FileManager.default.fileExists(atPath: path)
        {
            return URL(fileURLWithPath: path)
        }

        guard let item = modelManager.catalog.first(where: { $0.id == settings.selectedModelID }) else {
            throw ModelManagerError.catalogNotFound
        }

        let localURL = try await modelManager.ensureModelAvailable(item)
        settings.activeModelPath = localURL.path
        return localURL
    }

    private func register(_ hotkey: HotkeyCombination) {
        do {
            try hotkeyService.register(hotkey)
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    private func applyPreferredInputDeviceIfNeeded() throws {
        previousDefaultInputDeviceID = nil

        guard let preferredID = settings.preferredInputDeviceID else { return }
        guard availableInputDevices.contains(where: { $0.id == preferredID }) else {
            throw InputRoutingError.preferredInputUnavailable
        }

        if let currentID = audioInputDeviceManager.defaultInputDeviceID(), currentID != preferredID {
            previousDefaultInputDeviceID = currentID
            try audioInputDeviceManager.setDefaultInputDeviceID(preferredID)
        }
    }

    private func settleAfterInputDeviceSwitchIfNeeded() async {
        guard previousDefaultInputDeviceID != nil else { return }

        // Route changes (especially Bluetooth/HFP) are asynchronous in CoreAudio.
        let switchedToBluetooth = preferredInputDevice()?.isBluetooth == true
        let delayNs: UInt64 = switchedToBluetooth ? 700_000_000 : 250_000_000
        try? await Task.sleep(nanoseconds: delayNs)
        refreshInputDevices()
    }

    private func userFacingRecordingError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "com.apple.coreaudio.avfaudio", nsError.code == -10868 {
            return UserFacingMessage.audioRouteNotReady
        }
        return error.localizedDescription
    }

    private func restorePreviousInputDeviceIfNeeded() {
        guard let previousDefaultInputDeviceID else { return }
        defer { self.previousDefaultInputDeviceID = nil }
        try? audioInputDeviceManager.setDefaultInputDeviceID(previousDefaultInputDeviceID)
    }

    private func captureOutputTargetApp() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard
            let frontmost = NSWorkspace.shared.frontmostApplication,
            frontmost.processIdentifier != selfPID
        else {
            return
        }
        outputTargetProcessID = frontmost.processIdentifier
    }

    private func activateOutputTargetAppIfNeeded() async {
        guard let pid = outputTargetProcessID else { return }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }

        app.activate(options: [])
        // Give the target app a brief moment to become key before insertion.
        try? await Task.sleep(nanoseconds: 120_000_000)
    }
}
