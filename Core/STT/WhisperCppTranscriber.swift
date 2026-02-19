import Foundation

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

final class WhisperCppTranscriber: SpeechTranscriber {
    private var modelURL: URL?
    private let cliPathProvider: () -> String
    private let timeoutSeconds: TimeInterval
    private let worker = WhisperWorker()

    init(
        cliPathProvider: @escaping () -> String,
        timeoutSeconds: TimeInterval = 180
    ) {
        self.cliPathProvider = cliPathProvider
        self.timeoutSeconds = timeoutSeconds
    }

    func loadModel(at url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WhisperTranscriberError.modelNotLoaded
        }
        modelURL = url
    }

    func transcribe(samples: [Float], language: String?) async throws -> TranscriptResult {
        guard let modelURL else {
            throw WhisperTranscriberError.modelNotLoaded
        }

        if samples.isEmpty {
            return TranscriptResult(text: "", segments: [], duration: 0, processingTime: 0)
        }

        let configuredPath = cliPathProvider()
        guard let cliPath = WhisperCLIResolver.resolve(configuredPath: configuredPath) else {
            throw WhisperTranscriberError.whisperCLINotFound(configuredPath)
        }

        let activeModelPath = modelURL.path
        return try await worker.transcribe(
            samples: samples,
            language: language,
            cliPath: cliPath,
            modelPath: activeModelPath,
            timeoutSeconds: timeoutSeconds
        )
    }
}

private actor WhisperWorker {
    func transcribe(
        samples: [Float],
        language: String?,
        cliPath: String,
        modelPath: String,
        timeoutSeconds: TimeInterval
    ) async throws -> TranscriptResult {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicePloeg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let wavURL = tempDirectory.appendingPathComponent("input.wav")
        let outputPrefix = tempDirectory.appendingPathComponent("result")
        let outputTxtURL = outputPrefix.appendingPathExtension("txt")

        try WavWriter.write(samples: samples, to: wavURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)

        var arguments = [
            "-m", modelPath,
            "-f", wavURL.path,
            "-otxt",
            "-of", outputPrefix.path,
            "-nt"
        ]

        if let language, language.lowercased() != "auto" {
            arguments.append(contentsOf: ["-l", language])
        }

        process.arguments = arguments

        let stdOut = Pipe()
        let stdErr = Pipe()
        process.standardOutput = stdOut
        process.standardError = stdErr

        let startedAt = Date()
        try process.run()
        try await awaitProcessExit(process, timeoutSeconds: timeoutSeconds)

        let stderrData = stdErr.fileHandleForReading.readDataToEndOfFile()
        let stderrString = String(data: stderrData, encoding: .utf8) ?? "unknown error"

        guard process.terminationStatus == 0 else {
            throw WhisperTranscriberError.processFailed(stderrString)
        }

        let outputText: String
        if FileManager.default.fileExists(atPath: outputTxtURL.path) {
            outputText = (try String(contentsOf: outputTxtURL)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let stdoutData = stdOut.fileHandleForReading.readDataToEndOfFile()
            outputText = (String(data: stdoutData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

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

    private func awaitProcessExit(
        _ process: Process,
        timeoutSeconds: TimeInterval
    ) async throws {
        let timeoutNanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
        let startedAt = DispatchTime.now().uptimeNanoseconds

        while process.isRunning {
            try Task.checkCancellation()

            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAt
            if elapsedNanoseconds >= timeoutNanoseconds {
                process.terminate()
                throw WhisperTranscriberError.processTimedOut(timeoutSeconds)
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
