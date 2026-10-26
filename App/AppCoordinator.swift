import AppKit
import Combine
import Foundation

@MainActor
final class AppCoordinator: ObservableObject {
    let isDesignPreview: Bool
    @Published private(set) var state: AppState = .idle
    @Published private(set) var configurationError: String?
    @Published private(set) var preparationError: String?
    @Published private(set) var isPreparingModel = false
    @Published private(set) var hasRetainedRecording = false
    @Published private(set) var lastTimings = DictationTimings()
    @Published var permissionStatus: PermissionStatus
    @Published var accessibilityDiagnostics: AccessibilityDiagnostics
    @Published var lastTranscript: String = ""
    @Published private(set) var isLiveDictating = false
    @Published private(set) var liveTranscript = ""
    @Published private(set) var liveOutputMessage: String?
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
    private let inputRouteController: InputRouteController
    private let outputTargetProvider: (@MainActor () -> pid_t?)?
    private let idleTimeoutSeconds: TimeInterval
    private var registeredHotkey: HotkeyCombination?
    private var isCaptureActive = false
    private var isShuttingDown = false
    private var isReleasingModels = false
    private var captureDeviceID: UInt32?
    private var recordingModelURL: URL?
    private var retainedRequest: TranscriptionRequest?
    private var transcriptionTask: Task<TranscriptResult, Error>?
    private var insertionTask: Task<TextInsertionMethod, Error>?
    private var idleUnloadTask: Task<Void, Never>?
    private var warmupGeneration = UUID()
    private var outputTargetProcessID: pid_t?
    private var recordingTranscriptionSelection: RecordingTranscriptionSelection?
    private var languageFeedbackTask: Task<Void, Never>?
    private var inputRecoveryTask: Task<Void, Never>?
    private var modelWarmupTask: Task<Void, Never>?
    private var warmingSelection: ModelWarmupSelection?
    private var isWaitingForInputDevice = false
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var liveTask: Task<Void, Never>?
    private var liveBuffer = LiveDictationBuffer()
    private var liveAccumulator = LiveTranscriptAccumulator()
    private var liveModelURL: URL?
    private var liveOutputError: Error?
    private var livePendingChunks: [[Float]] = []

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
        maxRecordingDurationSeconds: TimeInterval = ReleaseConfig.maxRecordingDurationSeconds,
        idleTimeoutSeconds: TimeInterval = ReleaseConfig.modelIdleTimeoutSeconds,
        outputTargetProvider: (@MainActor () -> pid_t?)? = nil,
        isDesignPreview: Bool = false
    ) {
        self.isDesignPreview = isDesignPreview
        self.settings = settings
        self.inputRouteController = InputRouteController(settings: settings, devices: audioInputDeviceManager)
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.outputTargetProvider = outputTargetProvider
        self.modelManager = modelManager
        if !isDesignPreview {
            settings.migrateModelAssignmentsIfNeeded(catalog: modelManager.catalog)
        }
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

        // The visual fixture uses inert dependencies and no runtime preparation.
        guard !isDesignPreview else { return }

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
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] hotkey in
                Task { @MainActor [weak self] in
                    guard let self, self.settings.hotkey == hotkey else { return }
                    self.changeHotkey(hotkey)
                }
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

        settings.$automaticDictationModelID.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleSelectedModelWarmup(releaseCurrentModels: true) }
        }.store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshPermissions()
                    self?.settings.pruneTranscriptHistory()
                }
            }.store(in: &cancellables)

        recordingController.setInterruptionHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isCaptureActive else { return }
                await self.stopRecordingAndTranscribe(captureInterrupted: true)
            }
        }

        audioInputDeviceManager.setInputDeviceChangeHandler { [weak self] in
            Task { @MainActor in
                self?.refreshInputDevices()
            }
        }

        changeHotkey(settings.hotkey)
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
        guard !isDesignPreview else { return }
        guard !isShuttingDown else { return }
        if isCaptureActive {
            await stopRecordingAndTranscribe()
            return
        }
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
        if settings.preferredInputDeviceUID == nil, let legacyID = settings.preferredInputDeviceID,
           let device = availableInputDevices.first(where: { $0.id == legacyID }) {
            settings.preferredInputDeviceUID = device.uid
            settings.preferredInputDeviceID = nil
        }
        if !state.isDictationActive {
            do { try inputRouteController.restore(available: availableInputDevices) }
            catch { configurationError = UserFacingMessage.inputRestoreFailed }
        }
        if isCaptureActive, let captureDeviceID,
           !availableInputDevices.contains(where: { $0.id == captureDeviceID }) {
            Task { @MainActor [weak self] in await self?.stopRecordingAndTranscribe(captureInterrupted: true) }
        }

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
        guard let uid = settings.preferredInputDeviceUID else { return nil }
        return availableInputDevices.first(where: { $0.uid == uid })
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

    func openMicrophoneSettings() {
        permissionController.openMicrophoneSettings()
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
        lastTranscript = ""
    }

    var canManageModels: Bool {
        !isShuttingDown && !isReleasingModels && !isCaptureActive && !state.isDictationActive
            && !isDownloadingModel && !isInstallingCrisperRuntime && !isInstallingBarkRuntime
    }

    func downloadSelectedModel() async {
        guard canManageModels else { return }
        guard let item = modelToManage() else {
            state = .error(message: UserFacingMessage.selectedModelNotFound)
            return
        }

        isDownloadingModel = true
        defer {
            isDownloadingModel = false
            scheduleSelectedModelWarmup()
        }
        await cancelModelPreparation(releaseModels: true)

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
        defer {
            isDownloadingModel = false
            scheduleSelectedModelWarmup()
        }
        await cancelModelPreparation(releaseModels: true)
        do {
            try await modelManager.removeModel(item)
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
        defer {
            isInstallingCrisperRuntime = false
            scheduleSelectedModelWarmup()
        }
        await cancelModelPreparation(releaseModels: true)
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
        defer {
            isInstallingCrisperRuntime = false
            scheduleSelectedModelWarmup()
        }
        await cancelModelPreparation(releaseModels: true)
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
        defer {
            isInstallingBarkRuntime = false
            scheduleSelectedModelWarmup()
        }
        await cancelModelPreparation(releaseModels: true)
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
        defer {
            isInstallingBarkRuntime = false
            scheduleSelectedModelWarmup()
        }
        await cancelModelPreparation(releaseModels: true)
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
        guard let model = selectedModel(), model.supports(language: settings.selectedLanguage), modelManager.isDownloaded(model) else { return false }
        if model.backend == .bark {
            guard settings.selectedLanguage == "en", case .ready = barkRuntimeStatus,
                  CrisperRuntimeManager.isCompatibleHardware else { return false }
            return modelManager.isDownloaded(model)
        }
        guard model.backend == .crisperWhisper else {
            return WhisperCLIResolver.resolve(configuredPath: settings.whisperCLIPath) != nil
        }
        guard settings.selectedLanguage != "auto", case .ready = crisperRuntimeStatus else { return false }
        return modelManager.isDownloaded(model)
    }

    var selectedModelReadinessMessage: String {
        guard let model = selectedModel() else { return UserFacingMessage.selectedModelNotFound }
        guard model.supports(language: settings.selectedLanguage) else { return UserFacingMessage.modelLanguageMismatch }
        if isPreparingModel { return UserFacingMessage.modelPreparing }
        if model.backend == .bark {
            guard case .ready = barkRuntimeStatus else { return UserFacingMessage.barkRuntimeMissing }
        }
        if model.backend == .crisperWhisper {
            guard case .ready = crisperRuntimeStatus else { return UserFacingMessage.crisperRuntimeMissing }
        }
        guard modelManager.isDownloaded(model) else { return UserFacingMessage.modelNotInstalled }
        if model.backend == .whisperCpp, WhisperCLIResolver.resolve(configuredPath: settings.whisperCLIPath) == nil {
            return UserFacingMessage.whisperExecutableMissing
        }
        return UserFacingMessage.modelReady
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
                    ? UserFacingMessage.autoRequiresMultilingual
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
            whisperCLIPath: settings.whisperCLIPath,
            liveDictation: settings.liveDictationEnabled
        )
        idleUnloadTask?.cancel()
        captureOutputTargetApp()
        state = .starting
        let preparationStarted = ContinuousClock.now
        do {
            guard permissionController.currentStatus().accessibilityGranted else {
                throw TextOutputError.accessibilityUnavailable
            }
            if selectedModel.backend == .whisperCpp {
                guard WhisperCLIResolver.resolve(configuredPath: settings.whisperCLIPath) != nil else {
                    throw WhisperTranscriberError.whisperCLINotFound(settings.whisperCLIPath)
                }
            }
            // Only check installation here. Hashing and loading a cold model must
            // never delay opening the microphone.
            guard modelManager.isDownloaded(selectedModel) else { throw ModelManagerError.modelNotInstalled }
            recordingModelURL = try modelManager.localURL(for: selectedModel)
            lastTimings = DictationTimings()
            try Task.checkCancellation()
            guard !isShuttingDown else { return }
        } catch {
            recordingTranscriptionSelection = nil
            outputTargetProcessID = nil
            state = .error(message: error.localizedDescription)
            return
        }

        let micGranted = await permissionController.requestMicrophoneIfNeeded()
        permissionStatus = permissionController.currentStatus()

        guard !isShuttingDown else { return }
        guard micGranted else {
            recordingTranscriptionSelection = nil
            state = .error(message: UserFacingMessage.microphonePermissionDenied)
            return
        }

        do {
            if recordingTranscriptionSelection?.liveDictation == true {
                guard let outputTargetProcessID else { throw TextOutputError.liveTextFieldRequired }
                try textOutputController.beginLiveInsertion(targetProcessID: outputTargetProcessID)
                liveModelURL = recordingModelURL
            }
            refreshInputDevices()
            guard !availableInputDevices.isEmpty else {
                recordingTranscriptionSelection = nil
                state = .error(message: UserFacingMessage.noInputAtStart)
                return
            }
            try applyPreferredInputDeviceIfNeeded()
            await settleAfterInputDeviceSwitchIfNeeded()
            let captureInput = availableInputDevices.first { $0.id == audioInputDeviceManager.defaultInputDeviceID() }
            if
                settings.warnOnBluetoothInput,
                let effectiveInput = captureInput,
                effectiveInput.isBluetooth
            {
                recordingTranscriptionSelection = nil
                restorePreviousInputDeviceIfNeeded()
                state = .error(message: UserFacingMessage.bluetoothInputBlocked(effectiveInput.name))
                return
            }
            try Task.checkCancellation()
            guard !isShuttingDown else { return }
            discardRetainedRecording()
            try await recordingController.start()
            guard !isShuttingDown else { _ = try? await recordingController.stop(); return }
            isCaptureActive = true
            captureDeviceID = captureInput?.id
            recordingFeedbackPlayer.playStartCue()
            lastTimings.preparation = DictationTimings.seconds(preparationStarted.duration(to: .now))
            state = .listening(startedAt: Date())
            scheduleSelectedModelWarmup()
            if recordingTranscriptionSelection?.liveDictation == true {
                startLiveDictation()
            }
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
            guard let self, self.isCaptureActive else { return }
            // Clear before stopping so the automatic stop cannot cancel itself.
            self.recordingLimitTask = nil
            await self.stopRecordingAndTranscribe()
        }
    }

    private func stopRecordingAndTranscribe(captureInterrupted: Bool = false) async {
        guard isCaptureActive else { return }
        isCaptureActive = false
        captureDeviceID = nil
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        state = .processing
        defer {
            recordingTranscriptionSelection = nil
            recordingModelURL = nil
            outputTargetProcessID = nil
            scheduleSelectedModelWarmup()
            scheduleIdleUnload()
        }
        if isLiveDictating {
            if captureInterrupted {
                liveOutputError = TextOutputError.targetFocusUnavailable
                liveOutputMessage = UserFacingMessage.liveOutputPaused
            }
            await finishLiveDictation(captureInterrupted: captureInterrupted)
            return
        }
        do {
            let samples = try await recordingController.stop()
            recordingFeedbackPlayer.playStopCue()
            restorePreviousInputDeviceIfNeeded()
            guard let selection = recordingTranscriptionSelection, let modelURL = recordingModelURL else {
                throw ModelManagerError.modelNotInstalled
            }
            retainedRequest = TranscriptionRequest(samples: samples, model: selection.model,
                localModelURL: modelURL, language: selection.language, whisperCLIPath: selection.whisperCLIPath)
            hasRetainedRecording = !samples.isEmpty
            if captureInterrupted {
                state = .error(message: UserFacingMessage.inputDisconnected)
                return
            }
            try await transcribeRetainedRecording(deliverToOriginalTarget: true)
        } catch {
            restorePreviousInputDeviceIfNeeded()
            if !isShuttingDown { state = .error(message: error.localizedDescription) }
        }
    }

    private func startLiveDictation() {
        isLiveDictating = true
        liveTranscript = ""
        liveOutputMessage = nil
        liveOutputError = nil
        livePendingChunks = []
        liveAccumulator = LiveTranscriptAccumulator()
        liveBuffer = LiveDictationBuffer()
        liveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.isShuttingDown, !Task.isCancelled, case .listening = self.state {
                let chunks = await self.liveBuffer.read(from: self.recordingController)
                do {
                    try await self.transcribeLiveChunks(chunks)
                } catch {
                    // Finish retries the untranscribed chunk once, and drains the tail.
                    Task { @MainActor [weak self] in
                        guard let self, !self.isShuttingDown, case .listening = self.state else { return }
                        await self.stopRecordingAndTranscribe()
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func transcribeLiveChunks(_ chunks: [[Float]]) async throws {
        guard let selection = recordingTranscriptionSelection, let liveModelURL else {
            throw ModelManagerError.catalogNotFound
        }
        for (index, samples) in chunks.enumerated() {
            let result: TranscriptResult
            do {
                try Task.checkCancellation()
                guard !isShuttingDown else { return }
                let request = TranscriptionRequest(
                    samples: samples, model: selection.model, localModelURL: liveModelURL,
                    language: selection.language, whisperCLIPath: selection.whisperCLIPath
                )
                let started = ContinuousClock.now
                let task = Task { try await self.transcribeWithPreparedModel(request) }
                transcriptionTask = task
                defer { transcriptionTask = nil }
                result = try await task.value
                lastTimings.transcription += DictationTimings.seconds(started.duration(to: .now))
            } catch {
                livePendingChunks = Array(chunks[index...])
                throw error
            }
            guard let fragment = liveAccumulator.append(result.text) else { continue }
            liveTranscript = liveAccumulator.text
            guard liveOutputError == nil, !isShuttingDown else { continue }
            do {
                guard let outputTargetProcessID else { throw TextOutputError.targetApplicationUnavailable }
                let output = textOutputController
                let started = ContinuousClock.now
                let insertion = Task { try await output.insertLive(fragment, targetProcessID: outputTargetProcessID) }
                insertionTask = insertion
                defer { insertionTask = nil }
                _ = try await insertion.value
                lastTimings.insertion += DictationTimings.seconds(started.duration(to: .now))
            } catch {
                // An event may already have reached the editor. Never replay it or
                // send later phrases to a different field. Keep transcribing for History.
                liveOutputError = error
                liveOutputMessage = UserFacingMessage.liveOutputPaused
            }
        }
    }

    private func finishLiveDictation(captureInterrupted: Bool) async {
        var failure: Error?
        do {
            _ = try await recordingController.stop()
        } catch {
            failure = error
        }
        recordingFeedbackPlayer.playStopCue()
        restorePreviousInputDeviceIfNeeded()
        // Do not cancel inference or a pending paste when Stop is pressed.
        await liveTask?.value
        liveTask = nil
        let remaining = await liveBuffer.read(from: recordingController, finishing: true)
        let chunks = livePendingChunks + remaining
        livePendingChunks = []
        if !isShuttingDown {
            do {
                try await transcribeLiveChunks(chunks)
            } catch {
                failure = error
            }
        }
        saveLiveTranscript()
        if !livePendingChunks.isEmpty, !isShuttingDown,
           let selection = recordingTranscriptionSelection, let liveModelURL {
            // Retrying is copy-only, like other retained recordings. Already
            // recognized phrases are excluded so the editor cannot receive them twice.
            let samples = livePendingChunks.flatMap { $0 }
            retainedRequest = TranscriptionRequest(samples: samples, model: selection.model,
                localModelURL: liveModelURL, language: selection.language, whisperCLIPath: selection.whisperCLIPath)
            hasRetainedRecording = !samples.isEmpty
        }
        outputTargetProcessID = nil
        liveModelURL = nil
        livePendingChunks = []
        if isShuttingDown {
            state = .idle
        } else if captureInterrupted {
            state = .error(message: UserFacingMessage.inputDisconnected)
        } else if let failure {
            state = .error(message: failure.localizedDescription)
        } else if liveOutputError != nil {
            state = .error(message: UserFacingMessage.liveOutputSaved)
        } else {
            state = .idle
        }
    }

    private func saveLiveTranscript() {
        guard isLiveDictating else { return }
        lastTranscript = liveAccumulator.text
        settings.addTranscriptToHistory(lastTranscript, maxItems: ReleaseConfig.maxTranscriptHistoryItems)
        isLiveDictating = false
    }

    func retryTranscription() async {
        guard canManageModels, retainedRequest != nil else { return }
        state = .processing
        defer { scheduleSelectedModelWarmup(); scheduleIdleUnload() }
        do {
            try await transcribeRetainedRecording(deliverToOriginalTarget: false)
        } catch {
            if !isShuttingDown { state = .error(message: error.localizedDescription) }
        }
    }

    func discardRetainedRecording() {
        retainedRequest = nil
        hasRetainedRecording = false
    }

    private func transcribeWithPreparedModel(_ request: TranscriptionRequest) async throws -> TranscriptResult {
        // An idle warmup may still be loading. Capture continues while we wait,
        // and the tracked transcription task owns cancellation during shutdown.
        await modelWarmupTask?.value
        try Task.checkCancellation()
        guard !isShuttingDown else { throw CancellationError() }
        _ = try await modelManager.verifiedInstalledURL(for: request.model)
        try Task.checkCancellation()
        try await transcriber.preloadModel(at: request.localModelURL, backend: request.model.backend)
        try Task.checkCancellation()
        guard !isShuttingDown else { throw CancellationError() }
        return try await transcriber.transcribe(request)
    }

    private func transcribeRetainedRecording(deliverToOriginalTarget: Bool) async throws {
        guard let request = retainedRequest else { return }
        let transcriptionStarted = ContinuousClock.now
        let task = Task { try await self.transcribeWithPreparedModel(request) }
        transcriptionTask = task
        defer { transcriptionTask = nil }
        let result = try await task.value
        lastTimings.transcription = DictationTimings.seconds(transcriptionStarted.duration(to: .now))
        guard !isShuttingDown else { return }
        // Once recognized, insertion failure must never cause a second transcription/paste.
        discardRetainedRecording()
        lastTranscript = result.text
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            settings.addTranscriptToHistory(trimmed, maxItems: ReleaseConfig.maxTranscriptHistoryItems)
            if deliverToOriginalTarget {
                guard let outputTargetProcessID else { throw TextOutputError.targetApplicationUnavailable }
                let insertionStarted = ContinuousClock.now
                defer { lastTimings.insertion = DictationTimings.seconds(insertionStarted.duration(to: .now)) }
                let output = textOutputController
                let insertion = Task { try await output.insert(result.text, targetProcessID: outputTargetProcessID) }
                insertionTask = insertion
                defer { insertionTask = nil }
                _ = try await insertion.value
            }
        }
        state = .idle
    }

    func changeHotkey(_ hotkey: HotkeyCombination) {
        guard hotkey != registeredHotkey else { return }
        if state.isDictationActive || isCaptureActive {
            configurationError = UserFacingMessage.hotkeyDuringRecording
            if let registeredHotkey { settings.hotkey = registeredHotkey }
            return
        }
        do {
            guard hotkey.isValidRecordingShortcut else { throw GlobalHotkeyError.invalidCombination }
            try hotkeyService.register(hotkey)
            registeredHotkey = hotkey
            configurationError = hotkeyService.registrationWarning
            if settings.hotkey != hotkey { settings.hotkey = hotkey }
        } catch {
            configurationError = error.localizedDescription
            if let registeredHotkey, settings.hotkey != registeredHotkey { settings.hotkey = registeredHotkey }
        }
    }

    private func applyPreferredInputDeviceIfNeeded() throws {
        if preferredInputDevice() == nil { try recoverDefaultInputDeviceIfNeeded() }
        try inputRouteController.begin(preferred: preferredInputDevice(), available: availableInputDevices)
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
        guard inputRouteController.hasPendingRestoration else { return }

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
        do { try inputRouteController.restore(available: audioInputDeviceManager.availableInputDevices()) }
        catch { configurationError = UserFacingMessage.inputRestoreFailed }
    }

    private func captureOutputTargetApp() {
        outputTargetProcessID = nil
        if let outputTargetProvider { outputTargetProcessID = outputTargetProvider(); return }
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
            guard let self, self.canManageModels else { return }
            self.isReleasingModels = true
            defer { self.isReleasingModels = false }
            await self.cancelModelPreparation(releaseModels: true)
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
        // Loading may run alongside capture. Releasing models still requires idle.
        guard canManageModels || (isCaptureActive && !releaseCurrentModels) else { return }
        idleUnloadTask?.cancel()
        if releaseCurrentModels {
            modelWarmupTask?.cancel()
            warmingSelection = nil
        }
        let model = isCaptureActive ? recordingTranscriptionSelection?.model : selectedModel()
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
        let previousWarmup = modelWarmupTask
        previousWarmup?.cancel()
        warmingSelection = selection
        let transcriber = self.transcriber
        let generation = UUID()
        warmupGeneration = generation
        modelWarmupTask = Task { [weak self] in
            if releaseCurrentModels {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            await previousWarmup?.value
            guard !Task.isCancelled, let self else { return }
            let preparesRecording = self.isCaptureActive && self.recordingTranscriptionSelection?.model.id == model?.id
            guard self.canManageModels || preparesRecording else { return }
            self.isPreparingModel = true
            self.preparationError = nil
            defer {
                if self.warmupGeneration == generation {
                    self.isPreparingModel = false
                    self.modelWarmupTask = nil
                    self.scheduleIdleUnload()
                }
            }
            if releaseCurrentModels, self.canManageModels { await transcriber.releasePreloadedModels() }
            guard !Task.isCancelled, runtimeReady, let model, let modelURL else { return }
            do {
                _ = try await self.modelManager.verifiedInstalledURL(for: model)
                guard !Task.isCancelled, !self.isShuttingDown else { return }
                try await transcriber.preloadModel(at: modelURL, backend: model.backend)
            } catch is CancellationError {
                return
            } catch {
                if self.warmupGeneration == generation { self.preparationError = error.localizedDescription }
            }
        }
    }
    private func cancelModelPreparation(releaseModels: Bool) async {
        idleUnloadTask?.cancel()
        warmupGeneration = UUID()
        let previous = modelWarmupTask
        modelWarmupTask = nil
        warmingSelection = nil
        isPreparingModel = false
        previous?.cancel()
        await previous?.value
        if releaseModels { await transcriber.releasePreloadedModels() }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        guard canManageModels, !isPreparingModel else { return }
        let timeout = idleTimeoutSeconds
        idleUnloadTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            guard let self, self.canManageModels, !self.isPreparingModel else { return }
            self.idleUnloadTask = nil
            await self.cancelModelPreparation(releaseModels: true)
        }
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        recordingLimitTask?.cancel()
        inputRecoveryTask?.cancel()
        languageFeedbackTask?.cancel()
        idleUnloadTask?.cancel()
        liveTask?.cancel()
        modelWarmupTask?.cancel()
        transcriptionTask?.cancel()
        insertionTask?.cancel()
        if isCaptureActive {
            isCaptureActive = false
            _ = try? await recordingController.stop()
        }
        restorePreviousInputDeviceIfNeeded()
        _ = await transcriptionTask?.result
        _ = await insertionTask?.result
        await liveTask?.value
        liveTask = nil
        saveLiveTranscript()
        liveModelURL = nil
        livePendingChunks = []
        discardRetainedRecording()
        await cancelModelPreparation(releaseModels: true)
        state = .idle
    }

}

private struct RecordingTranscriptionSelection: Sendable {
    let model: SpeechModelDescriptor
    let language: String
    let whisperCLIPath: String
    let liveDictation: Bool
}

private struct ModelWarmupSelection: Equatable {
    let backend: SpeechBackend
    let modelPath: String
}
