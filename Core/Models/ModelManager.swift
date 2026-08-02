import CryptoKit
import Foundation

enum SpeechBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case whisperCpp
    case crisperWhisper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperCpp:
            return "whisper.cpp"
        case .crisperWhisper:
            return "CrisperWhisper 2.0"
        }
    }
}

enum ModelAcquisition: Codable, Equatable, Sendable {
    case singleFile(url: URL, sha256: String?)
    case huggingFaceSnapshot(repositoryID: String, revision: String)
}

struct SpeechModelDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let backend: SpeechBackend
    let displayName: String
    let sizeBytes: Int64
    let languageSupport: [String]
    let precision: String
    let acquisition: ModelAcquisition
    let licenseIdentifier: String

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var expectedSHA256: String? {
        guard case let .singleFile(_, sha256) = acquisition, let sha256 else { return nil }
        let normalized = sha256.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized.uppercased() == "UNVERIFIED" {
            return nil
        }
        return normalized.lowercased()
    }

    var quantization: String { precision }

    init(
        id: String,
        backend: SpeechBackend = .whisperCpp,
        displayName: String,
        sizeBytes: Int64,
        languageSupport: [String],
        precision: String,
        acquisition: ModelAcquisition,
        licenseIdentifier: String = "unknown"
    ) {
        self.id = id
        self.backend = backend
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.languageSupport = languageSupport
        self.precision = precision
        self.acquisition = acquisition
        self.licenseIdentifier = licenseIdentifier
    }

    // Compatibility initializer for existing callers and tests.
    init(
        id: String,
        displayName: String,
        downloadURL: String,
        sha256: String,
        sizeBytes: Int64,
        languageSupport: [String],
        quantization: String
    ) {
        self.init(
            id: id,
            displayName: displayName,
            sizeBytes: sizeBytes,
            languageSupport: languageSupport,
            precision: quantization,
            acquisition: .singleFile(
                url: URL(string: downloadURL) ?? URL(fileURLWithPath: downloadURL),
                sha256: sha256
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case backend
        case displayName
        case sizeBytes
        case languageSupport
        case precision
        case quantization
        case licenseIdentifier
        case downloadURL
        case sha256
        case repositoryID
        case revision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        backend = try container.decodeIfPresent(SpeechBackend.self, forKey: .backend) ?? .whisperCpp
        displayName = try container.decode(String.self, forKey: .displayName)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        languageSupport = try container.decode([String].self, forKey: .languageSupport)
        precision = try container.decodeIfPresent(String.self, forKey: .precision)
            ?? container.decode(String.self, forKey: .quantization)
        licenseIdentifier = try container.decodeIfPresent(String.self, forKey: .licenseIdentifier) ?? "unknown"

        if let repositoryID = try container.decodeIfPresent(String.self, forKey: .repositoryID) {
            let revision = try container.decode(String.self, forKey: .revision)
            acquisition = .huggingFaceSnapshot(repositoryID: repositoryID, revision: revision)
        } else {
            let downloadURL = try container.decode(String.self, forKey: .downloadURL)
            guard let url = URL(string: downloadURL) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .downloadURL,
                    in: container,
                    debugDescription: "Invalid model download URL"
                )
            }
            acquisition = .singleFile(
                url: url,
                sha256: try container.decodeIfPresent(String.self, forKey: .sha256)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(backend, forKey: .backend)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encode(languageSupport, forKey: .languageSupport)
        try container.encode(precision, forKey: .precision)
        try container.encode(licenseIdentifier, forKey: .licenseIdentifier)
        switch acquisition {
        case let .singleFile(url, sha256):
            try container.encode(url.absoluteString, forKey: .downloadURL)
            try container.encodeIfPresent(sha256, forKey: .sha256)
        case let .huggingFaceSnapshot(repositoryID, revision):
            try container.encode(repositoryID, forKey: .repositoryID)
            try container.encode(revision, forKey: .revision)
        }
    }
}

typealias ModelCatalogItem = SpeechModelDescriptor

enum ModelManagerError: Error, LocalizedError {
    case catalogNotFound
    case invalidCatalog
    case invalidDownloadURL
    case checksumMismatch
    case unsupportedAcquisition
    case incompleteInstallation

    var errorDescription: String? {
        switch self {
        case .catalogNotFound:
            return "Model catalog not found"
        case .invalidCatalog:
            return "Model catalog could not be parsed"
        case .invalidDownloadURL:
            return "Model download URL is invalid"
        case .checksumMismatch:
            return "Downloaded model failed checksum verification"
        case .unsupportedAcquisition:
            return "The selected model requires a runtime that is not ready"
        case .incompleteInstallation:
            return "The selected model installation is incomplete"
        }
    }
}

@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var catalog: [SpeechModelDescriptor] = []

    private let fileManager: FileManager
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let loaded = try? loadCatalog() {
            catalog = loaded
        }
    }

    func loadCatalog() throws -> [SpeechModelDescriptor] {
        #if SWIFT_PACKAGE
        let resourceBundle = Bundle.module
        #else
        let resourceBundle = Bundle.main
        #endif

        guard let url = resourceBundle.url(forResource: "ModelCatalog", withExtension: "json") else {
            throw ModelManagerError.catalogNotFound
        }

        do {
            return try decoder.decode([SpeechModelDescriptor].self, from: Data(contentsOf: url))
        } catch {
            throw ModelManagerError.invalidCatalog
        }
    }

    func refreshCatalog() throws {
        catalog = try loadCatalog()
    }

    func models(for backend: SpeechBackend) -> [SpeechModelDescriptor] {
        catalog.filter { $0.backend == backend }
    }

    func model(id: String, backend: SpeechBackend) -> SpeechModelDescriptor? {
        catalog.first { $0.id == id && $0.backend == backend }
    }

    func modelsDirectory() throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let path = appSupport
            .appendingPathComponent("VoicePloeg", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)

        if !fileManager.fileExists(atPath: path.path) {
            try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        }
        return path
    }

    func localURL(for item: SpeechModelDescriptor) throws -> URL {
        switch item.acquisition {
        case .singleFile:
            return try modelsDirectory().appendingPathComponent("\(item.id).bin")
        case let .huggingFaceSnapshot(_, revision):
            return try modelsDirectory()
                .appendingPathComponent("CrisperWhisper", isDirectory: true)
                .appendingPathComponent(item.id, isDirectory: true)
                .appendingPathComponent(revision, isDirectory: true)
        }
    }

    func isDownloaded(_ item: SpeechModelDescriptor) -> Bool {
        guard let url = try? localURL(for: item) else { return false }
        switch item.acquisition {
        case .singleFile:
            return fileManager.fileExists(atPath: url.path)
        case .huggingFaceSnapshot:
            return fileManager.fileExists(atPath: url.appendingPathComponent("installation.json").path)
                && fileManager.fileExists(atPath: url.appendingPathComponent("model.safetensors").path)
        }
    }

    func ensureModelAvailable(_ item: SpeechModelDescriptor) async throws -> URL {
        guard case let .singleFile(remoteURL, _) = item.acquisition else {
            if isDownloaded(item) { return try localURL(for: item) }
            throw ModelManagerError.unsupportedAcquisition
        }

        let destinationURL = try localURL(for: item)
        if fileManager.fileExists(atPath: destinationURL.path) {
            if try verifyChecksumIfNeeded(item: item, at: destinationURL) {
                return destinationURL
            }
            try? fileManager.removeItem(at: destinationURL)
        }

        let (tempURL, _) = try await URLSession.shared.download(from: remoteURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: tempURL, to: destinationURL)

        guard try verifyChecksumIfNeeded(item: item, at: destinationURL) else {
            try? fileManager.removeItem(at: destinationURL)
            throw ModelManagerError.checksumMismatch
        }
        return destinationURL
    }

    func removeModel(_ item: SpeechModelDescriptor) throws {
        let url = try localURL(for: item)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func verifyChecksumIfNeeded(item: SpeechModelDescriptor, at fileURL: URL) throws -> Bool {
        guard let expected = item.expectedSHA256 else { return true }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data)
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        return expected == actual
    }
}
