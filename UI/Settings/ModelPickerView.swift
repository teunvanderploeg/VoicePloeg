import SwiftUI

struct ModelPickerView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Picker("Model", selection: $coordinator.settings.selectedModelID) {
            ForEach(coordinator.modelManager.catalog) { model in
                Text("\(model.displayName) (\(model.quantization))").tag(model.id)
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
}
