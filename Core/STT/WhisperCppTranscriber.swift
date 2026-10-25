import Foundation

enum WhisperTranscriptNormalizer {
    static func normalize(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum WhisperTranscriberError: Error, LocalizedError {
    case modelNotLoaded
    case whisperCLINotFound(String)
    case processTimedOut(TimeInterval)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No model loaded"
        case let .whisperCLINotFound(path):
            return "whisper-cli not found (configured: \(path)). Build whisper.cpp and verify Settings -> Path to whisper-cli."
        case let .processTimedOut(seconds):
            return "whisper.cpp exceeded timeout (\(Int(seconds))s)"
        case let .processFailed(message):
            return "whisper.cpp failed: \(message)"
        }
    }
}

final class WhisperCppTranscriber: SpeechTranscribing, @unchecked Sendable {
    private let timeoutSeconds: TimeInterval
    private let worker = WhisperWorker()

    init(timeoutSeconds: TimeInterval = 180) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// Reads the model ahead of time so macOS can satisfy whisper-cli's first
    /// model load from the unified file cache instead of storage.
    func preloadModel(at modelURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw WhisperTranscriberError.modelNotLoaded
        }
        try await worker.preloadModel(at: modelURL)
    }

    func invalidatePreloadedModel() async {
        await worker.invalidatePreloadedModel()
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptResult {
        guard FileManager.default.fileExists(atPath: request.localModelURL.path) else {
            throw WhisperTranscriberError.modelNotLoaded
        }

        if request.samples.isEmpty {
            return TranscriptResult(text: "", segments: [], duration: 0, processingTime: 0)
        }

        let configuredPath = request.whisperCLIPath ?? ""
        guard let cliPath = WhisperCLIResolver.resolve(configuredPath: configuredPath) else {
            throw WhisperTranscriberError.whisperCLINotFound(configuredPath)
        }

        return try await worker.transcribe(
            samples: request.samples,
            language: request.language,
            cliPath: cliPath,
            modelPath: request.localModelURL.path,
            timeoutSeconds: timeoutSeconds
        )
    }
}

private actor WhisperWorker {
    private static let preloadChunkSize = 8 * 1_024 * 1_024
    private var preloadedModel: PreloadedModel?

    func preloadModel(at modelURL: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: modelURL.path)
        let candidate = PreloadedModel(
            path: modelURL.path,
            size: (attributes[.size] as? NSNumber)?.uint64Value,
            modificationDate: attributes[.modificationDate] as? Date
        )
        guard preloadedModel != candidate else { return }

        let handle = try FileHandle(forReadingFrom: modelURL)
        defer { try? handle.close() }

        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: Self.preloadChunkSize), !data.isEmpty else {
                break
            }
        }
        preloadedModel = candidate
    }

    func invalidatePreloadedModel() {
        preloadedModel = nil
    }

    func transcribe(
        samples: [Float],
        language: String?,
        cliPath: String,
        modelPath: String,
        timeoutSeconds: TimeInterval
    ) async throws -> TranscriptResult {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicePloeg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let wavURL = tempDirectory.appendingPathComponent("input.wav")
        let outputPrefix = tempDirectory.appendingPathComponent("result")
        let outputTxtURL = outputPrefix.appendingPathExtension("txt")

        try WavWriter.write(samples: samples, to: wavURL)

        var arguments = [
            "-m", modelPath,
            "-f", wavURL.path,
            "-otxt",
            "-of", outputPrefix.path,
            "-nt"
        ]

        if let language {
            arguments.append(contentsOf: ["-l", language])
        }

        let startedAt = Date()
        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(
                executable: URL(fileURLWithPath: cliPath),
                arguments: arguments,
                timeout: timeoutSeconds
            )
        } catch SubprocessError.timedOut {
            throw WhisperTranscriberError.processTimedOut(timeoutSeconds)
        }
        guard result.status == 0 else {
            throw WhisperTranscriberError.processFailed(result.standardError)
        }

        let rawOutputText: String
        if FileManager.default.fileExists(atPath: outputTxtURL.path) {
            rawOutputText = try String(contentsOf: outputTxtURL)
        } else {
            rawOutputText = result.standardOutput
        }
        let outputText = WhisperTranscriptNormalizer.normalize(rawOutputText)

        let duration = Double(samples.count) / 16_000
        let processing = Date().timeIntervalSince(startedAt)
        let segments = outputText.isEmpty
            ? []
            : [TranscriptSegment(start: 0, end: duration, text: outputText)]

        return TranscriptResult(
            text: outputText,
            segments: segments,
            duration: duration,
            processingTime: processing
        )
    }
}

private struct PreloadedModel: Equatable {
    let path: String
    let size: UInt64?
    let modificationDate: Date?
}
