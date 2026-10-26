import SwiftUI
import PloegKit

struct LanguageModelAssignmentsView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            languagePicker(UserFacingMessage.englishModel, language: "en", keyPath: \.englishDictationModelID)
            languagePicker(UserFacingMessage.dutchModel, language: "nl", keyPath: \.dutchDictationModelID)

            Picker(UserFacingMessage.automaticModel, selection: Binding(
                get: { coordinator.settings.automaticDictationModelID },
                set: {
                    coordinator.settings.automaticDictationModelID = $0
                    coordinator.selectModelForManagement(id: $0)
                }
            )) {
                ForEach(coordinator.modelManager.catalog.filter { $0.supports(language: "auto") }) { model in
                    Text(model.displayName).tag(model.id)
                }
            }

            Picker(UserFacingMessage.defaultModel, selection: defaultBinding) {
                ForEach(defaultModels) { model in
                    Text(model.displayName).tag(model.id)
                }
            }

            Text(UserFacingMessage.languageModelsDescription)
                .font(.caption)
                .foregroundStyle(PloegTheme.muted)
        }
        .disabled(!coordinator.canManageModels)
    }

    private var defaultModels: [SpeechModelDescriptor] {
        coordinator.modelManager.catalog.filter { $0.supports(language: "en") && $0.supports(language: "nl") }
    }

    private func languagePicker(
        _ title: String,
        language: String,
        keyPath: ReferenceWritableKeyPath<AppSettings, String?>
    ) -> some View {
        Picker(title, selection: languageBinding(keyPath)) {
            Text(UserFacingMessage.useDefaultModel).tag("")
            ForEach(coordinator.modelManager.catalog.filter { $0.supports(language: language) }) { model in
                Text(model.displayName).tag(model.id)
            }
        }
    }

    private func languageBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, String?>) -> Binding<String> {
        Binding(
            get: { coordinator.settings[keyPath: keyPath] ?? "" },
            set: { id in
                coordinator.settings[keyPath: keyPath] = id.isEmpty ? nil : id
                coordinator.selectModelForManagement(id: id.isEmpty ? coordinator.settings.defaultDictationModelID : id)
            }
        )
    }

    private var defaultBinding: Binding<String> {
        Binding(
            get: { coordinator.settings.defaultDictationModelID },
            set: { id in
                coordinator.settings.defaultDictationModelID = id
                coordinator.selectModelForManagement(id: id)
            }
        )
    }
}
