import SwiftUI
import AppKit
import PloegKit

@main
struct VoicePloegApp: App {
    @NSApplicationDelegateAdaptor(VoicePloegAppDelegate.self) private var appDelegate
    @StateObject private var coordinator: AppCoordinator
    private let previewMode: VoiceDesignPreviewMode?
    private let settingsPresenter: VoiceSettingsPresenter

    init() {
        let previewMode = VoiceDesignPreviewMode.resolve(
            arguments: ProcessInfo.processInfo.arguments, info: Bundle.main.infoDictionary ?? [:]
        )
        self.previewMode = previewMode
        let coordinator = previewMode == nil ? AppCoordinator() : VoiceDesignPreview.coordinator()
        let settingsPresenter = VoiceSettingsPresenter(coordinator: coordinator)
        self.settingsPresenter = settingsPresenter
        _coordinator = StateObject(wrappedValue: coordinator)
        appDelegate.coordinator = coordinator
        appDelegate.settingsPresenter = settingsPresenter
        appDelegate.isDesignPreview = previewMode != nil
        appDelegate.onPreviewReopen = { VoiceDesignPreview.bringToFront() }
        NSApplication.shared.setActivationPolicy(previewMode == nil ? .accessory : .regular)
        NSApplication.shared.applicationIconImage = PloegAssets.image(for: .voice)
        if let previewMode {
            DispatchQueue.main.async {
                VoiceDesignPreview.show(coordinator, mode: previewMode)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(previewMode == nil)) {
            MenuBarRoot(coordinator: coordinator, onOpenSettings: settingsPresenter.showSettings)
        } label: {
            if let flag = coordinator.languageFeedbackFlag {
                Image(nsImage: flagImage(flag))
            } else {
                Image(systemName: coordinator.state.symbolName)
            }
        }
        .menuBarExtraStyle(.window)
        .commands {
            SettingsCommands(isPreview: previewMode != nil, openSettings: settingsPresenter.showSettings)
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
    var isPreview = false
    let openSettings: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(UserFacingMessage.settingsTitle) {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])
            .disabled(isPreview)
        }
    }
}


@MainActor
final class VoicePloegAppDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: AppCoordinator?
    var settingsPresenter: VoiceSettingsPresenter?
    var isDesignPreview = false
    var onPreviewReopen: (() -> Void)?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isDesignPreview, ProcessInfo.processInfo.arguments.contains("--show-settings") else { return }
        DispatchQueue.main.async { [weak self] in
            self?.handleLaunch(arguments: ProcessInfo.processInfo.arguments)
        }
    }

    @discardableResult
    func handleLaunch(arguments: [String]) -> Bool {
        guard !isDesignPreview, arguments.contains("--show-settings") else { return false }
        settingsPresenter?.showSettings()
        return true
    }

    @discardableResult
    func handleReopen() -> Bool {
        if isDesignPreview {
            onPreviewReopen?()
        } else {
            settingsPresenter?.showSettings()
        }
        // This delegate has handled the request; don't ask AppKit to open another window.
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        handleReopen()
    }

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
