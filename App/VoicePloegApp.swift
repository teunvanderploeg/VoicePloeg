import SwiftUI

@main
struct VoicePloegApp: App {
    @StateObject private var coordinator = AppCoordinator()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarRoot(coordinator: coordinator)
        } label: {
            Label("VoicePloeg", systemImage: coordinator.state.symbolName)
        }

        Settings {
            SettingsView(coordinator: coordinator)
                .frame(minWidth: 860, minHeight: 620)
        }
    }
}
