import CryptoKit
import Foundation

struct ModelCatalogItem: Codable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let downloadURL: String
    let sha256: String
    let sizeBytes: Int64
    let languageSupport: [String]
    let quantization: String

    var remoteURL: URL? {
        URL(string: downloadURL)
    }

    var expectedSHA256: String? {
        let normalized = sha256.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized.uppercased() == "UNVERIFIED" {
            return nil
        }
        return normalized.lowercased()
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum ModelManagerError: Error, LocalizedError {
    case catalogNotFound
    case invalidCatalog
    case invalidDownloadURL
    case checksumMismatch

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
        }
    }
}

@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var catalog: [ModelCatalogItem] = []

    private let fileManager = FileManager.default
    private let decoder = JSONDecoder()

    init() {
        if let loaded = try? loadCatalog() {
            catalog = loaded
        }
    }

    func loadCatalog() throws -> [ModelCatalogItem] {
        #if SWIFT_PACKAGE
        let resourceBundle = Bundle.module
        #else
        let resourceBundle = Bundle.main
        #endif

        guard let url = resourceBundle.url(forResource: "ModelCatalog", withExtension: "json") else {
            throw ModelManagerError.catalogNotFound
        }

        let data = try Data(contentsOf: url)
        do {
            let catalog = try decoder.decode([ModelCatalogItem].self, from: data)
            return catalog
        } catch {
            throw ModelManagerError.invalidCatalog
        }
    }

    func refreshCatalog() throws {
        catalog = try loadCatalog()
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

    func localURL(for item: ModelCatalogItem) throws -> URL {
        try modelsDirectory().appendingPathComponent("\(item.id).bin", isDirectory: false)
    }

    func isDownloaded(_ item: ModelCatalogItem) -> Bool {
        guard let url = try? localURL(for: item) else {
            return false
        }
        return fileManager.fileExists(atPath: url.path)
    }

    func ensureModelAvailable(_ item: ModelCatalogItem) async throws -> URL {
        let destinationURL = try localURL(for: item)
        if fileManager.fileExists(atPath: destinationURL.path) {
            if try verifyChecksumIfNeeded(item: item, at: destinationURL) {
                return destinationURL
            }
            try? fileManager.removeItem(at: destinationURL)
        }

        guard let remoteURL = item.remoteURL else {
            throw ModelManagerError.invalidDownloadURL
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

    private func verifyChecksumIfNeeded(item: ModelCatalogItem, at fileURL: URL) throws -> Bool {
        guard let expected = item.expectedSHA256 else {
            return true
        }

        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data)
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        return expected == actual
    }
}
