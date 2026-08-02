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
    private var client: CrisperWorkerClient?
    private var loadedModelPath: String?
    private var idleTask: Task<Void, Never>?

    init(runtimeManager: CrisperRuntimeManager, timeoutSeconds: TimeInterval = 180) {
        self.runtimeManager = runtimeManager
        self.timeoutSeconds = timeoutSeconds
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

        idleTask?.cancel()
        let activeClient = try await prepareClient(modelURL: request.localModelURL)
        defer { scheduleIdleUnload() }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicePloeg-Crisper-\(UUID().uuidString)", isDirectory: true)
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
                    language: request.language,
                    mode: "intended"
                ),
                timeout: timeoutSeconds
            )
        } catch let CrisperWorkerProtocolError.workerError(code, _) where code == "mps_out_of_memory" {
            throw CrisperTranscriberError.outOfMemory
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
        idleTask?.cancel()
        idleTask = nil
        if let client {
            try? await client.shutdown()
        }
        client = nil
        loadedModelPath = nil
    }

    private func prepareClient(modelURL: URL) async throws -> CrisperWorkerClient {
        if let client, loadedModelPath == modelURL.path, await client.isRunning() {
            return client
        }
        await unload()
        guard let workerURL = CrisperResources.workerURL() else {
            throw CrisperTranscriberError.workerResourceMissing
        }
        let pythonURL = try await runtimeManager.pythonExecutableURL()
        let environment = await runtimeManager.offlineEnvironment()
        let newClient = try CrisperWorkerClient(
            pythonURL: pythonURL,
            workerURL: workerURL,
            environment: environment
        )
        do {
            _ = try await newClient.request(
                CrisperWorkerRequest(
                    id: UUID(),
                    command: "loadModel",
                    path: modelURL.path,
                    device: "mps",
                    computeType: "float16"
                ),
                timeout: timeoutSeconds
            )
        } catch {
            try? await newClient.shutdown()
            throw error
        }
        client = newClient
        loadedModelPath = modelURL.path
        return newClient
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }
}

private actor CrisperWorkerClient {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle

    init(pythonURL: URL, workerURL: URL, environment: [String: String]) throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = pythonURL
        process.arguments = [workerURL.path, "--serve"]
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        try process.run()
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
    }

    func request(_ request: CrisperWorkerRequest, timeout: TimeInterval) async throws -> CrisperWorkerResponse {
        guard process.isRunning else {
            throw CrisperWorkerProtocolError.workerExited("process is not running")
        }
        try input.write(contentsOf: CrisperWorkerCodec.encode(request))

        let output = self.output
        let process = self.process
        let line = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try readLine(from: output) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if process.isRunning { process.terminate() }
                    throw CrisperTranscriberError.processTimedOut(timeout)
                }
                guard let first = try await group.next() else {
                    throw CrisperWorkerProtocolError.invalidResponse
                }
                group.cancelAll()
                return first
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        return try CrisperWorkerCodec.decode(line, expectedID: request.id)
    }

    func shutdown() async throws {
        if process.isRunning {
            _ = try? await request(
                CrisperWorkerRequest(id: UUID(), command: "shutdown"),
                timeout: 5
            )
        }
        if process.isRunning { process.terminate() }
        try? input.close()
        try? output.close()
    }

    func isRunning() -> Bool {
        process.isRunning
    }
}

private func readLine(from handle: FileHandle) throws -> Data {
    var data = Data()
    while true {
        guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
            throw CrisperWorkerProtocolError.workerExited("stdout closed")
        }
        if byte[0] == 0x0A { return data }
        data.append(byte)
    }
}
