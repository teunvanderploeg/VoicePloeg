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
    private var isInstalling = false
    private let fileManager: FileManager
    private let rootOverride: URL?

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootURL
    }

    nonisolated static var isCompatibleHardware: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    func status() -> CrisperRuntimeStatus {
        if isInstalling { return .installing }
        guard Self.isCompatibleHardware else { return .incompatibleHardware }
        try? RuntimeInstaller.recoverInterruptedReplacement(at: runtimeRootURL())
        guard fileManager.isExecutableFile(atPath: pythonURL().path),
              let data = try? Data(contentsOf: installationManifestURL()),
              let manifest = try? JSONDecoder().decode(RuntimeInstallation.self, from: data),
              manifest.version == ReleaseConfig.crisperRuntimeVersion else {
            return .notInstalled
        }
        return .ready(version: ReleaseConfig.crisperRuntimeVersion)
    }

    func pythonExecutableURL() throws -> URL {
        guard case .ready = status() else { throw CrisperRuntimeError.runtimeNotInstalled }
        return pythonURL()
    }

    func install() async throws {
        guard !isInstalling else { throw CrisperRuntimeError.installationFailed(UserFacingMessage.runtimeBusy) }
        isInstalling = true
        defer { isInstalling = false }
        guard Self.isCompatibleHardware else { throw CrisperRuntimeError.incompatibleHardware }
        guard let requirementsURL = CrisperResources.requirementsURL() else {
            throw CrisperRuntimeError.resourcesMissing
        }
        guard let uvURL = resolveUVURL() else { throw CrisperRuntimeError.uvNotFound }

        do {
            try await RuntimeInstaller.install(root: runtimeRootURL(), uv: uvURL, requirements: requirementsURL,
                version: ReleaseConfig.crisperRuntimeVersion,
                healthArguments: ["-c", "import crisperwhisper, torch; print(crisperwhisper.__version__)"],
                offlineEnvironment: offlineEnvironment())
        } catch {
            throw CrisperRuntimeError.installationFailed(error.localizedDescription)
        }
    }

    func remove() throws {
        guard !isInstalling else { throw CrisperRuntimeError.installationFailed(UserFacingMessage.runtimeBusy) }
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
            guard SnapshotInstallation.isInstalled(model, at: destination) else {
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
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return environment
    }

    private func runtimeRootURL() -> URL {
        if let rootOverride { return rootOverride }
        return applicationSupportURL()
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
        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: timeout
            )
        } catch SubprocessError.timedOut {
            throw CrisperRuntimeError.installationFailed(UserFacingMessage.installationTimedOut)
        }
        guard result.status == 0 else {
            let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CrisperRuntimeError.installationFailed(message)
        }
    }
}

private struct RuntimeInstallationManifest: Codable {
    let version: String
    let installedAt: Date
}
