import Foundation

actor BarkTranscriber: SpeechTranscribing {
    private let runtimeManager: BarkRuntimeManager
    private let timeoutSeconds: TimeInterval
    private var client: LocalSpeechWorkerClient?
    private var loadedModelPath: String?
    private var loadingModelPath: String?
    private var loadingGeneration: UUID?
    private var loadingClientTask: Task<LocalSpeechWorkerClient, Error>?

    init(runtimeManager: BarkRuntimeManager, timeoutSeconds: TimeInterval = 180) {
        self.runtimeManager = runtimeManager
        self.timeoutSeconds = timeoutSeconds
    }

    func preloadModel(at modelURL: URL) async throws {
        guard FileManager.default.fileExists(
            atPath: modelURL.appendingPathComponent("model.safetensors").path
        ) else {
            throw BarkError.modelMissing
        }
        _ = try await prepareClient(modelURL: modelURL)
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptResult {
        guard request.language == "en" else {
            throw BarkError.englishOnly
        }
        guard FileManager.default.fileExists(
            atPath: request.localModelURL.appendingPathComponent("model.safetensors").path
        ) else {
            throw BarkError.modelMissing
        }
        if request.samples.isEmpty {
            return TranscriptResult(text: "", segments: [], duration: 0, processingTime: 0)
        }

        let activeClient = try await prepareClient(modelURL: request.localModelURL)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicePloeg-Bark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
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
                    language: request.language
                ),
                timeout: timeoutSeconds
            )
        } catch let CrisperWorkerProtocolError.workerError(code, _) where code == "out_of_memory" {
            throw BarkError.outOfMemory
        } catch let LocalSpeechWorkerError.timedOut(seconds) {
            throw BarkError.timedOut(seconds)
        }
        guard let result = response.result,
              let text = result.text,
              let duration = result.duration,
              let processingTime = result.processingTime else {
            throw BarkError.invalidResponse
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptResult(
            text: normalized,
            segments: normalized.isEmpty ? [] : [.init(start: 0, end: duration, text: normalized)],
            duration: duration,
            processingTime: processingTime
        )
    }

    func unload() async {
        loadingClientTask?.cancel()
        loadingClientTask = nil
        loadingModelPath = nil
        loadingGeneration = nil
        if let client {
            try? await client.shutdown()
        }
        client = nil
        loadedModelPath = nil
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
        guard let workerURL = BarkResources.workerURL() else {
            throw BarkError.resourcesMissing
        }
        let pythonURL = try await runtimeManager.pythonExecutableURL()
        let environment = runtimeManager.offlineEnvironment()
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
                        path: modelPath
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
            let loadedClient = try await task.value
            if let client, loadedModelPath == modelPath, await client.isRunning() {
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
