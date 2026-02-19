import SwiftUI

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var showDiagnostics = false
    @State private var copiedTranscriptID: UUID?

    var body: some View {
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
                VStack(alignment: .leading, spacing: 18) {
                    headerView

                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 340), spacing: 16)
                        ],
                        spacing: 16
                    ) {
                        permissionsCard
                        inputCard
                        speechModelCard
                        languageCard
                        hotkeyCard
                        whisperCard
                        historyCard
                    }
                }
                .padding(20)
            }
        }
        .onAppear {
            coordinator.refreshInputDevices()
            coordinator.refreshPermissions()
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Image(systemName: "waveform.and.mic")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("VoicePloeg Settings")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Offline dictation controls and runtime status")
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

            LabeledContent("State", value: coordinator.state.title)
                .font(.callout)
            LabeledContent("Active Model", value: coordinator.settings.activeModelPath ?? "Not downloaded")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var permissionsCard: some View {
        SettingsCard(title: "Permissions", systemImage: "lock.shield.fill") {
            VStack(alignment: .leading, spacing: 10) {
                PermissionRow(title: "Microphone", granted: coordinator.permissionStatus.microphoneGranted)
                PermissionRow(title: "Accessibility", granted: coordinator.permissionStatus.accessibilityGranted)

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
                Picker("Preferred Recording Input", selection: $coordinator.settings.preferredInputDeviceID) {
                    Text("System Default").tag(nil as UInt32?)
                    ForEach(coordinator.availableInputDevices) { device in
                        Text(device.name).tag(Optional(device.id))
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

                if coordinator.settings.preferredInputDeviceID != nil, coordinator.preferredInputDevice() == nil {
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
        SettingsCard(title: "Speech Model", systemImage: "cpu.fill") {
            VStack(alignment: .leading, spacing: 10) {
                ModelPickerView(coordinator: coordinator)

                if coordinator.isDownloadingModel {
                    ProgressView("Downloading model…")
                }
            }
        }
    }

    private var languageCard: some View {
        SettingsCard(title: "Language", systemImage: "globe") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Transcription Language", selection: $coordinator.settings.selectedLanguage) {
                    Text("Auto").tag("auto")
                    Text("English").tag("en")
                    Text("Dutch").tag("nl")
                    Text("German").tag("de")
                    Text("French").tag("fr")
                    Text("Spanish").tag("es")
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var hotkeyCard: some View {
        SettingsCard(title: "Hotkey", systemImage: "keyboard.fill") {
            VStack(alignment: .leading, spacing: 10) {
                HotkeyRecorderView(hotkey: $coordinator.settings.hotkey)
                Text("Press once to start recording, press again to stop and transcribe.")
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

    private var historyCard: some View {
        SettingsCard(title: "History", systemImage: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("\(coordinator.settings.transcriptHistory.count) saved", systemImage: "text.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History") {
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
                    .padding(.vertical, 8)
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
                                        .lineLimit(4)
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
                    .frame(minHeight: 220, maxHeight: 320)
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
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
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
