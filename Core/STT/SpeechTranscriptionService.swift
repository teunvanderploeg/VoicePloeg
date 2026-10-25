import Foundation

protocol ManagedSpeechTranscribing: SpeechTranscribing {
    func preloadModel(at modelURL: URL, backend: SpeechBackend) async throws
    func unloadBarkModel() async
    func unloadCrisperModel() async
    func releasePreloadedModels() async
}

actor SpeechTranscriptionService: ManagedSpeechTranscribing {
    private let whisperTranscriber: WhisperCppTranscriber
    private let barkTranscriber: BarkTranscriber
    private let crisperTranscriber: CrisperWhisperTranscriber

    init(
        whisperTranscriber: WhisperCppTranscriber = WhisperCppTranscriber(),
        crisperTranscriber: CrisperWhisperTranscriber,
        barkTranscriber: BarkTranscriber = BarkTranscriber(runtimeManager: BarkRuntimeManager())
    ) {
        self.barkTranscriber = barkTranscriber
        self.whisperTranscriber = whisperTranscriber
        self.crisperTranscriber = crisperTranscriber
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptResult {
        switch request.model.backend {
        case .whisperCpp:
            await barkTranscriber.unload()
            await crisperTranscriber.unload()
            return try await whisperTranscriber.transcribe(request)
        case .crisperWhisper:
            await barkTranscriber.unload()
            await whisperTranscriber.invalidatePreloadedModel()
            return try await crisperTranscriber.transcribe(request)
        case .bark:
            await crisperTranscriber.unload()
            await whisperTranscriber.invalidatePreloadedModel()
            return try await barkTranscriber.transcribe(request)
        }
    }

    func preloadModel(at modelURL: URL, backend: SpeechBackend) async throws {
        switch backend {
        case .whisperCpp:
            await barkTranscriber.unload()
            await crisperTranscriber.unload()
            try await whisperTranscriber.preloadModel(at: modelURL)
        case .crisperWhisper:
            await barkTranscriber.unload()
            await whisperTranscriber.invalidatePreloadedModel()
            try await crisperTranscriber.preloadModel(at: modelURL)
        case .bark:
            await crisperTranscriber.unload()
            await whisperTranscriber.invalidatePreloadedModel()
            try await barkTranscriber.preloadModel(at: modelURL)
        }
    }

    func unloadBarkModel() async {
        await barkTranscriber.unload()
    }

    func unloadCrisperModel() async {
        await crisperTranscriber.unload()
    }

    func releasePreloadedModels() async {
        await barkTranscriber.unload()
        await crisperTranscriber.unload()
        await whisperTranscriber.invalidatePreloadedModel()
    }
}
