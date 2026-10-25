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
    private let rootOverride: URL?

    init(rootURL: URL? = nil) {
        rootOverride = rootURL
    }

    func status() -> CrisperRuntimeStatus {
        guard CrisperRuntimeManager.isCompatibleHardware else { return .incompatibleHardware }
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
        guard CrisperRuntimeManager.isCompatibleHardware else { throw BarkError.incompatibleHardware }
        guard let requirements = BarkResources.url("bark-requirements", extension: "lock"),
              let worker = BarkResources.workerURL() else { throw BarkError.resourcesMissing }
        let uv = [CrisperResources.bundledUVURL(),
                  URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
                  URL(fileURLWithPath: "/usr/local/bin/uv")]
            .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let uv else { throw BarkError.installerMissing }
        let root = rootURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Create the venv at its final location: Python console scripts contain absolute paths.
        // The ready marker is written only after package installation and the health check pass.
        try? FileManager.default.removeItem(at: root.appendingPathComponent("installation.json"))
        var environment = ProcessInfo.processInfo.environment
        environment["UV_PYTHON_INSTALL_DIR"] = root.deletingLastPathComponent().appendingPathComponent("Python").path
        environment["UV_CACHE_DIR"] = root.deletingLastPathComponent().appendingPathComponent("Cache").path
        try await run(uv, ["venv", "--clear", "--python", "3.12", root.appendingPathComponent(".venv").path],
                      environment: environment, timeout: 600)
        try await run(uv, ["pip", "install", "--python", pythonURL().path,
                           "--require-hashes", "--only-binary", ":all:", "-r", requirements.path],
                      environment: environment, timeout: 1_800)
        try await run(pythonURL(), [worker.path, "--health"], environment: offlineEnvironment(), timeout: 60)
        try JSONEncoder().encode(Installation(version: ReleaseConfig.barkRuntimeVersion))
            .write(to: root.appendingPathComponent("installation.json"), options: .atomic)
    }

    func remove() throws {
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
              let variant = variants[model.id], variant.repository == repository, variant.revision == revision,
              let data = try? Data(contentsOf: directory.appendingPathComponent("installation.json")),
              let manifest = try? JSONDecoder().decode(ModelInstallation.self, from: data),
              manifest.modelID == model.id, manifest.repository == repository,
              manifest.revision == revision, manifest.runtimeVersion == ReleaseConfig.barkRuntimeVersion else {
            return false
        }
        return variant.installedFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
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
