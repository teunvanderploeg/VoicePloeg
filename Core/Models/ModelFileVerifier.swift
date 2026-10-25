import CryptoKit
import Foundation

actor ModelFileVerifier {
    private struct Verification: Equatable {
        let size: UInt64
        let modifiedAt: Date?
        let checksum: String
    }

    private var verifiedFiles: [URL: Verification] = [:]

    func verifySnapshot(_ model: SpeechModelDescriptor, at directory: URL) throws {
        guard SnapshotInstallation.isInstalled(model, at: directory),
              let manifest = SnapshotInstallation.read(model, at: directory) else {
            throw ModelManagerError.incompleteInstallation
        }
        for name in SnapshotInstallation.requiredFiles(for: model) where name.hasSuffix(".json") {
            try Task.checkCancellation()
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
                throw ModelManagerError.incompleteInstallation
            }
        }
        // Existing installations predate per-file hashes. Validate their weight header
        // without loading gigabytes onto the UI actor. New installs also verify hashes.
        let weights = directory.appendingPathComponent("model.safetensors")
        let handle = try FileHandle(forReadingFrom: weights)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 8) ?? Data()
        guard prefix.count == 8 else { throw ModelManagerError.incompleteInstallation }
        let length = prefix.enumerated().reduce(UInt64.zero) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard length > 0, length <= 100 * 1_024 * 1_024,
              let header = try handle.read(upToCount: Int(length)), header.count == Int(length),
              let entries = try JSONSerialization.jsonObject(with: header) as? [String: Any],
              entries.keys.contains(where: { $0 != "__metadata__" }) else {
            throw ModelManagerError.incompleteInstallation
        }
        let fileSize = try handle.seekToEnd()
        for (name, entry) in entries where name != "__metadata__" {
            guard let tensor = entry as? [String: Any], let offsets = tensor["data_offsets"] as? [UInt64],
                  offsets.count == 2, offsets[0] <= offsets[1], fileSize >= 8 + length,
                  offsets[1] <= fileSize - 8 - length else { throw ModelManagerError.incompleteInstallation }
        }
        for (name, record) in manifest.files ?? [:] {
            try Task.checkCancellation()
            guard SnapshotInstallation.isSafeRelativePath(name) else { throw ModelManagerError.incompleteInstallation }
            let descriptor = SpeechModelDescriptor(id: name, displayName: name, sizeBytes: record.size,
                languageSupport: [], precision: "", acquisition: .singleFile(url: directory, sha256: record.sha256))
            try verify(descriptor, at: directory.appendingPathComponent(name))
        }
    }

    func verify(_ model: SpeechModelDescriptor, at url: URL) throws {
        try Task.checkCancellation()
        guard let expected = model.expectedSHA256 else { throw ModelManagerError.checksumMissing }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size == UInt64(max(0, model.sizeBytes)) else { throw ModelManagerError.sizeMismatch }
        let candidate = Verification(
            size: size,
            modifiedAt: attributes[.modificationDate] as? Date,
            checksum: expected
        )
        guard verifiedFiles[url] != candidate else { return }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw ModelManagerError.checksumMismatch }
        verifiedFiles[url] = candidate
    }
}
