import PloegKit
import SwiftUI

private enum SettingsPage: String, CaseIterable, Identifiable {
    case overview, recording, transcription, history
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return UserFacingMessage.overviewTitle
        case .recording: return UserFacingMessage.recordingTitle
        case .transcription: return UserFacingMessage.transcriptionTitle
        case .history: return UserFacingMessage.historyTitle
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return UserFacingMessage.overviewSubtitle
        case .recording: return UserFacingMessage.recordingSubtitle
        case .transcription: return UserFacingMessage.transcriptionSubtitle
        case .history: return UserFacingMessage.historySubtitle
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .recording: return "mic"
        case .transcription: return "waveform.and.magnifyingglass"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var showDiagnostics = false
    @State private var copiedTranscriptID: UUID?
    @State private var selectedPage: SettingsPage = .overview

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(PloegTheme.line).frame(width: 1)
            detailView
        }
        .foregroundStyle(PloegTheme.ink)
        .tint(PloegTheme.accent)
        .onAppear {
            guard !coordinator.isDesignPreview else { return }
            coordinator.refreshInputDevices()
            coordinator.refreshPermissions()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 12) {
                PloegAppIcon(.voice, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(UserFacingMessage.appName)
                        .font(.system(size: 19, weight: .semibold))
                    Text(UserFacingMessage.settingsTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(PloegTheme.muted)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            VStack(spacing: 6) {
                ForEach(SettingsPage.allCases) { page in
                    Button {
                        selectedPage = page
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: page.systemImage)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 20)
                            Text(page.title)
                                .font(.system(size: 13, weight: selectedPage == page ? .semibold : .medium))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(selectedPage == page ? PloegTheme.accent : PloegTheme.muted)
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(selectedPage == page ? PloegTheme.accentSoft : .clear,
                                    in: RoundedRectangle(cornerRadius: PloegTheme.controlRadius))
                        .contentShape(RoundedRectangle(cornerRadius: PloegTheme.controlRadius))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedPage == page ? .isSelected : [])
                }
            }
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 6) {
                Label(UserFacingMessage.onThisMac, systemImage: "desktopcomputer")
                    .font(.system(size: 12, weight: .medium))
                Text(UserFacingMessage.localProcessing)
                    .font(.system(size: 11))
            }
            .foregroundStyle(PloegTheme.muted)
            .padding(8)
        }
        .padding(16)
        .frame(width: PloegTheme.sidebarWidth)
        .background(PloegTheme.sidebar)
    }

    private var detailView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHero
                Group {
                    switch selectedPage {
                    case .overview: overviewPage
                    case .recording: recordingPage
                    case .transcription: transcriptionPage
                    case .history: historyPage
                    }
                }
                .font(.system(size: 13))
                .disabled(coordinator.isDesignPreview)
            }
            .padding(PloegTheme.pagePadding)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(PloegTheme.canvas)
    }

    private var pageHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                PloegSectionHeader(selectedPage.title, subtitle: selectedPage.subtitle)
                Spacer(minLength: 0)
                PloegStatusPill(VoiceInterface.title(for: coordinator),
                                systemImage: VoiceInterface.symbol(for: coordinator),
                                color: VoiceInterface.color(for: coordinator))
            }
            if case let .error(message) = coordinator.state {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(PloegTheme.warning)
            }
        }
    }

    private var overviewPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            permissionsCard
            quickRuntimeCard
        }
    }

    private var recordingPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            liveDictationCard
            inputCard
            hotkeyCard
        }
    }

    private var transcriptionPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            liveDictationCard
            languageCard
            languageModelsCard
            speechModelCard
            if coordinator.settings.selectedTranscriptionBackend == .whisperCpp {
                whisperCard
            } else if coordinator.settings.selectedTranscriptionBackend == .bark {
                barkRuntimeCard
            } else {
                crisperRuntimeCard
            }
        }
    }

    private var historyPage: some View {
        historyCard
    }

    private var quickRuntimeCard: some View {
        SettingsCard(title: UserFacingMessage.runtimeTitle, systemImage: "gauge.with.dots.needle.bottom.50percent") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent(UserFacingMessage.engineTitle, value: coordinator.selectedModel()?.backend.displayName ?? UserFacingMessage.noModelSelected)
                    .font(.callout)
                    .foregroundStyle(PloegTheme.muted)
                LabeledContent(UserFacingMessage.selectedModelTitle, value: coordinator.selectedModel()?.displayName ?? UserFacingMessage.noModelSelected)
                    .font(.callout)
                    .foregroundStyle(PloegTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                LabeledContent(UserFacingMessage.preparationTiming,
                    value: String(format: "%.2f s", coordinator.lastTimings.preparation))
                LabeledContent(UserFacingMessage.transcriptionTiming,
                    value: String(format: "%.2f s", coordinator.lastTimings.transcription))
                LabeledContent(UserFacingMessage.insertionTiming,
                    value: String(format: "%.2f s", coordinator.lastTimings.insertion))

                if !coordinator.lastTranscript.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(UserFacingMessage.lastTranscriptTitle)
                            .font(.caption)
                            .foregroundStyle(PloegTheme.muted)
                        Text(coordinator.lastTranscript)
                            .font(.callout)
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                    }
                } else {
                    Text(UserFacingMessage.noSessionTranscript)
                        .font(.caption)
                        .foregroundStyle(PloegTheme.muted)
                }
            }
        }
    }

    private var permissionsCard: some View {
        SettingsCard(title: UserFacingMessage.permissionsTitle, systemImage: "lock.shield.fill") {
            VStack(alignment: .leading, spacing: 10) {
                PermissionRow(title: UserFacingMessage.microphoneTitle, granted: coordinator.permissionStatus.microphoneGranted)
                PermissionRow(title: UserFacingMessage.accessibilityTitle, granted: coordinator.permissionStatus.accessibilityGranted)

                if !coordinator.permissionStatus.microphoneGranted {
                    Button(UserFacingMessage.openMicrophoneSettings) {
                        coordinator.openMicrophoneSettings()
                    }
                }

                HStack {
                    Button(UserFacingMessage.requestAccessibility) {
                        coordinator.requestAccessibilityPermission()
                    }

                    Button(UserFacingMessage.openAccessibilitySettings) {
                        coordinator.openAccessibilitySettings()
                    }
                    .buttonStyle(PloegSecondaryButtonStyle())

                    Button(UserFacingMessage.refreshStatus) {
                        coordinator.refreshPermissions()
                    }
                    .buttonStyle(PloegSecondaryButtonStyle())
                }

                if !coordinator.permissionStatus.accessibilityGranted {
                    Text(UserFacingMessage.accessibilityRequired)
                        .font(.caption)
                        .foregroundStyle(PloegTheme.warning)
                }

                DisclosureGroup(isExpanded: $showDiagnostics) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Legacy trusted: \(coordinator.accessibilityDiagnostics.trustedLegacy ? "yes" : "no")")
                        Text("Options trusted: \(coordinator.accessibilityDiagnostics.trustedWithOptionsNoPrompt ? "yes" : "no")")
                        Text("Bundle ID: \(coordinator.accessibilityDiagnostics.bundleID)")
                        Text("Bundle path: \(coordinator.accessibilityDiagnostics.bundlePath)")
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text("Executable: \(coordinator.accessibilityDiagnostics.executablePath)")
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(PloegTheme.muted)
                    .textSelection(.enabled)
                } label: {
                    Text(UserFacingMessage.troubleshootingTitle)
                        .font(.caption)
                        .foregroundStyle(PloegTheme.muted)
                }
            }
        }
    }

    private var inputCard: some View {
        SettingsCard(title: UserFacingMessage.inputTitle, systemImage: "mic.fill.badge.plus") {
            VStack(alignment: .leading, spacing: 10) {
                Picker(UserFacingMessage.preferredInput, selection: $coordinator.settings.preferredInputDeviceUID) {
                    Text(UserFacingMessage.systemDefaultInput).tag(nil as String?)
                    ForEach(coordinator.availableInputDevices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Toggle("Block recording on Bluetooth/HFP input", isOn: $coordinator.settings.warnOnBluetoothInput)
                    .toggleStyle(.checkbox)

                Text("When enabled, recording is stopped before start if the effective input device is Bluetooth/HFP.")
                    .font(.caption)
                    .foregroundStyle(PloegTheme.muted)

                HStack {
                    Text(UserFacingMessage.currentInputTitle)
                        .foregroundStyle(PloegTheme.muted)
                    Spacer()
                    Text(coordinator.currentDefaultInputDeviceName())
                        .fontWeight(.medium)
                }

                if coordinator.shouldShowBluetoothInputWarning() {
                    Label("Effective recording input is Bluetooth, which can switch headphones to call mode.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(PloegTheme.warning)
                }

                if coordinator.settings.preferredInputDeviceUID != nil, coordinator.preferredInputDevice() == nil {
                    Text("Preferred input device is not currently available.")
                        .font(.caption)
                        .foregroundStyle(PloegTheme.danger)
                }

                Button(UserFacingMessage.refreshInputs) {
                    coordinator.refreshInputDevices()
                }
                .buttonStyle(PloegSecondaryButtonStyle())
            }
        }
    }

    private var speechModelCard: some View {
        SettingsCard(title: UserFacingMessage.modelDownloadsTitle, systemImage: "cpu.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text(UserFacingMessage.modelDownloadsDescription)
                    .font(.caption)
                    .foregroundStyle(PloegTheme.muted)
                ModelPickerView(coordinator: coordinator)

                if coordinator.isDownloadingModel {
                    ProgressView("Downloading model...")
                }
            }
        }
    }

    private var languageModelsCard: some View {
        SettingsCard(title: UserFacingMessage.languageModelsTitle, systemImage: "globe") {
            LanguageModelAssignmentsView(coordinator: coordinator)
        }
    }

    private var languageCard: some View {
        SettingsCard(title: UserFacingMessage.activeLanguage, systemImage: "globe") {
            VStack(alignment: .leading, spacing: 10) {
                Picker(UserFacingMessage.transcriptionLanguage, selection: $coordinator.settings.selectedLanguage) {
                    Text(UserFacingMessage.automaticLanguage).tag("auto")
                    Text(UserFacingMessage.englishModel).tag("en")
                    Text(UserFacingMessage.dutchModel).tag("nl")
                    Text(UserFacingMessage.germanLanguage).tag("de")
                    Text(UserFacingMessage.frenchLanguage).tag("fr")
                    Text(UserFacingMessage.spanishLanguage).tag("es")
                }
                .labelsHidden()
                .pickerStyle(.menu)

                if let model = coordinator.selectedModel() {
                    LabeledContent(UserFacingMessage.activeModel, value: model.displayName)
                        .font(.caption)
                    Text(coordinator.selectedModelReadinessMessage)
                        .font(.caption)
                        .foregroundStyle(coordinator.canUseSelectedBackend() ? PloegTheme.muted : PloegTheme.warning)
                    if let message = coordinator.preparationError {
                        Text(message).font(.caption).foregroundStyle(PloegTheme.warning)
                    }
                }

                if let model = coordinator.selectedModel(),
                   coordinator.settings.selectedLanguage != "auto",
                   !model.supports(language: coordinator.settings.selectedLanguage) {
                    Label(UserFacingMessage.modelLanguageMismatch, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(PloegTheme.warning)
                }

                if coordinator.selectedModel()?.backend == .crisperWhisper,
                   coordinator.settings.selectedLanguage == "auto" {
                    Label(UserFacingMessage.crisperRequiresExplicitLanguage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(PloegTheme.warning)
                }
            }
        }
    }

    private var hotkeyCard: some View {
        SettingsCard(title: UserFacingMessage.shortcutTitle, systemImage: "keyboard.fill") {
            VStack(alignment: .leading, spacing: 10) {
                HotkeyRecorderView(hotkey: Binding(
                    get: { coordinator.settings.hotkey },
                    set: { coordinator.changeHotkey($0) }
                ))
                .disabled(coordinator.state.isDictationActive)
                if let message = coordinator.configurationError {
                    Text(message).font(.caption).foregroundStyle(PloegTheme.warning)
                }
                Text(UserFacingMessage.dictationHotkeyHelp)
                    .font(.caption)
                    .foregroundStyle(PloegTheme.muted)
            }
        }
    }

    private var liveDictationCard: some View {
        SettingsCard(title: UserFacingMessage.liveDictationTitle, systemImage: "text.cursor") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(UserFacingMessage.liveDictationToggle, isOn: $coordinator.settings.liveDictationEnabled)
                    .toggleStyle(.switch)
                    .disabled(coordinator.state.isDictationActive)
                Text(UserFacingMessage.liveDictationDescription)
                    .font(.callout)
                Text(UserFacingMessage.liveDictationHelp)
                    .font(.caption)
                    .foregroundStyle(PloegTheme.muted)
                Text(UserFacingMessage.liveDictationLatency)
                    .font(.caption)
                    .foregroundStyle(PloegTheme.muted)
            }
        }
    }

    private var whisperCard: some View {
        SettingsCard(title: "whisper.cpp", systemImage: "terminal") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Path to whisper-cli", text: $coordinator.settings.whisperCLIPath)
                    .textFieldStyle(.roundedBorder)
                Text("Auto-detect checks configured path, project Vendor build, and common Homebrew paths.")
                    .font(.caption)
                    .foregroundStyle(PloegTheme.muted)
            }
        }
    }

    private var barkRuntimeCard: some View {
        SettingsCard(title: UserFacingMessage.barkRuntimeTitle, systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 10) {
                Text(coordinator.barkRuntimeStatus.title)
                Text(UserFacingMessage.barkRuntimeDescription)
                    .font(.caption)
                    .foregroundStyle(PloegTheme.muted)
                Text(UserFacingMessage.barkAttribution)
                    .font(.caption)
                Link(UserFacingMessage.barkModelCard,
                     destination: barkModelCardURL)
                switch coordinator.barkRuntimeStatus {
                case .notInstalled, .failed:
                    Button(UserFacingMessage.barkInstallRuntime) {
                        Task { await coordinator.installBarkRuntime() }
                    }
                    .disabled(!coordinator.canManageModels)
                case .installing:
                    ProgressView(UserFacingMessage.barkInstallingRuntime)
                case .ready:
                    Button(UserFacingMessage.barkRemoveRuntime, role: .destructive) {
                        Task { await coordinator.removeBarkRuntime() }
                    }
                    .disabled(!coordinator.canManageModels)
                case .incompatibleHardware:
                    Text(UserFacingMessage.barkIncompatibleHardware)
                        .font(.caption)
                }
            }
        }
    }

    private var barkModelCardURL: URL {
        if let model = coordinator.modelToManage(), model.backend == .bark,
           case let .huggingFaceSnapshot(repository, _) = model.acquisition,
           let url = URL(string: "https://huggingface.co/\(repository)") {
            return url
        }
        return URL(string: "https://huggingface.co/ConwayResearch/Underdog-Bark-3.0")!
    }

    private var crisperRuntimeCard: some View {
        SettingsCard(title: "Local CrisperWhisper Runtime", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Runtime", value: coordinator.crisperRuntimeStatus.title)

                Text("Inference runs entirely on this Mac. Internet is used only to install the runtime and selected model; transcription forces Hugging Face and Transformers offline mode.")
                    .font(.caption)
                    .foregroundStyle(PloegTheme.muted)

                if coordinator.settings.acceptedCrisperLicenseVersion != ReleaseConfig.crisperLicenseVersion {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The standard CrisperWhisper 2.0 weights use the Nyra Health Non-Commercial Research License. Commercial use requires a separate license.")
                            .font(.caption)
                            .foregroundStyle(PloegTheme.warning)
                        HStack {
                            Link(
                                "Read Model License",
                                destination: URL(string: "https://huggingface.co/nyralabs/CrisperWhisper2.0_large")!
                            )
                            Button("Accept for Non-Commercial Use") {
                                coordinator.acceptCrisperLicense()
                            }
                            .buttonStyle(PloegPrimaryButtonStyle())
                        }
                    }
                } else {
                    Label("Non-commercial model license accepted", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(PloegTheme.success)
                }

                HStack {
                    switch coordinator.crisperRuntimeStatus {
                    case .notInstalled, .failed:
                        Button("Install Runtime") {
                            Task { await coordinator.installCrisperRuntime() }
                        }
                        .disabled(!coordinator.canManageModels)
                    case .installing:
                        ProgressView("Installing Python, PyTorch, and CrisperWhisper…")
                    case .ready:
                        Button("Repair Runtime") {
                            Task { await coordinator.installCrisperRuntime() }
                        }
                        .disabled(!coordinator.canManageModels)
                        Button("Remove Runtime", role: .destructive) {
                            Task { await coordinator.removeCrisperRuntime() }
                        }
                        .disabled(!coordinator.canManageModels)
                    case .incompatibleHardware:
                        Text("Use whisper.cpp on this Mac.")
                            .font(.caption)
                            .foregroundStyle(PloegTheme.muted)
                    }
                }
            }
        }
    }

    private var historyCard: some View {
        SettingsCard(title: UserFacingMessage.historyTitle, systemImage: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                Picker(UserFacingMessage.historyDays, selection: $coordinator.settings.transcriptRetention) {
                    ForEach(TranscriptRetention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                }
                HStack {
                    Label(UserFacingMessage.savedTranscriptCount(coordinator.settings.transcriptHistory.count), systemImage: "text.bubble")
                        .font(.caption)
                        .foregroundStyle(PloegTheme.muted)
                    Spacer()
                    Button(UserFacingMessage.clearTranscripts) {
                        coordinator.clearTranscriptHistory()
                        copiedTranscriptID = nil
                    }
                    .buttonStyle(PloegSecondaryButtonStyle())
                    .disabled(coordinator.settings.transcriptHistory.isEmpty)
                }

                if coordinator.settings.transcriptHistory.isEmpty {
                    ContentUnavailableView(
                        UserFacingMessage.noTranscriptsTitle,
                        systemImage: "waveform.and.magnifyingglass",
                        description: Text(UserFacingMessage.noTranscriptsDescription)
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(coordinator.settings.transcriptHistory) { item in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        Label(timestampText(for: item.createdAt), systemImage: "clock")
                                            .font(.caption)
                                            .foregroundStyle(PloegTheme.muted)
                                        Spacer()
                                        Button(UserFacingMessage.deleteTranscript, role: .destructive) {
                                            coordinator.settings.removeTranscript(id: item.id)
                                        }
                                        .controlSize(.small)
                                        Button(copiedTranscriptID == item.id ? UserFacingMessage.copiedStatus : UserFacingMessage.copyAction) {
                                            coordinator.copyTranscriptToClipboard(item.text)
                                            copiedTranscriptID = item.id
                                            Task { @MainActor in
                                                try? await Task.sleep(nanoseconds: 1_200_000_000)
                                                if copiedTranscriptID == item.id {
                                                    copiedTranscriptID = nil
                                                }
                                            }
                                        }
                                        .buttonStyle(PloegPrimaryButtonStyle())
                                        .controlSize(.small)
                                    }

                                    Text(item.text)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .lineLimit(5)
                                        .truncationMode(.tail)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(PloegTheme.canvas)
                                )
                            }
                        }
                    }
                    .frame(minHeight: 240, maxHeight: 420)
                }
            }
        }
    }

    private func timestampText(for date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        PloegCard(title: title, systemImage: systemImage) {
            content
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: title == UserFacingMessage.microphoneTitle ? "mic" : "accessibility")
                .font(.system(size: 18))
                .foregroundStyle(PloegTheme.muted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PloegTheme.ink)
                Text(title == UserFacingMessage.microphoneTitle
                     ? UserFacingMessage.microphonePurpose : UserFacingMessage.accessibilityPurpose)
                    .font(.system(size: 12))
                    .foregroundStyle(PloegTheme.muted)
            }
            Spacer()
            PloegStatusPill(granted ? UserFacingMessage.allowedStatus : UserFacingMessage.permissionNeededStatus,
                            systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                            color: granted ? PloegTheme.success : PloegTheme.warning)
        }
        .padding(.vertical, 6)
    }
}
