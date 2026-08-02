import Foundation

struct TranscriptHistoryItem: Codable, Equatable, Identifiable {
    let id: UUID
    let text: String
    let createdAt: Date
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var selectedTranscriptionBackend: SpeechBackend {
        didSet { userDefaults.set(selectedTranscriptionBackend.rawValue, forKey: Keys.selectedTranscriptionBackend) }
    }

    @Published var selectedWhisperModelID: String {
        didSet { userDefaults.set(selectedWhisperModelID, forKey: Keys.selectedWhisperModelID) }
    }

    @Published var selectedCrisperModelID: String {
        didSet { userDefaults.set(selectedCrisperModelID, forKey: Keys.selectedCrisperModelID) }
    }

    @Published var acceptedCrisperLicenseVersion: String? {
        didSet { userDefaults.set(acceptedCrisperLicenseVersion, forKey: Keys.acceptedCrisperLicenseVersion) }
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

    @Published var transcriptHistory: [TranscriptHistoryItem] {
        didSet {
            if let encoded = try? JSONEncoder().encode(transcriptHistory) {
                userDefaults.set(encoded, forKey: Keys.transcriptHistory)
            }
        }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let legacyModelID = userDefaults.string(forKey: Keys.selectedModelID)
        selectedWhisperModelID = userDefaults.string(forKey: Keys.selectedWhisperModelID)
            ?? legacyModelID
            ?? ReleaseConfig.defaultModelID
        selectedCrisperModelID = userDefaults.string(forKey: Keys.selectedCrisperModelID)
            ?? ReleaseConfig.defaultCrisperModelID
        selectedTranscriptionBackend = userDefaults.string(forKey: Keys.selectedTranscriptionBackend)
            .flatMap(SpeechBackend.init(rawValue:))
            ?? .whisperCpp
        acceptedCrisperLicenseVersion = userDefaults.string(forKey: Keys.acceptedCrisperLicenseVersion)
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

        if
            let historyData = userDefaults.data(forKey: Keys.transcriptHistory),
            let decodedHistory = try? JSONDecoder().decode([TranscriptHistoryItem].self, from: historyData)
        {
            transcriptHistory = decodedHistory
        } else {
            transcriptHistory = []
        }
    }

    func addTranscriptToHistory(_ text: String, maxItems: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let item = TranscriptHistoryItem(
            id: UUID(),
            text: trimmed,
            createdAt: Date()
        )
        transcriptHistory.insert(item, at: 0)
        if transcriptHistory.count > maxItems {
            transcriptHistory = Array(transcriptHistory.prefix(maxItems))
        }
    }

    func clearTranscriptHistory() {
        transcriptHistory.removeAll()
    }

    var selectedModelID: String {
        get {
            switch selectedTranscriptionBackend {
            case .whisperCpp:
                return selectedWhisperModelID
            case .crisperWhisper:
                return selectedCrisperModelID
            }
        }
        set {
            switch selectedTranscriptionBackend {
            case .whisperCpp:
                selectedWhisperModelID = newValue
            case .crisperWhisper:
                selectedCrisperModelID = newValue
            }
        }
    }

    private enum Keys {
        static let selectedModelID = "settings.selectedModelID"
        static let selectedTranscriptionBackend = "settings.selectedTranscriptionBackend"
        static let selectedWhisperModelID = "settings.selectedWhisperModelID"
        static let selectedCrisperModelID = "settings.selectedCrisperModelID"
        static let acceptedCrisperLicenseVersion = "settings.acceptedCrisperLicenseVersion"
        static let selectedLanguage = "settings.selectedLanguage"
        static let hotkey = "settings.hotkey"
        static let activeModelPath = "settings.activeModelPath"
        static let whisperCLIPath = "settings.whisperCLIPath"
        static let preferredInputDeviceID = "settings.preferredInputDeviceID"
        static let warnOnBluetoothInput = "settings.warnOnBluetoothInput"
        static let transcriptHistory = "settings.transcriptHistory"
    }
}
