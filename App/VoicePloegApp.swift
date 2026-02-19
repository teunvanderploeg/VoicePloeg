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

        Window("Settings", id: "settings") {
            SettingsView(coordinator: coordinator)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 1000, height: 720)
        .commands {
            SettingsCommands()
        }
    }
}

private struct SettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings...") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }
}
