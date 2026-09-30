import CryptoKit
import Foundation

actor ModelFileVerifier {
    private struct Verification: Equatable {
        let size: UInt64
        let modifiedAt: Date?
        let checksum: String
    }

    private var verifiedFiles: [URL: Verification] = [:]

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
