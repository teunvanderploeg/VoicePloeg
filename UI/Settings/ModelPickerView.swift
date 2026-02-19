import SwiftUI

struct ModelPickerView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Picker("Model", selection: $coordinator.settings.selectedModelID) {
            ForEach(coordinator.modelManager.catalog) { model in
                Text(modelRowTitle(for: model))
                    .tag(model.id)
            }
        }

        HStack {
            Button("Download / Activate") {
                Task {
                    await coordinator.downloadSelectedModel()
                }
            }
            .disabled(coordinator.isDownloadingModel)

            if let selected = coordinator.modelManager.catalog.first(where: { $0.id == coordinator.settings.selectedModelID }) {
                let isDownloaded = coordinator.modelManager.isDownloaded(selected)
                Text(isDownloaded ? "Downloaded" : "Not downloaded")
                    .foregroundStyle(isDownloaded ? .green : .secondary)
                    .font(.caption)
            }
        }
    }

    private func modelRowTitle(for model: ModelCatalogItem) -> String {
        let isDownloaded = coordinator.modelManager.isDownloaded(model)
        let statusPrefix = isDownloaded ? "✓" : "○"
        return "\(statusPrefix) \(model.displayName) • \(model.formattedSize) • \(model.quantization)"
    }
}
