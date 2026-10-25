import Foundation

struct TranscriptHistoryItem: Codable, Equatable, Identifiable {
    let id: UUID
    let text: String
    let createdAt: Date
}

enum TranscriptRetention: String, CaseIterable, Identifiable {
    case off
    case sevenDays
    case thirtyDays
    case untilCleared

    var id: String { rawValue }
    var days: Int? {
        switch self {
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .off, .untilCleared: return nil
        }
    }
    var title: String {
        switch self {
        case .off: return UserFacingMessage.historyOff
        case .sevenDays: return UserFacingMessage.historySevenDays
        case .thirtyDays: return UserFacingMessage.historyThirtyDays
        case .untilCleared: return UserFacingMessage.historyForever
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var automaticDictationModelID: String {
        didSet { userDefaults.set(automaticDictationModelID, forKey: Keys.automaticDictationModelID) }
    }

    @Published var transcriptRetention: TranscriptRetention {
        didSet {
            userDefaults.set(transcriptRetention.rawValue, forKey: Keys.transcriptRetention)
            pruneTranscriptHistory()
        }
    }

    @Published var preferredInputDeviceUID: String? {
        didSet { userDefaults.set(preferredInputDeviceUID, forKey: Keys.preferredInputDeviceUID) }
    }

    var pendingInputRestorationUID: String? {
        get { userDefaults.string(forKey: Keys.pendingInputRestorationUID) }
        set { userDefaults.set(newValue, forKey: Keys.pendingInputRestorationUID) }
    }

    var temporaryInputUID: String? {
        get { userDefaults.string(forKey: Keys.temporaryInputUID) }
        set { userDefaults.set(newValue, forKey: Keys.temporaryInputUID) }
    }

    @Published var defaultDictationModelID: String {
        didSet { userDefaults.set(defaultDictationModelID, forKey: Keys.defaultDictationModelID) }
    }

    @Published var englishDictationModelID: String? {
        didSet { userDefaults.set(englishDictationModelID, forKey: Keys.englishDictationModelID) }
    }

    @Published var dutchDictationModelID: String? {
        didSet { userDefaults.set(dutchDictationModelID, forKey: Keys.dutchDictationModelID) }
    }

    // These selections belong to the model download controls, independently of dictation routing.
    @Published var selectedTranscriptionBackend: SpeechBackend {
        didSet { userDefaults.set(selectedTranscriptionBackend.rawValue, forKey: Keys.selectedTranscriptionBackend) }
    }

    @Published var selectedWhisperModelID: String {
        didSet { userDefaults.set(selectedWhisperModelID, forKey: Keys.selectedWhisperModelID) }
    }

    @Published var selectedCrisperModelID: String {
        didSet { userDefaults.set(selectedCrisperModelID, forKey: Keys.selectedCrisperModelID) }
    }

    @Published var selectedBarkModelID: String {
        didSet { userDefaults.set(selectedBarkModelID, forKey: Keys.selectedBarkModelID) }
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
        automaticDictationModelID = userDefaults.string(forKey: Keys.automaticDictationModelID)
            ?? ReleaseConfig.defaultMultilingualModelID
        transcriptRetention = userDefaults.string(forKey: Keys.transcriptRetention)
            .flatMap(TranscriptRetention.init(rawValue:)) ?? .untilCleared
        preferredInputDeviceUID = userDefaults.string(forKey: Keys.preferredInputDeviceUID)

        defaultDictationModelID = userDefaults.string(forKey: Keys.defaultDictationModelID)
            ?? ReleaseConfig.defaultMultilingualModelID
        englishDictationModelID = userDefaults.string(forKey: Keys.englishDictationModelID)
        dutchDictationModelID = userDefaults.string(forKey: Keys.dutchDictationModelID)

        let legacyModelID = userDefaults.string(forKey: Keys.selectedModelID)
        selectedWhisperModelID = userDefaults.string(forKey: Keys.selectedWhisperModelID)
            ?? legacyModelID
            ?? ReleaseConfig.defaultModelID
        selectedCrisperModelID = userDefaults.string(forKey: Keys.selectedCrisperModelID)
            ?? ReleaseConfig.defaultCrisperModelID
        selectedBarkModelID = userDefaults.string(forKey: Keys.selectedBarkModelID)
            ?? ReleaseConfig.defaultBarkModelID
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
        pruneTranscriptHistory()
    }

    func addTranscriptToHistory(_ text: String, maxItems: Int) {
        pruneTranscriptHistory()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcriptRetention != .off, !trimmed.isEmpty, maxItems > 0 else { return }

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

    func pruneTranscriptHistory(now: Date = Date()) {
        let cutoff = transcriptRetention.days.map { now.addingTimeInterval(-Double($0) * 86_400) }
        let retained = transcriptRetention == .off ? [] : transcriptHistory.filter { item in
            cutoff.map { item.createdAt >= $0 } ?? true
        }
        let bounded = Array(retained.prefix(ReleaseConfig.maxTranscriptHistoryItems))
        if transcriptHistory != bounded { transcriptHistory = bounded }
    }

    func removeTranscript(id: UUID) {
        transcriptHistory.removeAll { $0.id == id }
    }

    func clearTranscriptHistory() {
        transcriptHistory.removeAll()
    }

    func dictationModelID(for language: String) -> String {
        switch language {
        case "auto": return automaticDictationModelID
        case "en": return englishDictationModelID ?? defaultDictationModelID
        case "nl": return dutchDictationModelID ?? defaultDictationModelID
        default: return defaultDictationModelID
        }
    }

    func migrateModelAssignmentsIfNeeded(catalog: [SpeechModelDescriptor]) {
        let migrateAutomatic = userDefaults.string(forKey: Keys.automaticDictationModelID) == nil
        if migrateAutomatic {
            automaticDictationModelID = catalog.first { $0.id == defaultDictationModelID && $0.supports(language: "auto") }?.id
                ?? ReleaseConfig.defaultMultilingualModelID
        }
        guard userDefaults.string(forKey: Keys.defaultDictationModelID) == nil else { return }
        let current = catalog.first { $0.id == selectedModelID && $0.backend == selectedTranscriptionBackend }
        let whisper = catalog.first { $0.id == selectedWhisperModelID && $0.backend == .whisperCpp }
        let fallback = catalog.first { $0.id == ReleaseConfig.defaultMultilingualModelID }
        let multilingual = [current, whisper, fallback].compactMap { $0 }
            .first { $0.supports(language: "en") && $0.supports(language: "nl") }
            ?? catalog.first { $0.supports(language: "en") && $0.supports(language: "nl") }

        defaultDictationModelID = multilingual?.id ?? current?.id ?? ReleaseConfig.defaultMultilingualModelID
        if migrateAutomatic, let multilingual, multilingual.supports(language: "auto") {
            automaticDictationModelID = multilingual.id
        }
        if let current, current.supports(language: "en"), current.id != defaultDictationModelID {
            englishDictationModelID = current.id
        }
        if let current, current.supports(language: "nl"), current.id != defaultDictationModelID {
            dutchDictationModelID = current.id
        } else if current?.supports(language: "nl") != true,
                  userDefaults.string(forKey: Keys.selectedCrisperModelID) != nil,
                  let crisper = catalog.first(where: { $0.id == selectedCrisperModelID && $0.backend == .crisperWhisper }),
                  crisper.supports(language: "nl"), crisper.id != defaultDictationModelID {
            dutchDictationModelID = crisper.id
        }
    }

    var selectedModelID: String {
        get {
            switch selectedTranscriptionBackend {
            case .whisperCpp:
                return selectedWhisperModelID
            case .crisperWhisper:
                return selectedCrisperModelID
            case .bark:
                return selectedBarkModelID
            }
        }
        set {
            switch selectedTranscriptionBackend {
            case .whisperCpp:
                selectedWhisperModelID = newValue
            case .crisperWhisper:
                selectedCrisperModelID = newValue
            case .bark:
                selectedBarkModelID = newValue
            }
        }
    }

    private enum Keys {
        static let automaticDictationModelID = "settings.automaticDictationModelID"
        static let transcriptRetention = "settings.transcriptRetention"
        static let preferredInputDeviceUID = "settings.preferredInputDeviceUID"
        static let pendingInputRestorationUID = "settings.pendingInputRestorationUID"
        static let temporaryInputUID = "settings.temporaryInputUID"
        static let defaultDictationModelID = "settings.defaultDictationModelID"
        static let englishDictationModelID = "settings.englishDictationModelID"
        static let dutchDictationModelID = "settings.dutchDictationModelID"
        static let selectedModelID = "settings.selectedModelID"
        static let selectedTranscriptionBackend = "settings.selectedTranscriptionBackend"
        static let selectedWhisperModelID = "settings.selectedWhisperModelID"
        static let selectedBarkModelID = "settings.selectedBarkModelID"
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
