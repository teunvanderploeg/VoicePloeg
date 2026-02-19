import Foundation

enum ReleaseConfig {
    static let defaultModelID = "ggml-base.en-q5_1"
    static let defaultLanguage = "auto"
    static let maxRecordingDurationSeconds: TimeInterval = 120
    static let maxTranscriptHistoryItems = 40
}

enum UserFacingMessage {
    static let selectedModelNotFound = "Selected model not found in catalog"
    static let microphonePermissionDenied = "Microphone permission denied"
    static let preferredInputUnavailable = "Preferred recording input is not available. Connect it or choose another input device."

    static func bluetoothInputBlocked(_ inputName: String) -> String {
        "Recording blocked because the selected input (\(inputName)) is Bluetooth/HFP. Disable the Bluetooth warning or choose a non-Bluetooth input."
    }
}
