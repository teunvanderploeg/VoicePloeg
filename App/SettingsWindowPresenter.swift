import AppKit
import PloegKit
import SwiftUI

@MainActor
protocol VoiceSettingsWindowPresenting: AnyObject {
    func showAndActivate()
}

/// Every settings route shares this retained window, including external reopens.
@MainActor
final class VoiceSettingsPresenter {
    private let makeWindow: () -> any VoiceSettingsWindowPresenting
    private var window: (any VoiceSettingsWindowPresenting)?

    init(makeWindow: @escaping () -> any VoiceSettingsWindowPresenting) {
        self.makeWindow = makeWindow
    }

    convenience init(coordinator: AppCoordinator) {
        self.init { NativeVoiceSettingsWindow(coordinator: coordinator) }
    }

    func showSettings() {
        if window == nil { window = makeWindow() }
        window?.showAndActivate()
    }
}

@MainActor
private final class NativeVoiceSettingsWindow: NSWindowController, VoiceSettingsWindowPresenting {
    init(coordinator: AppCoordinator) {
        let controller = NSHostingController(rootView: SettingsView(coordinator: coordinator))
        let window = NSWindow(contentViewController: controller)
        window.title = UserFacingMessage.settingsTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1000, height: 720))
        window.contentMinSize = NSSize(width: 860, height: 620)
        window.backgroundColor = PloegTheme.canvasNS
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { return nil }

    func showAndActivate() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
