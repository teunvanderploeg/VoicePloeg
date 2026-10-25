import Foundation

enum BarkError: Error, LocalizedError {
    case englishOnly
    case incompatibleHardware
    case runtimeMissing
    case modelMissing
    case resourcesMissing
    case installerMissing
    case invalidResponse
    case outOfMemory
    case operationFailed(String)
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .englishOnly: return UserFacingMessage.barkEnglishOnly
        case .incompatibleHardware: return UserFacingMessage.barkIncompatibleHardware
        case .runtimeMissing: return UserFacingMessage.barkRuntimeMissing
        case .modelMissing: return UserFacingMessage.barkModelMissing
        case .resourcesMissing: return UserFacingMessage.barkResourcesMissing
        case .installerMissing: return UserFacingMessage.barkInstallerMissing
        case .invalidResponse: return UserFacingMessage.barkInvalidResponse
        case .outOfMemory: return UserFacingMessage.barkOutOfMemory
        case let .operationFailed(message): return UserFacingMessage.barkOperationFailed(message)
        case let .timedOut(seconds): return UserFacingMessage.barkTimedOut(seconds)
        }
    }
}

actor BarkRuntimeManager {
    private var isInstalling = false
    private let rootOverride: URL?

    init(rootURL: URL? = nil) {
        rootOverride = rootURL
    }

    func status() -> CrisperRuntimeStatus {
        if isInstalling { return .installing }
        guard CrisperRuntimeManager.isCompatibleHardware else { return .incompatibleHardware }
        try? RuntimeInstaller.recoverInterruptedReplacement(at: rootURL())
        guard FileManager.default.isExecutableFile(atPath: pythonURL().path),
              let data = try? Data(contentsOf: rootURL().appendingPathComponent("installation.json")),
              let manifest = try? JSONDecoder().decode(Installation.self, from: data),
              manifest.version == ReleaseConfig.barkRuntimeVersion else { return .notInstalled }
        return .ready(version: ReleaseConfig.barkRuntimeVersion)
    }

    func pythonExecutableURL() throws -> URL {
        guard case .ready = status() else { throw BarkError.runtimeMissing }
        return pythonURL()
    }

    func install() async throws {
        guard !isInstalling else { throw CrisperRuntimeError.installationFailed(UserFacingMessage.runtimeBusy) }
        isInstalling = true
        defer { isInstalling = false }
        guard CrisperRuntimeManager.isCompatibleHardware else { throw BarkError.incompatibleHardware }
        guard let requirements = BarkResources.url("bark-requirements", extension: "lock"),
              let worker = BarkResources.workerURL() else { throw BarkError.resourcesMissing }
        let uv = [CrisperResources.bundledUVURL(),
                  URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
                  URL(fileURLWithPath: "/usr/local/bin/uv")]
            .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let uv else { throw BarkError.installerMissing }
        try await RuntimeInstaller.install(root: rootURL(), uv: uv, requirements: requirements,
            version: ReleaseConfig.barkRuntimeVersion, healthArguments: [worker.path, "--health"],
            offlineEnvironment: offlineEnvironment())
    }

    func remove() throws {
        guard !isInstalling else { throw CrisperRuntimeError.installationFailed(UserFacingMessage.runtimeBusy) }
        if FileManager.default.fileExists(atPath: rootURL().path) {
            try FileManager.default.removeItem(at: rootURL())
        }
    }

    func installModel(_ model: SpeechModelDescriptor, destination: URL) async throws {
        guard model.backend == .bark,
              case let .huggingFaceSnapshot(repository, revision) = model.acquisition else {
            throw ModelManagerError.unsupportedAcquisition
        }
        guard let worker = BarkResources.workerURL() else { throw BarkError.resourcesMissing }
        try await run(pythonExecutableURL(), [worker.path, "--install-model",
            "--repository", repository, "--revision", revision,
            "--destination", destination.path, "--model-id", model.id,
            "--runtime-version", ReleaseConfig.barkRuntimeVersion],
            environment: ProcessInfo.processInfo.environment, timeout: 7_200)
    }

    nonisolated func offlineEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_DATASETS_OFFLINE",
                    "HF_HUB_DISABLE_TELEMETRY", "DO_NOT_TRACK"] {
            environment[key] = "1"
        }
        environment["TOKENIZERS_PARALLELISM"] = "false"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return environment
    }

    private func rootURL() -> URL {
        if let rootOverride { return rootOverride }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("VoicePloeg/BarkRuntime/\(ReleaseConfig.barkRuntimeVersion)")
    }

    private func pythonURL() -> URL { rootURL().appendingPathComponent(".venv/bin/python") }

    private func run(_ executable: URL, _ arguments: [String], environment: [String: String],
                     timeout: TimeInterval) async throws {
        do {
            let result = try await SubprocessRunner.run(executable: executable, arguments: arguments,
                                                        environment: environment, timeout: timeout)
            guard result.status == 0 else { throw BarkError.operationFailed(result.standardError) }
        } catch SubprocessError.timedOut {
            throw BarkError.timedOut(timeout)
        }
    }

    private struct Installation: Codable {
        let version: String
    }
}

enum BarkResources {
    private static let variants: [String: Variant] = {
        guard let url = url("bark-model-files", extension: "json"),
              let data = try? Data(contentsOf: url),
              let variants = try? JSONDecoder().decode([String: Variant].self, from: data) else { return [:] }
        return variants
    }()

    static func requiredModelFiles(for model: SpeechModelDescriptor) -> [String] {
        variants[model.id]?.installedFiles ?? []
    }

    static func isInstalled(_ model: SpeechModelDescriptor, at directory: URL) -> Bool {
        guard case let .huggingFaceSnapshot(repository, revision) = model.acquisition,
              let variant = variants[model.id], variant.repository == repository, variant.revision == revision else { return false }
        return SnapshotInstallation.isInstalled(model, at: directory)
    }

    private struct Variant: Decodable, Sendable {
        let repository: String
        let revision: String
        let installedFiles: [String]
    }

    private struct ModelInstallation: Decodable {
        let modelID: String
        let repository: String
        let revision: String
        let runtimeVersion: String
    }

    static func workerURL() -> URL? { url("bark_worker", extension: "py") }

    static func url(_ name: String, extension ext: String) -> URL? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        return bundle.url(forResource: name, withExtension: ext, subdirectory: "BarkWorker")
            ?? bundle.url(forResource: name, withExtension: ext)
    }
}
