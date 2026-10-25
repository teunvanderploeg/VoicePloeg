import Foundation

enum ReleaseConfig {
    static let defaultModelID = "ggml-base.en-q5_1"
    static let defaultMultilingualModelID = "ggml-base-q5_1"
    static let defaultBarkModelID = "underdog-bark-3"
    static let barkRuntimeVersion = "3.0-mlx0.32.2-py3.12-v1"
    static let defaultCrisperModelID = "crisper-whisper-2-medium"
    static let defaultLanguage = "auto"
    static let crisperRuntimeVersion = "2.0.1-py3.12-v1"
    static let crisperLicenseVersion = "nyra-health-non-commercial-research-2026-07"
    static let maxRecordingDurationSeconds: TimeInterval = 120
    static let maxTranscriptHistoryItems = 40
}

enum UserFacingMessage {
    static let languageModelsTitle = "Models by language"
    static let englishModel = "English"
    static let dutchModel = "Dutch"
    static let defaultModel = "Default"
    static let useDefaultModel = "Use default"
    static let languageModelsDescription = "Default handles other languages and any language set to Use default. Auto requires a whisper.cpp model."
    static let modelDownloadsTitle = "Model downloads"
    static let modelDownloadsDescription = "Select a model below to download or remove it. Assign the models used for dictation above."
    static let activeModel = "Active model"
    static let transcriptionLanguage = "Transcription language"
    static let automaticLanguage = "Auto"
    static let germanLanguage = "German"
    static let frenchLanguage = "French"
    static let spanishLanguage = "Spanish"
    static func localWorkerTimedOut(_ seconds: TimeInterval) -> String {
        "Local transcription exceeded timeout (\(Int(seconds))s)."
    }
    static let localWorkerInvalidResponse = "The local transcription worker returned an invalid response."
    static let localWorkerMismatchedResponse = "The local transcription worker returned a response for a different request."
    static let localWorkerUnknownError = "Unknown local transcription worker error."
    static func localWorkerExited(_ message: String) -> String {
        "The local transcription worker exited unexpectedly: \(message)"
    }

    static let barkName = "Underdog Bark 3.0"
    static let barkEnglishOnly = "Bark supports English only. Select English or switch to a multilingual model."
    static let barkIncompatibleHardware = "Bark requires an Apple Silicon Mac. whisper.cpp remains available."
    static let barkRuntimeMissing = "Install the local Bark runtime in Settings before recording."
    static let barkModelMissing = "Download the selected local Bark model in Settings before recording."
    static let barkResourcesMissing = "Bark runtime resources are missing from the app."
    static let barkInstallerMissing = "The local runtime installer is missing. Run Scripts/bootstrap_crisper_runtime.sh and rebuild."
    static let barkInvalidResponse = "Bark returned no valid transcript."
    static let barkOutOfMemory = "Bark ran out of memory. Close other applications or switch to a smaller whisper.cpp model."
    static let barkRuntimeTitle = "Local Bark runtime"
    static let barkRuntimeDescription = "Standard, Plus, and Pro run English transcription locally on Apple Silicon. Each model needs about 1.25 GB for its prepared weights, plus runtime files. Setup can temporarily use several GB of memory."
    static let barkAttribution = "Bark by Conway Research, derived from NVIDIA Parakeet and Moondream Parakeet Ultra. CC BY 4.0."
    static let barkInstallRuntime = "Install Bark runtime"
    static let barkRemoveRuntime = "Remove Bark runtime"
    static let barkInstallingRuntime = "Installing the local Bark runtime…"
    static let barkModelCard = "Model details and license"
    static func barkOperationFailed(_ message: String) -> String {
        "Bark operation failed: \(message)"
    }
    static func barkTimedOut(_ seconds: TimeInterval) -> String {
        "Bark exceeded timeout (\(Int(seconds))s)."
    }

    static let releaseShortcutKeys = "Release the shortcut keys before pasting. The transcript was saved in History."
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
