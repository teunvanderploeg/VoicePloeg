import SwiftUI
import AppKit

@main
struct VoicePloegApp: App {
    @NSApplicationDelegateAdaptor(VoicePloegAppDelegate.self) private var appDelegate
    @StateObject private var coordinator: AppCoordinator

    init() {
        let coordinator = AppCoordinator()
        _coordinator = StateObject(wrappedValue: coordinator)
        appDelegate.coordinator = coordinator
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarRoot(coordinator: coordinator)
        } label: {
            if let flag = coordinator.languageFeedbackFlag {
                Image(nsImage: flagImage(flag))
            } else {
                Image(systemName: coordinator.state.symbolName)
            }
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

    /// Renders a flag emoji into an NSImage sized for the menu bar (18×18 pt).
    private func flagImage(_ emoji: String) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14)
        ]
        let str = NSAttributedString(string: emoji, attributes: attrs)
        let strSize = str.size()
        str.draw(at: NSPoint(x: (size.width - strSize.width) / 2,
                             y: (size.height - strSize.height) / 2))
        image.unlockFocus()
        image.isTemplate = false
        return image
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


@MainActor
final class VoicePloegAppDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: AppCoordinator?
    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task { @MainActor in
            await coordinator?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
