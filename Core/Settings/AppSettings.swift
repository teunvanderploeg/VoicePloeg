import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var selectedModelID: String {
        didSet { userDefaults.set(selectedModelID, forKey: Keys.selectedModelID) }
    }

    @Published var selectedLanguage: String {
        didSet { userDefaults.set(selectedLanguage, forKey: Keys.selectedLanguage) }
    }

    @Published var hotkey: HotkeyCombination {
        didSet {
            if let encoded = try? JSONEncoder().encode(hotkey) {
                userDefaults.set(encoded, forKey: Keys.hotkey)
            }
        }
    }

    @Published var activeModelPath: String? {
        didSet { userDefaults.set(activeModelPath, forKey: Keys.activeModelPath) }
    }

    @Published var whisperCLIPath: String {
        didSet { userDefaults.set(whisperCLIPath, forKey: Keys.whisperCLIPath) }
    }

    @Published var preferredInputDeviceID: UInt32? {
        didSet {
            if let preferredInputDeviceID {
                userDefaults.set(Int(preferredInputDeviceID), forKey: Keys.preferredInputDeviceID)
            } else {
                userDefaults.removeObject(forKey: Keys.preferredInputDeviceID)
            }
        }
    }

    @Published var warnOnBluetoothInput: Bool {
        didSet { userDefaults.set(warnOnBluetoothInput, forKey: Keys.warnOnBluetoothInput) }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        selectedModelID = userDefaults.string(forKey: Keys.selectedModelID) ?? ReleaseConfig.defaultModelID
        selectedLanguage = userDefaults.string(forKey: Keys.selectedLanguage) ?? ReleaseConfig.defaultLanguage
        activeModelPath = userDefaults.string(forKey: Keys.activeModelPath)
        whisperCLIPath = WhisperCLIResolver.resolve(configuredPath: userDefaults.string(forKey: Keys.whisperCLIPath))
            ?? WhisperCLIResolver.defaultHintPath()
        if let storedID = userDefaults.object(forKey: Keys.preferredInputDeviceID) as? NSNumber {
            preferredInputDeviceID = storedID.uint32Value
        } else {
            preferredInputDeviceID = nil
        }
        warnOnBluetoothInput = userDefaults.object(forKey: Keys.warnOnBluetoothInput) as? Bool ?? true

        if
            let hotkeyData = userDefaults.data(forKey: Keys.hotkey),
            let decoded = try? JSONDecoder().decode(HotkeyCombination.self, from: hotkeyData)
        {
            hotkey = decoded
        } else {
            hotkey = .default
        }
    }

    private enum Keys {
        static let selectedModelID = "settings.selectedModelID"
        static let selectedLanguage = "settings.selectedLanguage"
        static let hotkey = "settings.hotkey"
        static let activeModelPath = "settings.activeModelPath"
        static let whisperCLIPath = "settings.whisperCLIPath"
        static let preferredInputDeviceID = "settings.preferredInputDeviceID"
        static let warnOnBluetoothInput = "settings.warnOnBluetoothInput"
    }
}
