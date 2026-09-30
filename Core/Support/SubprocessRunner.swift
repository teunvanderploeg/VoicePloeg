import Darwin
import Foundation

struct SubprocessResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

enum SubprocessError: Error {
    case timedOut
}

/// Redirect to temporary files so verbose subprocesses cannot fill an unread pipe.
/// Keep only the tail of each log when returning diagnostics.
enum SubprocessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) async throws -> SubprocessResult {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicePloeg-Process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        try Data().write(to: outputURL)
        try Data().write(to: errorURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? error.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = error
        try process.run()
        defer {
            // Also covers cancellation during sleep. Do not leave a worker using
            // deleted temporary audio or installation files after returning.
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while process.isRunning {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw SubprocessError.timedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        return SubprocessResult(
            status: process.terminationStatus,
            standardOutput: try logTail(at: outputURL),
            standardError: try logTail(at: errorURL)
        )
    }

    private static func logTail(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let maximumBytes: UInt64 = 1_024 * 1_024
        try handle.seek(toOffset: size > maximumBytes ? size - maximumBytes : 0)
        return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
    }
}
