import Foundation

enum CrisperTranscriberError: Error, LocalizedError {
    case explicitLanguageRequired
    case modelMissing
    case workerResourceMissing
    case workerResultMissing
    case processTimedOut(TimeInterval)
    case outOfMemory

    var errorDescription: String? {
        switch self {
        case .explicitLanguageRequired:
            return UserFacingMessage.crisperRequiresExplicitLanguage
        case .modelMissing:
            return UserFacingMessage.crisperModelMissing
        case .workerResourceMissing:
            return "CrisperWhisper worker is missing from the app"
        case .workerResultMissing:
            return "CrisperWhisper returned no transcript"
        case let .processTimedOut(seconds):
            return "CrisperWhisper exceeded timeout (\(Int(seconds))s)"
        case .outOfMemory:
            return UserFacingMessage.crisperOutOfMemory
        }
    }
}

actor CrisperWhisperTranscriber: SpeechTranscribing {
    private let runtimeManager: CrisperRuntimeManager
    private let timeoutSeconds: TimeInterval
    private var client: LocalSpeechWorkerClient?
    private var loadedModelPath: String?
    private var loadingModelPath: String?
    private var loadingGeneration: UUID?
    private var loadingClientTask: Task<LocalSpeechWorkerClient, Error>?

    init(runtimeManager: CrisperRuntimeManager, timeoutSeconds: TimeInterval = 180) {
        self.runtimeManager = runtimeManager
        self.timeoutSeconds = timeoutSeconds
    }

    func preloadModel(at modelURL: URL) async throws {
        guard FileManager.default.fileExists(
            atPath: modelURL.appendingPathComponent("model.safetensors").path
        ) else {
            throw CrisperTranscriberError.modelMissing
        }
        _ = try await prepareClient(modelURL: modelURL)
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptResult {
        guard request.language != "auto" else {
            throw CrisperTranscriberError.explicitLanguageRequired
        }
        guard FileManager.default.fileExists(
            atPath: request.localModelURL.appendingPathComponent("model.safetensors").path
        ) else {
            throw CrisperTranscriberError.modelMissing
        }
        if request.samples.isEmpty {
            return TranscriptResult(text: "", segments: [], duration: 0, processingTime: 0)
        }

        let activeClient = try await prepareClient(modelURL: request.localModelURL)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicePloeg-Crisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let wavURL = temporaryDirectory.appendingPathComponent("input.wav")
        try WavWriter.write(samples: request.samples, to: wavURL)
        let response: CrisperWorkerResponse
        do {
            response = try await activeClient.request(
                CrisperWorkerRequest(
                    id: UUID(),
                    command: "transcribe",
                    wavPath: wavURL.path,
                    language: request.language,
                    mode: "intended"
                ),
                timeout: timeoutSeconds
            )
        } catch let CrisperWorkerProtocolError.workerError(code, _) where code == "mps_out_of_memory" {
            throw CrisperTranscriberError.outOfMemory
        } catch let LocalSpeechWorkerError.timedOut(seconds) {
            throw CrisperTranscriberError.processTimedOut(seconds)
        }
        guard let result = response.result,
              let text = result.text,
              let duration = result.duration,
              let processingTime = result.processingTime else {
            throw CrisperTranscriberError.workerResultMissing
        }
        let normalized = WhisperTranscriptNormalizer.normalize(text)
        return TranscriptResult(
            text: normalized,
            segments: normalized.isEmpty ? [] : [.init(start: 0, end: duration, text: normalized)],
            duration: duration,
            processingTime: processingTime
        )
    }

    func unload() async {
        let loadingTask = loadingClientTask
        let previousClient = client
        loadingClientTask = nil
        loadingModelPath = nil
        loadingGeneration = nil
        client = nil
        loadedModelPath = nil
        loadingTask?.cancel()
        if let loadingTask, case let .success(loadingClient) = await loadingTask.result {
            try? await loadingClient.shutdown()
        }
        if let previousClient { try? await previousClient.shutdown() }
    }

    private func prepareClient(modelURL: URL) async throws -> LocalSpeechWorkerClient {
        if let client, loadedModelPath == modelURL.path, await client.isRunning() {
            return client
        }
        if loadingModelPath == modelURL.path,
           let loadingGeneration,
           let loadingClientTask {
            return try await finishLoading(
                loadingClientTask,
                modelPath: modelURL.path,
                generation: loadingGeneration
            )
        }
        await unload()
        guard let workerURL = CrisperResources.workerURL() else {
            throw CrisperTranscriberError.workerResourceMissing
        }
        let pythonURL = try await runtimeManager.pythonExecutableURL()
        let environment = await runtimeManager.offlineEnvironment()
        let modelPath = modelURL.path
        let timeoutSeconds = self.timeoutSeconds
        let generation = UUID()
        let task = Task {
            let newClient = try LocalSpeechWorkerClient(
                pythonURL: pythonURL,
                workerURL: workerURL,
                environment: environment
            )
            do {
                _ = try await newClient.request(
                    CrisperWorkerRequest(
                        id: UUID(),
                        command: "loadModel",
                        path: modelPath,
                        device: "mps",
                        computeType: "float16"
                    ),
                    timeout: timeoutSeconds
                )
                return newClient
            } catch {
                try? await newClient.shutdown()
                throw error
            }
        }
        loadingModelPath = modelPath
        loadingGeneration = generation
        loadingClientTask = task
        return try await finishLoading(task, modelPath: modelPath, generation: generation)
    }

    private func finishLoading(
        _ task: Task<LocalSpeechWorkerClient, Error>,
        modelPath: String,
        generation: UUID
    ) async throws -> LocalSpeechWorkerClient {
        do {
            let loadedClient = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled else {
                try? await loadedClient.shutdown()
                throw CancellationError()
            }
            if let client, client === loadedClient, loadedModelPath == modelPath, await client.isRunning() {
                return client
            }
            guard loadingGeneration == generation else {
                try? await loadedClient.shutdown()
                throw CancellationError()
            }
            client = loadedClient
            loadedModelPath = modelPath
            loadingClientTask = nil
            loadingModelPath = nil
            loadingGeneration = nil
            return loadedClient
        } catch {
            if loadingGeneration == generation {
                loadingClientTask = nil
                loadingModelPath = nil
                loadingGeneration = nil
            }
            throw error
        }
    }
}
