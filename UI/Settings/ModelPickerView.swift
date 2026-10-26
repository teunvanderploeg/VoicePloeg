import SwiftUI
import PloegKit

struct ModelPickerView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var isConfirmingRemoval = false

    var body: some View {
        Picker(UserFacingMessage.engineTitle, selection: $coordinator.settings.selectedTranscriptionBackend) {
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
            Button(UserFacingMessage.downloadModel) {
                Task { await coordinator.downloadSelectedModel() }
            }
            .buttonStyle(PloegPrimaryButtonStyle())
            .disabled(!coordinator.canManageModels || !canDownloadSelectedModel)

            if let selected = coordinator.modelToManage() {
                let isDownloaded = coordinator.modelManager.isDownloaded(selected)
                Text(isDownloaded ? UserFacingMessage.downloadedStatus : UserFacingMessage.notDownloadedStatus)
                    .foregroundStyle(isDownloaded ? PloegTheme.success : PloegTheme.muted)
                    .font(.caption)
                if isDownloaded {
                    Button(UserFacingMessage.removeModel, role: .destructive) {
                        isConfirmingRemoval = true
                    }
                    .buttonStyle(PloegSecondaryButtonStyle())
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
        if coordinator.settings.selectedTranscriptionBackend == .bark {
            if case .ready = coordinator.barkRuntimeStatus { return true }
            return false
        }
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
