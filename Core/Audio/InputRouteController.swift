import Foundation

/// Records ownership before changing a global route and restores only our own change.
@MainActor
final class InputRouteController {
    private let settings: AppSettings
    private let devices: any AudioInputDeviceManaging

    init(settings: AppSettings, devices: any AudioInputDeviceManaging) {
        self.settings = settings
        self.devices = devices
    }

    var hasPendingRestoration: Bool { settings.temporaryInputUID != nil }

    func begin(preferred: AudioInputDevice?, available: [AudioInputDevice]) throws {
        guard let preferred, devices.defaultInputDeviceID() != preferred.id else { return }
        let previous = available.first { $0.id == devices.defaultInputDeviceID() }
        settings.pendingInputRestorationUID = previous?.uid
        settings.temporaryInputUID = preferred.uid
        do {
            try devices.setDefaultInputDeviceID(preferred.id)
        } catch {
            clearJournal()
            throw error
        }
    }

    func restore(available: [AudioInputDevice]) throws {
        guard let temporaryUID = settings.temporaryInputUID else { return }
        guard let current = available.first(where: { $0.id == devices.defaultInputDeviceID() }) else { return }
        // An external change takes precedence over our remembered route.
        guard current.uid == temporaryUID else { clearJournal(); return }
        guard let previousUID = settings.pendingInputRestorationUID,
              let previous = available.first(where: { $0.uid == previousUID }) else {
            // Keep the journal if the previous device can return later.
            return
        }
        try devices.setDefaultInputDeviceID(previous.id)
        clearJournal()
    }

    private func clearJournal() {
        settings.pendingInputRestorationUID = nil
        settings.temporaryInputUID = nil
    }
}
