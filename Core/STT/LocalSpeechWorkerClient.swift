import Foundation

enum LocalSpeechWorkerError: Error, LocalizedError {
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .timedOut(seconds): return UserFacingMessage.localWorkerTimedOut(seconds)
        }
    }
}

actor LocalSpeechWorkerClient {
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
                    throw LocalSpeechWorkerError.timedOut(timeout)
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
