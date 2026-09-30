import SwiftUI

struct ModelPickerView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var isConfirmingRemoval = false

    var body: some View {
        Picker("Backend", selection: $coordinator.settings.selectedTranscriptionBackend) {
            ForEach(SpeechBackend.allCases) { backend in
                Text(backend.displayName).tag(backend)
            }
        }
        .pickerStyle(.segmented)

        Picker("Model", selection: selectedModelBinding) {
            ForEach(availableModels) { model in
                Text(modelRowTitle(for: model)).tag(model.id)
            }
        }

        HStack {
            Button("Download / Activate") {
                Task { await coordinator.downloadSelectedModel() }
            }
            .disabled(!coordinator.canManageModels || !canDownloadSelectedModel)

            if let selected = coordinator.selectedModel() {
                let isDownloaded = coordinator.modelManager.isDownloaded(selected)
                Text(isDownloaded ? "Downloaded locally" : "Not downloaded")
                    .foregroundStyle(isDownloaded ? .green : .secondary)
                    .font(.caption)
                if isDownloaded {
                    Button("Remove", role: .destructive) {
                        isConfirmingRemoval = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(!coordinator.canManageModels)
                }
            }
        }
        .confirmationDialog(
            "Remove the selected local model?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Model", role: .destructive) {
                Task { await coordinator.removeSelectedModel() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can download it again later.")
        }
    }

    private var availableModels: [SpeechModelDescriptor] {
        coordinator.modelManager.models(for: coordinator.settings.selectedTranscriptionBackend)
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { coordinator.settings.selectedModelID },
            set: { coordinator.settings.selectedModelID = $0 }
        )
    }

    private var canDownloadSelectedModel: Bool {
        guard coordinator.settings.selectedTranscriptionBackend == .crisperWhisper else { return true }
        guard coordinator.settings.acceptedCrisperLicenseVersion == ReleaseConfig.crisperLicenseVersion else {
            return false
        }
        if case .ready = coordinator.crisperRuntimeStatus { return true }
        return false
    }

    private func modelRowTitle(for model: SpeechModelDescriptor) -> String {
        let isDownloaded = coordinator.modelManager.isDownloaded(model)
        let statusPrefix = isDownloaded ? "✓" : "○"
        return "\(statusPrefix) \(model.displayName) • \(model.formattedSize) • \(model.precision)"
    }
}
