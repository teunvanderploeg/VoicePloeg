import AppKit
import Combine
import Foundation

@MainActor
final class AppCoordinator: ObservableObject {
    @Published var state: AppState = .idle
    @Published var permissionStatus: PermissionStatus
    @Published var accessibilityDiagnostics: AccessibilityDiagnostics
    @Published var lastTranscript: String = ""
    @Published var isDownloadingModel = false
    @Published var isInstallingCrisperRuntime = false
    @Published var crisperRuntimeStatus: CrisperRuntimeStatus = .notInstalled
    @Published var availableInputDevices: [AudioInputDevice] = []
    /// Non-nil for 2 seconds after a language switch; contains the flag emoji for the new language.
    @Published var languageFeedbackFlag: String? = nil

    var settings: AppSettings
    var modelManager: ModelManager

    private let permissionController: PermissionController
    private let recordingController: RecordingController
    private let transcriber: SpeechTranscriptionService
    private let crisperRuntimeManager: CrisperRuntimeManager
    private let textOutputController: TextOutputController
    private let hotkeyService: GlobalHotkeyService
    private let audioInputDeviceManager: AudioInputDeviceManaging
    private let recordingFeedbackPlayer: RecordingFeedbackPlayer

    private var cancellables = Set<AnyCancellable>()
    private var previousDefaultInputDeviceID: UInt32?
    private var outputTargetProcessID: pid_t?
    private var recordingTranscriptionSelection: RecordingTranscriptionSelection?
    private var languageFeedbackTask: Task<Void, Never>?
    private var inputRecoveryTask: Task<Void, Never>?
    private var isWaitingForInputDevice = false
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(
        settings: AppSettings,
        modelManager: ModelManager,
        permissionController: PermissionController,
        recordingController: RecordingController,
        textOutputController: TextOutputController,
        hotkeyService: GlobalHotkeyService,
        audioInputDeviceManager: AudioInputDeviceManaging,
        recordingFeedbackPlayer: RecordingFeedbackPlayer,
        crisperRuntimeManager: CrisperRuntimeManager = CrisperRuntimeManager()
    ) {
        self.settings = settings
        self.modelManager = modelManager
        self.permissionController = permissionController
        self.recordingController = recordingController
        self.textOutputController = textOutputController
        self.hotkeyService = hotkeyService
        self.audioInputDeviceManager = audioInputDeviceManager
        self.recordingFeedbackPlayer = recordingFeedbackPlayer
        self.crisperRuntimeManager = crisperRuntimeManager

        transcriber = SpeechTranscriptionService(
            crisperTranscriber: CrisperWhisperTranscriber(runtimeManager: crisperRuntimeManager)
        )
        permissionStatus = permissionController.currentStatus()
        accessibilityDiagnostics = permissionController.accessibilityDiagnostics()

        hotkeyService.onTrigger = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.toggleRecording()
            }
        }

        hotkeyService.onLanguageCycleTrigger = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.cycleLanguage()
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

        settings.$selectedTranscriptionBackend
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.state != .processing else { return }
                Task { await self.transcriber.unloadCrisperModel() }
            }
            .store(in: &cancellables)

        settings.$selectedCrisperModelID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.state != .processing else { return }
                Task { await self.transcriber.unloadCrisperModel() }
            }
            .store(in: &cancellables)

        audioInputDeviceManager.setInputDeviceChangeHandler { [weak self] in
            Task { @MainActor in
                self?.refreshInputDevices()
            }
        }

        register(settings.hotkey)
        refreshInputDevices()
        configureMemoryPressureHandling()
        Task { [weak self] in
            await self?.refreshCrisperRuntimeStatus()
        }
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

    /// Cycles the transcription language through English → Dutch → English.
    func cycleLanguage() {
        let cycle = ["en", "nl"]
        let current = settings.selectedLanguage
        if let index = cycle.firstIndex(of: current) {
            settings.selectedLanguage = cycle[(index + 1) % cycle.count]
        } else {
            settings.selectedLanguage = "en"
        }
        showLanguageFlagFeedback()
    }

    private func showLanguageFlagFeedback() {
        let flag: String
        switch settings.selectedLanguage {
        case "en": flag = "🇬🇧"
        case "nl": flag = "🇳🇱"
        default:   flag = "🌐"
        }

        languageFeedbackTask?.cancel()
        languageFeedbackFlag = flag
        languageFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            languageFeedbackFlag = nil
        }
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

        guard !availableInputDevices.isEmpty else {
            isWaitingForInputDevice = true
            scheduleInputDeviceRecovery()
            switch state {
            case .idle, .error:
                state = .error(message: UserFacingMessage.noInputDeviceAvailable)
            case .listening, .processing:
                break
            }
            return
        }

        do {
            try recoverDefaultInputDeviceIfNeeded(prefersBuiltIn: isWaitingForInputDevice)
            if isWaitingForInputDevice {
                isWaitingForInputDevice = false
                inputRecoveryTask?.cancel()
                inputRecoveryTask = nil
                if case .error = state {
                    state = .idle
                }
            }
        } catch {
            isWaitingForInputDevice = true
            scheduleInputDeviceRecovery()
            switch state {
            case .idle, .error:
                state = .error(message: UserFacingMessage.inputDeviceRecoveryFailed)
            case .listening, .processing:
                break
            }
        }
    }

    private func scheduleInputDeviceRecovery() {
        guard inputRecoveryTask == nil else { return }

        inputRecoveryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }

                self.refreshInputDevices()
                guard self.isWaitingForInputDevice else { return }
            }
        }
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
        guard let item = selectedModel() else {
            state = .error(message: UserFacingMessage.selectedModelNotFound)
            return
        }

        isDownloadingModel = true
        defer { isDownloadingModel = false }

        do {
            if item.backend == .crisperWhisper {
                guard settings.acceptedCrisperLicenseVersion == ReleaseConfig.crisperLicenseVersion else {
                    throw CrisperRuntimeError.modelInstallationFailed(UserFacingMessage.crisperLicenseNotAccepted)
                }
                guard case .ready = crisperRuntimeStatus else {
                    throw CrisperRuntimeError.runtimeNotInstalled
                }
                let destination = try modelManager.localURL(for: item)
                try await crisperRuntimeManager.installModel(item, destination: destination)
            } else {
                let localURL = try await modelManager.ensureModelAvailable(item)
                settings.activeModelPath = localURL.path
            }
            state = .idle
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    func removeSelectedModel() async {
        guard let item = selectedModel() else { return }
        if item.backend == .crisperWhisper {
            await transcriber.unloadCrisperModel()
        }
        do {
            try modelManager.removeModel(item)
            if item.backend == .whisperCpp {
                settings.activeModelPath = nil
            }
            state = .idle
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    func acceptCrisperLicense() {
        settings.acceptedCrisperLicenseVersion = ReleaseConfig.crisperLicenseVersion
    }

    func installCrisperRuntime() async {
        isInstallingCrisperRuntime = true
        crisperRuntimeStatus = .installing
        defer { isInstallingCrisperRuntime = false }
        do {
            try await crisperRuntimeManager.install()
            await refreshCrisperRuntimeStatus()
            state = .idle
        } catch {
            crisperRuntimeStatus = .failed(message: error.localizedDescription)
            state = .error(message: error.localizedDescription)
        }
    }

    func removeCrisperRuntime() async {
        await transcriber.unloadCrisperModel()
        do {
            try await crisperRuntimeManager.remove()
            await refreshCrisperRuntimeStatus()
        } catch {
            crisperRuntimeStatus = .failed(message: error.localizedDescription)
        }
    }

    func refreshCrisperRuntimeStatus() async {
        crisperRuntimeStatus = await crisperRuntimeManager.status()
    }

    func selectedModel() -> SpeechModelDescriptor? {
        modelManager.model(id: settings.selectedModelID, backend: settings.selectedTranscriptionBackend)
    }

    func canUseSelectedBackend() -> Bool {
        guard settings.selectedTranscriptionBackend == .crisperWhisper else { return true }
        guard settings.selectedLanguage != "auto", case .ready = crisperRuntimeStatus else { return false }
        guard let model = selectedModel() else { return false }
        return modelManager.isDownloaded(model)
    }

    private func startRecording() async {
        guard let selectedModel = selectedModel() else {
            state = .error(message: UserFacingMessage.selectedModelNotFound)
            return
        }
        if settings.selectedTranscriptionBackend == .crisperWhisper {
            guard CrisperRuntimeManager.isCompatibleHardware else {
                state = .error(message: UserFacingMessage.crisperIncompatibleHardware)
                return
            }
            guard settings.selectedLanguage != "auto" else {
                state = .error(message: UserFacingMessage.crisperRequiresExplicitLanguage)
                return
            }
            guard case .ready = crisperRuntimeStatus else {
                state = .error(message: UserFacingMessage.crisperRuntimeMissing)
                return
            }
            guard modelManager.isDownloaded(selectedModel) else {
                state = .error(message: UserFacingMessage.crisperModelMissing)
                return
            }
        }
        recordingTranscriptionSelection = RecordingTranscriptionSelection(
            model: selectedModel,
            language: settings.selectedLanguage,
            whisperCLIPath: settings.whisperCLIPath
        )
        captureOutputTargetApp()

        let micGranted = await permissionController.requestMicrophoneIfNeeded()
        permissionStatus = permissionController.currentStatus()

        guard micGranted else {
            recordingTranscriptionSelection = nil
            state = .error(message: UserFacingMessage.microphonePermissionDenied)
            return
        }

        do {
            refreshInputDevices()
            guard !availableInputDevices.isEmpty else {
                recordingTranscriptionSelection = nil
                return
            }
            try applyPreferredInputDeviceIfNeeded()
            await settleAfterInputDeviceSwitchIfNeeded()
            if
                settings.warnOnBluetoothInput,
                let effectiveInput = effectiveRecordingInputDevice(),
                effectiveInput.isBluetooth
            {
                recordingTranscriptionSelection = nil
                restorePreviousInputDeviceIfNeeded()
                state = .error(message: UserFacingMessage.bluetoothInputBlocked(effectiveInput.name))
                return
            }
            try await recordingController.start()
            recordingFeedbackPlayer.playStartCue()
            state = .listening(startedAt: Date())
        } catch {
            recordingTranscriptionSelection = nil
            restorePreviousInputDeviceIfNeeded()
            state = .error(message: userFacingRecordingError(error))
        }
    }

    private func stopRecordingAndTranscribe() async {
        state = .processing
        defer { recordingTranscriptionSelection = nil }

        do {
            let samples = try await recordingController.stop()
            recordingFeedbackPlayer.playStopCue()
            restorePreviousInputDeviceIfNeeded()

            guard let selection = recordingTranscriptionSelection else {
                throw ModelManagerError.catalogNotFound
            }
            let modelURL = try await resolveModelURL(selection.model)
            let request = TranscriptionRequest(
                samples: samples,
                model: selection.model,
                localModelURL: modelURL,
                language: selection.language,
                whisperCLIPath: selection.whisperCLIPath
            )
            let result = try await transcriber.transcribe(request)

            lastTranscript = result.text
            let trimmedTranscript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTranscript.isEmpty {
                settings.addTranscriptToHistory(trimmedTranscript, maxItems: ReleaseConfig.maxTranscriptHistoryItems)
                guard let outputTargetProcessID else {
                    throw TextOutputError.targetApplicationUnavailable
                }
                _ = try await textOutputController.insert(
                    result.text,
                    targetProcessID: outputTargetProcessID
                )
            }

            outputTargetProcessID = nil
            state = .idle
        } catch {
            restorePreviousInputDeviceIfNeeded()
            outputTargetProcessID = nil
            state = .error(message: error.localizedDescription)
        }
    }

    private func resolveModelURL(_ item: SpeechModelDescriptor) async throws -> URL {
        if modelManager.isDownloaded(item) {
            return try modelManager.localURL(for: item)
        }
        if item.backend == .whisperCpp,
            let path = settings.activeModelPath,
            FileManager.default.fileExists(atPath: path),
            URL(fileURLWithPath: path).lastPathComponent.contains(item.id)
        {
            return URL(fileURLWithPath: path)
        }
        guard item.backend == .whisperCpp else { throw CrisperTranscriberError.modelMissing }
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

        guard let preferredID = settings.preferredInputDeviceID else {
            try recoverDefaultInputDeviceIfNeeded()
            return
        }
        guard availableInputDevices.contains(where: { $0.id == preferredID }) else {
            try recoverDefaultInputDeviceIfNeeded(prefersBuiltIn: true)
            return
        }

        let currentID = audioInputDeviceManager.defaultInputDeviceID()
        if currentID != preferredID {
            if let currentID, availableInputDevices.contains(where: { $0.id == currentID }) {
                previousDefaultInputDeviceID = currentID
            }
            try audioInputDeviceManager.setDefaultInputDeviceID(preferredID)
        }
    }

    private func recoverDefaultInputDeviceIfNeeded(prefersBuiltIn: Bool = false) throws {
        let fallback = AudioInputRecovery.fallbackDevice(
            in: availableInputDevices,
            currentDefaultID: audioInputDeviceManager.defaultInputDeviceID(),
            prefersBuiltIn: prefersBuiltIn
        )
        if let fallback {
            try audioInputDeviceManager.setDefaultInputDeviceID(fallback.id)
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
        outputTargetProcessID = nil
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard
            let frontmost = NSWorkspace.shared.frontmostApplication,
            frontmost.processIdentifier != selfPID
        else {
            return
        }
        outputTargetProcessID = frontmost.processIdentifier
    }

    private func configureMemoryPressureHandling() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.transcriber.unloadCrisperModel() }
        }
        source.resume()
        memoryPressureSource = source
    }
}

private struct RecordingTranscriptionSelection {
    let model: SpeechModelDescriptor
    let language: String
    let whisperCLIPath: String
}
