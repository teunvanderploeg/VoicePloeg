import Darwin
import Foundation

enum LocalSpeechWorkerError: Error, LocalizedError {
    case timedOut(TimeInterval)
    case pipeSetupFailed(Int32)

    var errorDescription: String? {
        switch self {
        case let .timedOut(seconds): return UserFacingMessage.localWorkerTimedOut(seconds)
        case let .pipeSetupFailed(code): return UserFacingMessage.localWorkerPipeSetupFailed(code)
        }
    }
}

actor LocalSpeechWorkerClient {
    private let process: OwnedSubprocess
    private let input: FileHandle
    private let output: FileHandle
    private var isClosed = false
    private var handlesClosed = false
    private var requestInProgress = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    init(pythonURL: URL, workerURL: URL, environment: [String: String]) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        // A worker may exit between isRunning and write(). Suppress SIGPIPE on
        // this descriptor so a broken worker becomes an error, not an app exit.
        guard fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw LocalSpeechWorkerError.pipeSetupFailed(errno)
        }
        process = try OwnedSubprocess(executable: pythonURL, arguments: [workerURL.path, "--serve"],
            environment: environment, standardInput: inputPipe.fileHandleForReading,
            standardOutput: outputPipe.fileHandleForWriting, standardError: .standardError)
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
    }

    func request(_ request: CrisperWorkerRequest, timeout: TimeInterval) async throws -> CrisperWorkerResponse {
        try Task.checkCancellation()
        await acquireRequest()
        defer { releaseRequest() }
        try Task.checkCancellation()
        guard !isClosed, process.isRunning else {
            throw CrisperWorkerProtocolError.workerExited("process is not running")
        }
        do {
            return try await performRequest(request, timeout: timeout)
        } catch {
            isClosed = true
            stopProcess()
            await process.waitForExit(timeout: .seconds(2))
            throw error
        }
    }

    private func performRequest(_ request: CrisperWorkerRequest, timeout: TimeInterval) async throws -> CrisperWorkerResponse {
        try input.write(contentsOf: CrisperWorkerCodec.encode(request))

        let output = self.output
        let process = self.process
        let line = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try readLine(from: output) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    process.killGroup()
                    throw LocalSpeechWorkerError.timedOut(timeout)
                }
                guard let first = try await group.next() else {
                    throw CrisperWorkerProtocolError.invalidResponse
                }
                group.cancelAll()
                return first
            }
        } onCancel: {
            process.killGroup()
        }
        return try CrisperWorkerCodec.decode(line, expectedID: request.id)
    }

    func shutdown() async throws {
        guard !handlesClosed else { return }
        isClosed = true
        // Never race a shutdown response/read or close a descriptor while another
        // request is reading. Stop an in-flight load immediately, then join it.
        if requestInProgress { stopProcess() }
        await acquireRequest()
        defer { releaseRequest() }
        guard !handlesClosed else { return }
        if process.isRunning {
            _ = try? await performRequest(
                CrisperWorkerRequest(id: UUID(), command: "shutdown"),
                timeout: 5
            )
            await process.waitForExit(timeout: .seconds(2))
        }
        stopProcess()
        await process.waitForExit(timeout: .seconds(2))
        try? input.close()
        try? output.close()
        handlesClosed = true
    }

    func isRunning() -> Bool {
        !isClosed && process.isRunning
    }

    private func stopProcess() {
        process.killGroup()
    }

    private func acquireRequest() async {
        if !requestInProgress {
            requestInProgress = true
            return
        }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    private func releaseRequest() {
        if requestWaiters.isEmpty {
            requestInProgress = false
        } else {
            requestWaiters.removeFirst().resume()
        }
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
