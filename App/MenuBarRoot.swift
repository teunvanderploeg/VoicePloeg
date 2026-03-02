import SwiftUI

struct MenuBarRoot: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow
    private let maxTranscriptPreviewCharacters = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(colorForState(coordinator.state))
                    .frame(width: 10, height: 10)
                Text(coordinator.state.title)
                    .font(.headline)
            }

            Button(action: {
                Task { await coordinator.toggleRecording() }
            }) {
                Text(buttonTitle)
            }
            .keyboardShortcut(.space, modifiers: [.control, .option])

            if !coordinator.lastTranscript.isEmpty {
                Text("Last transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(transcriptPreview)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            Button(action: {
                coordinator.cycleLanguage()
            }) {
                Text("Language: \(languageLabel)")
            }
            .keyboardShortcut("l", modifiers: [.control, .option])

            Divider()

            Button("Settings") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private var buttonTitle: String {
        switch coordinator.state {
        case .idle, .error:
            return "Start Recording"
        case .listening:
            return "Stop & Transcribe"
        case .processing:
            return "Processing..."
        }
    }

    private func colorForState(_ state: AppState) -> Color {
        switch state {
        case .idle:
            return .gray
        case .listening:
            return .red
        case .processing:
            return .orange
        case .error:
            return .yellow
        }
    }

    private var languageLabel: String {
        switch coordinator.settings.selectedLanguage {
        case "en": return "English"
        case "nl": return "Dutch"
        default:   return "Auto"
        }
    }

    private var transcriptPreview: String {
        let trimmed = coordinator.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxTranscriptPreviewCharacters else {
            return trimmed
        }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: maxTranscriptPreviewCharacters)
        return "\(trimmed[..<endIndex])..."
    }
}
