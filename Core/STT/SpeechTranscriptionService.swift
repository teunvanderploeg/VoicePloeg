import Foundation

actor SpeechTranscriptionService: SpeechTranscribing {
    private let whisperTranscriber: WhisperCppTranscriber
    private let crisperTranscriber: CrisperWhisperTranscriber

    init(
        whisperTranscriber: WhisperCppTranscriber = WhisperCppTranscriber(),
        crisperTranscriber: CrisperWhisperTranscriber
    ) {
        self.whisperTranscriber = whisperTranscriber
        self.crisperTranscriber = crisperTranscriber
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptResult {
        switch request.model.backend {
        case .whisperCpp:
            await crisperTranscriber.unload()
            return try await whisperTranscriber.transcribe(request)
        case .crisperWhisper:
            return try await crisperTranscriber.transcribe(request)
        }
    }

    func preloadModel(at modelURL: URL, backend: SpeechBackend) async throws {
        switch backend {
        case .whisperCpp:
            await crisperTranscriber.unload()
            try await whisperTranscriber.preloadModel(at: modelURL)
        case .crisperWhisper:
            try await crisperTranscriber.preloadModel(at: modelURL)
        }
    }

    func unloadCrisperModel() async {
        await crisperTranscriber.unload()
    }

    func releasePreloadedModels() async {
        await crisperTranscriber.unload()
        await whisperTranscriber.invalidatePreloadedModel()
    }
}
