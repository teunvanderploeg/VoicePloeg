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
    @Published var isInstallingBarkRuntime = false
    @Published var barkRuntimeStatus: CrisperRuntimeStatus = .notInstalled
    @Published var isInstallingCrisperRuntime = false
    @Published var crisperRuntimeStatus: CrisperRuntimeStatus = .notInstalled
    @Published var availableInputDevices: [AudioInputDevice] = []
    /// Non-nil for 2 seconds after a language switch; contains the flag emoji for the new language.
    @Published var languageFeedbackFlag: String? = nil

    var settings: AppSettings
    var modelManager: ModelManager

    private let permissionController: PermissionController
    private let recordingController: RecordingController
    private let transcriber: any ManagedSpeechTranscribing
    private let barkRuntimeManager: BarkRuntimeManager
    private let crisperRuntimeManager: CrisperRuntimeManager
    private let textOutputController: TextOutputController
    private let hotkeyService: any GlobalHotkeyManaging
    private let audioInputDeviceManager: AudioInputDeviceManaging
    private let recordingFeedbackPlayer: RecordingFeedbackPlayer

    private let maxRecordingDurationSeconds: TimeInterval
    private var recordingLimitTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var previousDefaultInputDeviceID: UInt32?
    private var outputTargetProcessID: pid_t?
    private var recordingTranscriptionSelection: RecordingTranscriptionSelection?
    private var languageFeedbackTask: Task<Void, Never>?
    private var inputRecoveryTask: Task<Void, Never>?
    private var modelWarmupTask: Task<Void, Never>?
    private var warmingSelection: ModelWarmupSelection?
    private var isWaitingForInputDevice = false
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(
        settings: AppSettings,
        modelManager: ModelManager,
        permissionController: PermissionController,
        recordingController: RecordingController,
        textOutputController: TextOutputController,
        hotkeyService: any GlobalHotkeyManaging,
        audioInputDeviceManager: AudioInputDeviceManaging,
        recordingFeedbackPlayer: RecordingFeedbackPlayer,
        crisperRuntimeManager: CrisperRuntimeManager = CrisperRuntimeManager(),
        barkRuntimeManager: BarkRuntimeManager = BarkRuntimeManager(),
        transcriber: (any ManagedSpeechTranscribing)? = nil,
        maxRecordingDurationSeconds: TimeInterval = ReleaseConfig.maxRecordingDurationSeconds
    ) {
        self.settings = settings
        self.modelManager = modelManager
        settings.migrateModelAssignmentsIfNeeded(catalog: modelManager.catalog)
        self.permissionController = permissionController
        self.recordingController = recordingController
        self.textOutputController = textOutputController
        self.hotkeyService = hotkeyService
        self.audioInputDeviceManager = audioInputDeviceManager
        self.recordingFeedbackPlayer = recordingFeedbackPlayer
        self.barkRuntimeManager = barkRuntimeManager
        self.crisperRuntimeManager = crisperRuntimeManager

        self.maxRecordingDurationSeconds = maxRecordingDurationSeconds
        self.transcriber = transcriber ?? SpeechTranscriptionService(
            crisperTranscriber: CrisperWhisperTranscriber(runtimeManager: crisperRuntimeManager),
            barkTranscriber: BarkTranscriber(runtimeManager: barkRuntimeManager)
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

        settings.$selectedLanguage
            .combineLatest(settings.$defaultDictationModelID, settings.$englishDictationModelID, settings.$dutchDictationModelID)
            .dropFirst()
            .removeDuplicates { lhs, rhs in
                lhs.0 == rhs.0 && lhs.1 == rhs.1 && lhs.2 == rhs.2 && lhs.3 == rhs.3
            }
            .sink { [weak self] _ in
                guard let self else { return }
                guard !self.state.isDictationActive else { return }
                // Published values arrive before AppSettings updates its stored selection.
                Task { @MainActor [weak self] in
                    self?.scheduleSelectedModelWarmup(releaseCurrentModels: true)
                }
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
            await self?.refreshBarkRuntimeStatus()
            self?.scheduleSelectedModelWarmup()
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
        case .starting, .processing:
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
            case .starting, .listening, .processing:
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
            case .starting, .listening, .processing:
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

    var canManageModels: Bool {
        !state.isDictationActive && !isDownloadingModel && !isInstallingCrisperRuntime && !isInstallingBarkRuntime
    }

    func downloadSelectedModel() async {
        guard canManageModels else { return }
        guard let item = modelToManage() else {
            state = .error(message: UserFacingMessage.selectedModelNotFound)
            return
        }

        isDownloadingModel = true
        defer { isDownloadingModel = false }

        do {
            if item.backend == .bark {
                guard case .ready = barkRuntimeStatus else { throw BarkError.runtimeMissing }
                if !modelManager.isDownloaded(item) {
                    let destination = try modelManager.localURL(for: item)
                    try await barkRuntimeManager.installModel(item, destination: destination)
                }
            } else if item.backend == .crisperWhisper {
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
            scheduleSelectedModelWarmup()
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    func removeSelectedModel() async {
        guard canManageModels, let item = modelToManage() else { return }
        isDownloadingModel = true
        defer { isDownloadingModel = false }
        modelWarmupTask?.cancel()
        modelWarmupTask = nil
        warmingSelection = nil
        await transcriber.releasePreloadedModels()
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
        guard canManageModels else { return }
        isInstallingCrisperRuntime = true
        crisperRuntimeStatus = .installing
        defer { isInstallingCrisperRuntime = false }
        do {
            try await crisperRuntimeManager.install()
            await refreshCrisperRuntimeStatus()
            state = .idle
            scheduleSelectedModelWarmup()
        } catch {
            crisperRuntimeStatus = .failed(message: error.localizedDescription)
            state = .error(message: error.localizedDescription)
        }
    }

    func removeCrisperRuntime() async {
        guard canManageModels else { return }
        isInstallingCrisperRuntime = true
        defer { isInstallingCrisperRuntime = false }
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

    func installBarkRuntime() async {
        guard canManageModels else { return }
        isInstallingBarkRuntime = true
        barkRuntimeStatus = .installing
        defer { isInstallingBarkRuntime = false }
        modelWarmupTask?.cancel()
        modelWarmupTask = nil
        warmingSelection = nil
        await transcriber.unloadBarkModel()
        do {
            try await barkRuntimeManager.install()
            await refreshBarkRuntimeStatus()
            state = .idle
            scheduleSelectedModelWarmup()
        } catch {
            barkRuntimeStatus = .failed(message: error.localizedDescription)
            state = .error(message: error.localizedDescription)
        }
    }

    func removeBarkRuntime() async {
        guard canManageModels else { return }
        isInstallingBarkRuntime = true
        defer { isInstallingBarkRuntime = false }
        modelWarmupTask?.cancel()
        modelWarmupTask = nil
        warmingSelection = nil
        await transcriber.unloadBarkModel()
        do {
            try await barkRuntimeManager.remove()
            await refreshBarkRuntimeStatus()
        } catch {
            barkRuntimeStatus = .failed(message: error.localizedDescription)
        }
    }

    func refreshBarkRuntimeStatus() async {
        barkRuntimeStatus = await barkRuntimeManager.status()
    }

    func selectedModel() -> SpeechModelDescriptor? {
        let id = settings.dictationModelID(for: settings.selectedLanguage)
        return modelManager.catalog.first { $0.id == id }
    }

    func modelToManage() -> SpeechModelDescriptor? {
        modelManager.model(id: settings.selectedModelID, backend: settings.selectedTranscriptionBackend)
    }

    func selectModelForManagement(id: String) {
        guard let model = modelManager.catalog.first(where: { $0.id == id }) else { return }
        settings.selectedTranscriptionBackend = model.backend
        settings.selectedModelID = model.id
    }

    func canUseSelectedBackend() -> Bool {
        guard let model = selectedModel(), model.supports(language: settings.selectedLanguage) else { return false }
        if model.backend == .bark {
            guard settings.selectedLanguage == "en", case .ready = barkRuntimeStatus,
                  CrisperRuntimeManager.isCompatibleHardware else { return false }
            return modelManager.isDownloaded(model)
        }
        guard model.backend == .crisperWhisper else { return true }
        guard settings.selectedLanguage != "auto", case .ready = crisperRuntimeStatus else { return false }
        return modelManager.isDownloaded(model)
    }

    private func startRecording() async {
        guard canManageModels else { return }
        guard let selectedModel = selectedModel() else {
            state = .error(message: UserFacingMessage.selectedModelNotFound)
            return
        }
        guard selectedModel.supports(language: settings.selectedLanguage) else {
            state = .error(message: selectedModel.backend == .bark
                ? UserFacingMessage.barkEnglishOnly
                : settings.selectedLanguage == "auto"
                    ? UserFacingMessage.crisperRequiresExplicitLanguage
                    : UserFacingMessage.modelLanguageMismatch)
            return
        }
        if selectedModel.backend == .bark {
            guard CrisperRuntimeManager.isCompatibleHardware else {
                state = .error(message: UserFacingMessage.barkIncompatibleHardware)
                return
            }
            guard case .ready = barkRuntimeStatus else {
                state = .error(message: UserFacingMessage.barkRuntimeMissing)
                return
            }
            guard modelManager.isDownloaded(selectedModel) else {
                state = .error(message: UserFacingMessage.barkModelMissing)
                return
            }
        }
        if selectedModel.backend == .crisperWhisper {
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
        scheduleSelectedModelWarmup()
        captureOutputTargetApp()
        state = .starting

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
                state = .error(message: UserFacingMessage.noInputAtStart)
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
            scheduleRecordingLimit()
        } catch {
            recordingTranscriptionSelection = nil
            restorePreviousInputDeviceIfNeeded()
            state = .error(message: userFacingRecordingError(error))
        }
    }

    private func scheduleRecordingLimit() {
        recordingLimitTask?.cancel()
        let duration = maxRecordingDurationSeconds
        recordingLimitTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            guard let self, case .listening = self.state else { return }
            // Clear before stopping so the automatic stop cannot cancel itself.
            self.recordingLimitTask = nil
            await self.stopRecordingAndTranscribe()
        }
    }

    private func stopRecordingAndTranscribe() async {
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
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
        if item.backend == .bark {
            guard modelManager.isDownloaded(item) else { throw BarkError.modelMissing }
            return try modelManager.localURL(for: item)
        }
        if item.backend == .crisperWhisper {
            guard modelManager.isDownloaded(item) else { throw CrisperTranscriberError.modelMissing }
            return try modelManager.localURL(for: item)
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
        source.setEventHandler(handler: Self.makeMemoryPressureHandler { [weak self] in
            guard let self else { return }
            self.modelWarmupTask?.cancel()
            self.modelWarmupTask = nil
            self.warmingSelection = nil
            await self.transcriber.releasePreloadedModels()
        })
        source.resume()
        memoryPressureSource = source
    }

    nonisolated static func makeMemoryPressureHandler(
        operation: @escaping @MainActor @Sendable () async -> Void
    ) -> @Sendable () -> Void {
        {
            Task { @MainActor in
                await operation()
            }
        }
    }

    private func scheduleSelectedModelWarmup(releaseCurrentModels: Bool = false) {
        guard !state.isDictationActive else { return }
        if releaseCurrentModels {
            modelWarmupTask?.cancel()
            warmingSelection = nil
        }
        let model = selectedModel()
        let modelURL = model.flatMap { modelManager.isDownloaded($0) ? try? modelManager.localURL(for: $0) : nil }
        let runtimeReady: Bool
        switch model?.backend {
        case .bark:
            if case .ready = barkRuntimeStatus { runtimeReady = true } else { runtimeReady = false }
        case .crisperWhisper:
            if case .ready = crisperRuntimeStatus { runtimeReady = true } else { runtimeReady = false }
        default:
            runtimeReady = true
        }
        let selection = modelURL.flatMap { url in
            model.map { ModelWarmupSelection(backend: $0.backend, modelPath: url.path) }
        }
        if !releaseCurrentModels, warmingSelection == selection, modelWarmupTask != nil { return }
        modelWarmupTask?.cancel()
        warmingSelection = selection
        let transcriber = self.transcriber
        modelWarmupTask = Task { [weak self] in
            if releaseCurrentModels { await transcriber.releasePreloadedModels() }
            guard !Task.isCancelled, runtimeReady, let model, let modelURL else { return }
            try? await transcriber.preloadModel(at: modelURL, backend: model.backend)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.warmingSelection == selection else { return }
                self?.modelWarmupTask = nil
            }
        }
    }
}

private struct RecordingTranscriptionSelection {
    let model: SpeechModelDescriptor
    let language: String
    let whisperCLIPath: String
}

private struct ModelWarmupSelection: Equatable {
    let backend: SpeechBackend
    let modelPath: String
}
