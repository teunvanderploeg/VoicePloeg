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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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

        let process = try OwnedSubprocess(executable: executable, arguments: arguments,
            environment: environment, standardOutput: output, standardError: error)

        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw SubprocessError.timedOut }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
        } catch {
            process.killGroup()
            await process.waitForExit(timeout: .seconds(2))
            throw error
        }
        // A successful launcher must not leave background installers behind either.
        process.killGroup()
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
