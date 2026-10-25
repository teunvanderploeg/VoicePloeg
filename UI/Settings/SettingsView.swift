import SwiftUI

private enum SettingsPage: String, CaseIterable, Identifiable {
    case overview
    case recording
    case transcription
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .recording:
            return "Recording"
        case .transcription:
            return "Transcription"
        case .history:
            return "History"
        }
    }

    var subtitle: String {
        switch self {
        case .overview:
            return "Permissions and runtime"
        case .recording:
            return "Input and hotkey"
        case .transcription:
            return "Model, language, runtime"
        case .history:
            return "Recent dictations"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            return "square.grid.2x2"
        case .recording:
            return "mic"
        case .transcription:
            return "waveform.and.magnifyingglass"
        case .history:
            return "clock.arrow.circlepath"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var showDiagnostics = false
    @State private var copiedTranscriptID: UUID?
    @State private var selectedPage: SettingsPage? = .overview

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            coordinator.refreshInputDevices()
            coordinator.refreshPermissions()
        }
    }

    private var sidebar: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            List(SettingsPage.allCases, selection: $selectedPage) { page in
                HStack(spacing: 10) {
                    Image(systemName: page.systemImage)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(selectedPage == page ? .white : .primary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(page.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text(page.subtitle)
                            .font(.caption2)
                            .foregroundStyle(selectedPage == page ? .white.opacity(0.85) : .secondary)
                    }
                }
                .padding(.vertical, 6)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selectedPage == page ? Color.accentColor : Color.clear)
                        .padding(.vertical, 2)
                )
                .foregroundStyle(selectedPage == page ? .white : .primary)
                .tag(page)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VoicePloeg")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .background(.ultraThinMaterial)
            }
        }
        .frame(minWidth: 250)
    }

    private var detailView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    pageHero

                    switch selectedPage ?? .overview {
                    case .overview:
                        overviewPage
                    case .recording:
                        recordingPage
                    case .transcription:
                        transcriptionPage
                    case .history:
                        historyPage
                    }
                }
                .padding(20)
            }
        }
    }

    private var pageHero: some View {
        let page = selectedPage ?? .overview

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: page.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(page.title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(page.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    StatusBadge(
                        title: coordinator.permissionStatus.microphoneGranted ? "Mic Allowed" : "Mic Missing",
                        isGood: coordinator.permissionStatus.microphoneGranted
                    )
                    StatusBadge(
                        title: coordinator.permissionStatus.accessibilityGranted ? "AX Allowed" : "AX Missing",
                        isGood: coordinator.permissionStatus.accessibilityGranted
                    )
                }
            }

            HStack(spacing: 14) {
                LabeledContent("State", value: coordinator.state.title)
                Divider()
                    .frame(height: 16)
                LabeledContent("History", value: "\(coordinator.settings.transcriptHistory.count)")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
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
        SettingsCard(title: "Runtime", systemImage: "gauge.with.dots.needle.bottom.50percent") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Backend", value: coordinator.selectedModel()?.backend.displayName ?? "Not selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Selected Model", value: coordinator.selectedModel()?.displayName ?? "Not selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                        Text("Latest Transcript")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(coordinator.lastTranscript)
                            .font(.callout)
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("No transcription yet in this session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var permissionsCard: some View {
        SettingsCard(title: "Permissions", systemImage: "lock.shield.fill") {
            VStack(alignment: .leading, spacing: 10) {
                PermissionRow(title: "Microphone", granted: coordinator.permissionStatus.microphoneGranted)
                PermissionRow(title: "Accessibility", granted: coordinator.permissionStatus.accessibilityGranted)

                if !coordinator.permissionStatus.microphoneGranted {
                    Button(UserFacingMessage.openMicrophoneSettings) {
                        coordinator.openMicrophoneSettings()
                    }
                }

                HStack {
                    Button("Request Accessibility Permission") {
                        coordinator.requestAccessibilityPermission()
                    }

                    Button("Open Accessibility Settings") {
                        coordinator.openAccessibilitySettings()
                    }
                    .buttonStyle(.bordered)

                    Button("Refresh") {
                        coordinator.refreshPermissions()
                    }
                    .buttonStyle(.bordered)
                }

                if !coordinator.permissionStatus.accessibilityGranted {
                    Text("Accessibility is required to insert text into other apps.")
                        .font(.caption)
                        .foregroundStyle(.orange)
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                } label: {
                    Text("Troubleshooting Details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var inputCard: some View {
        SettingsCard(title: "Input Device", systemImage: "mic.fill.badge.plus") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Preferred Recording Input", selection: $coordinator.settings.preferredInputDeviceUID) {
                    Text("System Default").tag(nil as String?)
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
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Current System Input")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(coordinator.currentDefaultInputDeviceName())
                        .fontWeight(.medium)
                }

                if coordinator.shouldShowBluetoothInputWarning() {
                    Label("Effective recording input is Bluetooth, which can switch headphones to call mode.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if coordinator.settings.preferredInputDeviceUID != nil, coordinator.preferredInputDevice() == nil {
                    Text("Preferred input device is not currently available.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Refresh Input Devices") {
                    coordinator.refreshInputDevices()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var speechModelCard: some View {
        SettingsCard(title: UserFacingMessage.modelDownloadsTitle, systemImage: "cpu.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text(UserFacingMessage.modelDownloadsDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        SettingsCard(title: "Language", systemImage: "globe") {
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
                        .foregroundStyle(coordinator.canUseSelectedBackend() ? Color.secondary : Color.orange)
                    if let message = coordinator.preparationError {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                }

                if let model = coordinator.selectedModel(),
                   coordinator.settings.selectedLanguage != "auto",
                   !model.supports(language: coordinator.settings.selectedLanguage) {
                    Label(UserFacingMessage.modelLanguageMismatch, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if coordinator.selectedModel()?.backend == .crisperWhisper,
                   coordinator.settings.selectedLanguage == "auto" {
                    Label(UserFacingMessage.crisperRequiresExplicitLanguage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var hotkeyCard: some View {
        SettingsCard(title: "Hotkey", systemImage: "keyboard.fill") {
            VStack(alignment: .leading, spacing: 10) {
                HotkeyRecorderView(hotkey: Binding(
                    get: { coordinator.settings.hotkey },
                    set: { coordinator.changeHotkey($0) }
                ))
                .disabled(coordinator.state.isDictationActive)
                if let message = coordinator.configurationError {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                Text(UserFacingMessage.dictationHotkeyHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                Text(UserFacingMessage.liveDictationLatency)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var barkRuntimeCard: some View {
        SettingsCard(title: UserFacingMessage.barkRuntimeTitle, systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 10) {
                Text(coordinator.barkRuntimeStatus.title)
                Text(UserFacingMessage.barkRuntimeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)

                if coordinator.settings.acceptedCrisperLicenseVersion != ReleaseConfig.crisperLicenseVersion {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The standard CrisperWhisper 2.0 weights use the Nyra Health Non-Commercial Research License. Commercial use requires a separate license.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        HStack {
                            Link(
                                "Read Model License",
                                destination: URL(string: "https://huggingface.co/nyralabs/CrisperWhisper2.0_large")!
                            )
                            Button("Accept for Non-Commercial Use") {
                                coordinator.acceptCrisperLicense()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    Label("Non-commercial model license accepted", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
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
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var historyCard: some View {
        SettingsCard(title: "History", systemImage: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                Picker(UserFacingMessage.historyDays, selection: $coordinator.settings.transcriptRetention) {
                    ForEach(TranscriptRetention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                }
                HStack {
                    Label("\(coordinator.settings.transcriptHistory.count) saved", systemImage: "text.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(UserFacingMessage.clearTranscripts) {
                        coordinator.clearTranscriptHistory()
                        copiedTranscriptID = nil
                    }
                    .buttonStyle(.bordered)
                    .disabled(coordinator.settings.transcriptHistory.isEmpty)
                }

                if coordinator.settings.transcriptHistory.isEmpty {
                    ContentUnavailableView(
                        "No transcripts yet",
                        systemImage: "waveform.and.magnifyingglass",
                        description: Text("Your latest transcriptions will show up here.")
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
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Button(UserFacingMessage.deleteTranscript, role: .destructive) {
                                            coordinator.settings.removeTranscript(id: item.id)
                                        }
                                        .controlSize(.small)
                                        Button(copiedTranscriptID == item.id ? "Copied" : "Copy") {
                                            coordinator.copyTranscriptToClipboard(item.text)
                                            copiedTranscriptID = item.id
                                            Task { @MainActor in
                                                try? await Task.sleep(nanoseconds: 1_200_000_000)
                                                if copiedTranscriptID == item.id {
                                                    copiedTranscriptID = nil
                                                }
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
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
                                        .fill(Color.primary.opacity(0.04))
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
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool

    var body: some View {
        HStack {
            Label(
                title,
                systemImage: granted ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .foregroundStyle(granted ? .green : .red)

            Spacer()

            Text(granted ? "Allowed" : "Missing")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StatusBadge: View {
    let title: String
    let isGood: Bool

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill((isGood ? Color.green : Color.red).opacity(0.16))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke((isGood ? Color.green : Color.red).opacity(0.45), lineWidth: 1)
            )
    }
}
