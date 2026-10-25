import Foundation

struct RuntimeInstallation: Codable {
    let version: String
    var installedAt: Date? = Date()
}

enum RuntimeInstaller {
    static func recoverInterruptedReplacement(at root: URL) throws {
        let backup = root.appendingPathExtension("previous")
        let manifest = try? Data(contentsOf: root.appendingPathComponent("installation.json"))
        let ready = manifest.flatMap { try? JSONDecoder().decode(RuntimeInstallation.self, from: $0) } != nil
        if !ready, FileManager.default.fileExists(atPath: backup.path) {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            try FileManager.default.moveItem(at: backup, to: root)
        }
    }

    static func install(root: URL, uv: URL, requirements: URL, version: String,
                        healthArguments: [String], offlineEnvironment: [String: String]) async throws {
        let manager = FileManager.default
        try recoverInterruptedReplacement(at: root)
        let parent = root.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let candidate = parent.appendingPathComponent(".install-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: candidate) }
        var environment = ProcessInfo.processInfo.environment
        environment["UV_PYTHON_INSTALL_DIR"] = parent.appendingPathComponent("Python").path
        environment["UV_CACHE_DIR"] = parent.appendingPathComponent("Cache").path
        let python = candidate.appendingPathComponent(".venv/bin/python")
        try await run(uv, ["venv", "--relocatable", "--python", "3.12", candidate.appendingPathComponent(".venv").path],
                      environment: environment, timeout: 600)
        try await run(uv, ["pip", "install", "--python", python.path, "--require-hashes", "--only-binary", ":all:", "-r", requirements.path],
                      environment: environment, timeout: 1_800)
        try await run(python, healthArguments, environment: offlineEnvironment, timeout: 60)
        try Task.checkCancellation()
        let backup = root.appendingPathExtension("previous")
        if manager.fileExists(atPath: backup.path) { try manager.removeItem(at: backup) }
        if manager.fileExists(atPath: root.path) { try manager.moveItem(at: root, to: backup) }
        do {
            try manager.moveItem(at: candidate, to: root)
            // Verify imports and paths again at the location used by real workers.
            try await run(root.appendingPathComponent(".venv/bin/python"), healthArguments,
                          environment: offlineEnvironment, timeout: 60)
            try JSONEncoder().encode(RuntimeInstallation(version: version))
                .write(to: root.appendingPathComponent("installation.json"), options: .atomic)
        } catch {
            try? manager.removeItem(at: root)
            if manager.fileExists(atPath: backup.path) { try manager.moveItem(at: backup, to: root) }
            throw error
        }
        if manager.fileExists(atPath: backup.path) { try manager.removeItem(at: backup) }
    }

    private static func run(_ executable: URL, _ arguments: [String], environment: [String: String],
                            timeout: TimeInterval) async throws {
        let result = try await SubprocessRunner.run(executable: executable, arguments: arguments,
            environment: environment, timeout: timeout)
        guard result.status == 0 else { throw CrisperRuntimeError.installationFailed(result.standardError) }
    }
}
