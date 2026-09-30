import Foundation

enum ReleaseConfig {
    static let defaultModelID = "ggml-base.en-q5_1"
    static let defaultCrisperModelID = "crisper-whisper-2-medium"
    static let defaultLanguage = "auto"
    static let crisperRuntimeVersion = "2.0.1-py3.12-v1"
    static let crisperLicenseVersion = "nyra-health-non-commercial-research-2026-07"
    static let maxRecordingDurationSeconds: TimeInterval = 120
    static let maxTranscriptHistoryItems = 40
}

enum UserFacingMessage {
    static let startingRecording = "Starting recording…"
    static let copyTranscript = "Copy transcript"
    static let recordingLimit = "Recording stops automatically after 2 minutes."
    static let modelLanguageMismatch = "The selected model does not support this language. Choose a multilingual model in Settings."
    static let modelChecksumMissing = "The selected model has no verified checksum. Update the model catalog before downloading."
    static let modelSizeMismatch = "The model file is incomplete or has an unexpected size. Download it again."
    static let modelDownloadFailed = "The model server could not provide the selected file. Please try again."
    static let installationTimedOut = "Operation timed out"
    static let noInputAtStart = "No recording input is available. Connect a microphone and try again."

    static let selectedModelNotFound = "Selected model not found in catalog"
    static let microphonePermissionDenied = "Microphone permission denied"
    static let audioRouteNotReady = "Audio route is still switching (often Bluetooth/HFP). Please try again in a second."
    static let noInputDeviceAvailable = "No recording input is currently available. VoicePloeg will reconnect automatically when a microphone appears."
    static let inputDeviceRecoveryFailed = "A recording input appeared, but VoicePloeg could not activate it yet. It will retry when audio devices change."
    static let crisperRequiresExplicitLanguage = "CrisperWhisper requires an explicit transcription language. Choose a language in Settings."
    static let crisperIncompatibleHardware = "CrisperWhisper 2.0 requires an Apple Silicon Mac. whisper.cpp remains available."
    static let crisperRuntimeMissing = "Install the local CrisperWhisper runtime in Settings before recording."
    static let crisperModelMissing = "Download the selected local CrisperWhisper model in Settings before recording."
    static let crisperLicenseNotAccepted = "Accept the Nyra non-commercial model license before downloading CrisperWhisper weights."
    static let crisperOutOfMemory = "CrisperWhisper ran out of GPU memory. Choose a smaller model or switch to whisper.cpp."

    static func recordingElapsed(_ seconds: Int) -> String {
        let elapsed = max(0, seconds)
        return "\(elapsed / 60):\(String(format: "%02d", elapsed % 60)) / 2:00"
    }

    static func bluetoothInputBlocked(_ inputName: String) -> String {
        "Recording blocked because the selected input (\(inputName)) is Bluetooth/HFP. Disable the Bluetooth warning or choose a non-Bluetooth input."
    }
}
