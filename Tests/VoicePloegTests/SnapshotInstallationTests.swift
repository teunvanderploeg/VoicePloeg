import CryptoKit
import XCTest
@testable import VoicePloeg

@MainActor
final class SnapshotInstallationTests: XCTestCase {
    func testEmptyWeightsAndMalformedManifestAreNotInstalled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelManager(modelsDirectoryURL: root)
        let model = try XCTUnwrap(manager.models(for: .crisperWhisper).first)
        let directory = try manager.localURL(for: model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("model.safetensors"))
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("installation.json"))
        XCTAssertFalse(manager.isDownloaded(model))
    }

    func testVerifiedSnapshotDetectsWeightCorruption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SpeechModelDescriptor(id: "test", backend: .crisperWhisper, displayName: "test", sizeBytes: 1,
            languageSupport: ["nl"], precision: "test", acquisition: .huggingFaceSnapshot(repositoryID: "test/repo", revision: "revision"))
        let header = try JSONSerialization.data(withJSONObject: ["weight": ["dtype": "F32", "shape": [1], "data_offsets": [0, 4]]])
        var length = UInt64(header.count).littleEndian
        var weights = withUnsafeBytes(of: &length) { Data($0) }
        weights.append(header)
        weights.append(Data([0, 0, 0, 0]))
        var files: [String: [String: Any]] = [:]
        for name in SnapshotInstallation.requiredFiles(for: model) {
            let data = name.hasSuffix(".safetensors") ? weights : Data("{}".utf8)
            try data.write(to: root.appendingPathComponent(name))
            files[name] = ["size": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        }
        try JSONSerialization.data(withJSONObject: ["modelID": model.id, "repository": "test/repo", "revision": "revision",
            "runtimeVersion": ReleaseConfig.crisperRuntimeVersion, "files": files])
            .write(to: root.appendingPathComponent("installation.json"))
        let verifier = ModelFileVerifier()
        try await verifier.verifySnapshot(model, at: root)
        weights[weights.count - 1] = 1
        try weights.write(to: root.appendingPathComponent("model.safetensors"), options: .atomic)
        do {
            try await verifier.verifySnapshot(model, at: root)
            XCTFail("Corruption must be rejected")
        } catch ModelManagerError.checksumMismatch {}
    }
}
