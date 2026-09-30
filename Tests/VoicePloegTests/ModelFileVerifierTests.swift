import CryptoKit
import XCTest
@testable import VoicePloeg

final class ModelFileVerifierTests: XCTestCase {
    func testValidModelCanBeVerifiedRepeatedly() async throws {
        let data = Data(repeating: 7, count: 2_100_000)
        let url = try makeFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let verifier = ModelFileVerifier()
        let model = descriptor(for: data)
        try await verifier.verify(model, at: url)
        try await verifier.verify(model, at: url)
    }

    func testChangedFileIsReverifiedEvenWhenItsSizeIsUnchanged() async throws {
        let data = Data("good".utf8)
        let url = try makeFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let verifier = ModelFileVerifier()
        let model = descriptor(for: data)
        try await verifier.verify(model, at: url)
        try Data("evil".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        do {
            try await verifier.verify(model, at: url)
            XCTFail("Expected checksum mismatch")
        } catch ModelManagerError.checksumMismatch {}
    }

    func testTruncatedFileIsRejected() async throws {
        let data = Data("model".utf8)
        let url = try makeFile(Data("mod".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try await ModelFileVerifier().verify(descriptor(for: data), at: url)
            XCTFail("Expected size mismatch")
        } catch ModelManagerError.sizeMismatch {}
    }

    func testMissingChecksumIsRejected() async throws {
        let data = Data("model".utf8)
        let url = try makeFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try await ModelFileVerifier().verify(descriptor(for: data, checksum: "UNVERIFIED"), at: url)
            XCTFail("Expected missing checksum")
        } catch ModelManagerError.checksumMissing {}
    }

    private func makeFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    private func descriptor(for data: Data, checksum: String? = nil) -> SpeechModelDescriptor {
        SpeechModelDescriptor(
            id: "test", displayName: "Test", sizeBytes: Int64(data.count),
            languageSupport: ["en"], precision: "fp16",
            acquisition: .singleFile(url: URL(string: "https://example.com/model")!,
                sha256: checksum ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        )
    }
}
