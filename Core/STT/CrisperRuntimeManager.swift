import Foundation

enum CrisperRuntimeStatus: Equatable, Sendable {
    case notInstalled
    case installing
    case ready(version: String)
    case incompatibleHardware
    case failed(message: String)

    var title: String {
        switch self {
        case .notInstalled:
            return "Not installed"
        case .installing:
            return "Installing…"
        case let .ready(version):
            return "Ready (\(version))"
        case .incompatibleHardware:
            return "Requires Apple Silicon"
        case let .failed(message):
            return "Failed: \(message)"
        }
    }
}

enum CrisperRuntimeError: Error, LocalizedError {
    case incompatibleHardware
    case uvNotFound
    case resourcesMissing
    case runtimeNotInstalled
    case installationFailed(String)
    case modelInstallationFailed(String)

    var errorDescription: String? {
        switch self {
        case .incompatibleHardware:
            return UserFacingMessage.crisperIncompatibleHardware
        case .uvNotFound:
            return "The bundled CrisperWhisper installer is missing. Run Scripts/bootstrap_crisper_runtime.sh and rebuild."
        case .resourcesMissing:
            return "CrisperWhisper runtime resources are missing from the app"
        case .runtimeNotInstalled:
            return UserFacingMessage.crisperRuntimeMissing
        case let .installationFailed(message):
            return "CrisperWhisper runtime installation failed: \(message)"
        case let .modelInstallationFailed(message):
            return "CrisperWhisper model installation failed: \(message)"
        }
    }
}

actor CrisperRuntimeManager {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    nonisolated static var isCompatibleHardware: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    func status() -> CrisperRuntimeStatus {
        guard Self.isCompatibleHardware else { return .incompatibleHardware }
        guard fileManager.isExecutableFile(atPath: pythonURL().path),
              fileManager.fileExists(atPath: installationManifestURL().path) else {
            return .notInstalled
        }
        return .ready(version: ReleaseConfig.crisperRuntimeVersion)
    }

    func pythonExecutableURL() throws -> URL {
        guard case .ready = status() else { throw CrisperRuntimeError.runtimeNotInstalled }
        return pythonURL()
    }

    func install() async throws {
        guard Self.isCompatibleHardware else { throw CrisperRuntimeError.incompatibleHardware }
        guard let requirementsURL = CrisperResources.requirementsURL() else {
            throw CrisperRuntimeError.resourcesMissing
        }
        guard let uvURL = resolveUVURL() else { throw CrisperRuntimeError.uvNotFound }

        let parent = runtimeRootURL().deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }

        var environment = ProcessInfo.processInfo.environment
        environment["UV_PYTHON_INSTALL_DIR"] = parent.appendingPathComponent("Python", isDirectory: true).path
        environment["UV_CACHE_DIR"] = parent.appendingPathComponent("Cache", isDirectory: true).path

        do {
            try await run(
                executable: uvURL,
                arguments: ["venv", "--python", "3.12", temporary.appendingPathComponent(".venv").path],
                environment: environment,
                timeout: 600
            )
            let temporaryPython = temporary.appendingPathComponent(".venv/bin/python")
            try await run(
                executable: uvURL,
                arguments: [
                    "pip", "install", "--python", temporaryPython.path,
                    "--require-hashes", "-r", requirementsURL.path
                ],
                environment: environment,
                timeout: 1_800
            )
            try await run(
                executable: temporaryPython,
                arguments: ["-c", "import crisperwhisper, torch; print(crisperwhisper.__version__)"],
                environment: offlineEnvironment(),
                timeout: 60
            )

            let manifest = RuntimeInstallationManifest(
                version: ReleaseConfig.crisperRuntimeVersion,
                installedAt: Date()
            )
            try JSONEncoder().encode(manifest).write(to: temporary.appendingPathComponent("installation.json"))

            let destination = runtimeRootURL()
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            throw CrisperRuntimeError.installationFailed(error.localizedDescription)
        }
    }

    func remove() throws {
        let root = runtimeRootURL()
        guard fileManager.fileExists(atPath: root.path) else { return }
        try fileManager.removeItem(at: root)
    }

    func installModel(_ model: SpeechModelDescriptor, destination: URL) async throws {
        guard case let .huggingFaceSnapshot(repositoryID, revision) = model.acquisition else {
            throw ModelManagerError.unsupportedAcquisition
        }
        guard let workerURL = CrisperResources.workerURL() else {
            throw CrisperRuntimeError.resourcesMissing
        }
        let python = try pythonExecutableURL()

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await run(
                executable: python,
                arguments: [
                    workerURL.path,
                    "--install-model",
                    "--repository", repositoryID,
                    "--revision", revision,
                    "--destination", destination.path,
                    "--model-id", model.id,
                    "--runtime-version", ReleaseConfig.crisperRuntimeVersion
                ],
                environment: ProcessInfo.processInfo.environment,
                timeout: 7_200
            )
            guard fileManager.fileExists(atPath: destination.appendingPathComponent("installation.json").path),
                  fileManager.fileExists(atPath: destination.appendingPathComponent("model.safetensors").path) else {
                throw ModelManagerError.incompleteInstallation
            }
        } catch {
            throw CrisperRuntimeError.modelInstallationFailed(error.localizedDescription)
        }
    }

    func offlineEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["HF_DATASETS_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["DO_NOT_TRACK"] = "1"
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        return environment
    }

    private func runtimeRootURL() -> URL {
        applicationSupportURL()
            .appendingPathComponent("CrisperRuntime", isDirectory: true)
            .appendingPathComponent(ReleaseConfig.crisperRuntimeVersion, isDirectory: true)
    }

    private func pythonURL() -> URL {
        runtimeRootURL().appendingPathComponent(".venv/bin/python")
    }

    private func installationManifestURL() -> URL {
        runtimeRootURL().appendingPathComponent("installation.json")
    }

    private func applicationSupportURL() -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("VoicePloeg", isDirectory: true)
    }

    private func resolveUVURL() -> URL? {
        let candidates = [
            CrisperResources.bundledUVURL(),
            URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
            URL(fileURLWithPath: "/usr/local/bin/uv")
        ].compactMap { $0 }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()

        let startedAt = Date()
        while process.isRunning {
            try Task.checkCancellation()
            if Date().timeIntervalSince(startedAt) > timeout {
                process.terminate()
                throw CrisperRuntimeError.installationFailed("Operation timed out")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard process.terminationStatus == 0 else {
            let data = error.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "Exit status \(process.terminationStatus)"
            throw CrisperRuntimeError.installationFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

private struct RuntimeInstallationManifest: Codable {
    let version: String
    let installedAt: Date
}
