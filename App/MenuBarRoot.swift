import PloegKit
import SwiftUI

struct MenuBarRoot: View {
    @ObservedObject var coordinator: AppCoordinator
    let onOpenSettings: () -> Void
    private let maxTranscriptPreviewCharacters = 90

    init(coordinator: AppCoordinator, onOpenSettings: @escaping () -> Void = {}) {
        self.coordinator = coordinator
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                PloegAppIcon(.voice, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(UserFacingMessage.appName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(PloegTheme.ink)
                    Label(VoiceInterface.title(for: coordinator), systemImage: VoiceInterface.symbol(for: coordinator))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VoiceInterface.color(for: coordinator))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Rectangle().fill(PloegTheme.line).frame(height: 1)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(UserFacingMessage.activeLanguage).foregroundStyle(PloegTheme.muted)
                    Spacer()
                    Button(languageLabel) { coordinator.cycleLanguage() }
                        .buttonStyle(.plain)
                        .foregroundStyle(PloegTheme.accent)
                        .keyboardShortcut("l", modifiers: [.control, .option])
                        .accessibilityLabel(UserFacingMessage.activeLanguage)
                        .accessibilityValue(languageLabel)
                }
                if let model = coordinator.selectedModel() {
                    HStack(alignment: .top) {
                        Text(UserFacingMessage.localModelLabel).foregroundStyle(PloegTheme.muted)
                        Spacer(minLength: 14)
                        Text(model.displayName)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: coordinator.settings.liveDictationEnabled ? "text.cursor" : "waveform")
                    Text(coordinator.settings.liveDictationEnabled ? UserFacingMessage.liveMode : UserFacingMessage.afterStopMode)
                }
                .font(.system(size: 12))
                .foregroundStyle(PloegTheme.muted)
            }
            .font(.system(size: 13))
            .foregroundStyle(PloegTheme.ink)

            Button {
                Task { await coordinator.toggleRecording() }
            } label: {
                Label(buttonTitle, systemImage: coordinator.state.isDictationActive ? "stop.fill" : "mic.fill")
            }
            .buttonStyle(VoiceRecordButtonStyle(isRecording: isListening))
            .disabled(coordinator.state == .starting || coordinator.state == .processing
                || coordinator.isDownloadingModel || coordinator.isInstallingCrisperRuntime
                || coordinator.isInstallingBarkRuntime)

            if case let .listening(startedAt) = coordinator.state {
                HStack(alignment: .top) {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(UserFacingMessage.recordingElapsed(Int(context.date.timeIntervalSince(startedAt))))
                            .monospacedDigit()
                            .foregroundStyle(PloegTheme.recording)
                    }
                    Spacer()
                    Text(UserFacingMessage.recordingLimit)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(PloegTheme.muted)
                }
                .font(.system(size: 12))
            } else {
                Text(coordinator.settings.hotkey.displayText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(PloegTheme.muted)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(UserFacingMessage.shortcutTitle)
            }

            if coordinator.isLiveDictating {
                PloegCard(padding: 12) {
                    Label(UserFacingMessage.liveTranscriptTitle, systemImage: "text.cursor")
                        .font(.system(size: 12, weight: .semibold))
                    if let message = coordinator.liveOutputMessage {
                        Text(message).foregroundStyle(PloegTheme.warning)
                    } else if coordinator.liveTranscript.isEmpty {
                        Text(UserFacingMessage.liveDictationListening).foregroundStyle(PloegTheme.muted)
                    }
                    if !coordinator.liveTranscript.isEmpty {
                        Text(String(coordinator.liveTranscript.suffix(220)))
                            .foregroundStyle(PloegTheme.ink)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                }
                .font(.system(size: 12))
            }

            if let message = coordinator.configurationError {
                notice(message)
            }
            if case let .error(message) = coordinator.state, message != coordinator.configurationError {
                notice(message)
            }

            if coordinator.hasRetainedRecording {
                PloegCard(padding: 12) {
                    Text(UserFacingMessage.recordingRetained)
                        .font(.system(size: 12))
                        .foregroundStyle(PloegTheme.muted)
                    Button(UserFacingMessage.retryTranscription) {
                        Task { await coordinator.retryTranscription() }
                    }
                    .buttonStyle(PloegSecondaryButtonStyle())
                    .disabled(!coordinator.canManageModels)
                    Button(UserFacingMessage.discardRecording, role: .destructive) {
                        coordinator.discardRetainedRecording()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PloegTheme.danger)
                    .disabled(coordinator.state.isDictationActive)
                }
            }

            if !coordinator.lastTranscript.isEmpty && !coordinator.isLiveDictating {
                PloegCard(padding: 12) {
                    HStack {
                        Text(UserFacingMessage.lastTranscriptTitle).foregroundStyle(PloegTheme.muted)
                        Spacer()
                        Button {
                            coordinator.copyTranscriptToClipboard(coordinator.lastTranscript)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PloegTheme.accent)
                        .help(UserFacingMessage.copyTranscript)
                        .accessibilityLabel(UserFacingMessage.copyTranscript)
                    }
                    .font(.system(size: 12))
                    Text(transcriptPreview)
                        .font(.system(size: 13))
                        .foregroundStyle(PloegTheme.ink)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            Rectangle().fill(PloegTheme.line).frame(height: 1)
            HStack {
                Button {
                    onOpenSettings()
                } label: {
                    Label(UserFacingMessage.settingsTitle, systemImage: "gearshape")
                }
                Spacer()
                Button(UserFacingMessage.quitApp) { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(PloegTheme.muted)
        }
        .padding(20)
        .frame(width: 320)
        .background(PloegTheme.surface)
        .tint(PloegTheme.accent)
    }

    private func notice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(PloegTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isListening: Bool {
        if case .listening = coordinator.state { return true }
        return false
    }

    private var buttonTitle: String {
        switch coordinator.state {
        case .idle, .error: return UserFacingMessage.startRecording
        case .starting: return UserFacingMessage.startingRecording
        case .listening: return coordinator.isLiveDictating ? UserFacingMessage.liveDictationStop : UserFacingMessage.stopAndTranscribe
        case .processing: return UserFacingMessage.processingStatus
        }
    }

    private var languageLabel: String {
        switch coordinator.settings.selectedLanguage {
        case "en": return UserFacingMessage.englishModel
        case "nl": return UserFacingMessage.dutchModel
        case "de": return UserFacingMessage.germanLanguage
        case "fr": return UserFacingMessage.frenchLanguage
        case "es": return UserFacingMessage.spanishLanguage
        default: return UserFacingMessage.automaticLanguage
        }
    }

    private var transcriptPreview: String {
        let trimmed = coordinator.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxTranscriptPreviewCharacters else { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: maxTranscriptPreviewCharacters)
        return "\(trimmed[..<endIndex])…"
    }
}
