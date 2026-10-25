import Foundation

struct SnapshotInstallation: Decodable, Sendable {
    struct FileRecord: Decodable, Sendable {
        let size: Int64
        let sha256: String
    }

    let modelID: String
    let repository: String
    let revision: String
    let runtimeVersion: String
    let files: [String: FileRecord]?

    static func requiredFiles(for model: SpeechModelDescriptor) -> [String] {
        if model.backend == .bark { return BarkResources.requiredModelFiles(for: model) }
        return ["model.safetensors", "config.json", "preprocessor_config.json", "tokenizer.json", "tokenizer_config.json"]
    }

    static func read(_ model: SpeechModelDescriptor, at directory: URL) -> SnapshotInstallation? {
        guard case let .huggingFaceSnapshot(repository, revision) = model.acquisition,
              let data = try? Data(contentsOf: directory.appendingPathComponent("installation.json")),
              let manifest = try? JSONDecoder().decode(Self.self, from: data),
              manifest.modelID == model.id, manifest.repository == repository, manifest.revision == revision,
              manifest.runtimeVersion == (model.backend == .bark ? ReleaseConfig.barkRuntimeVersion : ReleaseConfig.crisperRuntimeVersion)
        else { return nil }
        return manifest
    }

    static func isInstalled(_ model: SpeechModelDescriptor, at directory: URL) -> Bool {
        guard let manifest = read(model, at: directory) else { return false }
        let required = requiredFiles(for: model)
        guard !required.isEmpty else { return false }
        if let files = manifest.files {
            guard required.allSatisfy({ files[$0] != nil }), files.keys.allSatisfy(isSafeRelativePath) else { return false }
        }
        return required.allSatisfy { name in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            guard attributes?[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes?[.size] as? NSNumber)?.int64Value, size > 0 else { return false }
            return manifest.files?[name].map { $0.size == size } ?? true
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
}
