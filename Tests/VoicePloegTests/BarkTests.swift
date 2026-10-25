import XCTest
@testable import VoicePloeg

final class BarkTests: XCTestCase {
    @MainActor
    func testAllThreeBarkVariantsAreSelectableForEnglishOnly() throws {
        let models = ModelManager().models(for: .bark)
        XCTAssertEqual(Set(models.map(\.id)), ["underdog-bark-3", "underdog-bark-3-plus", "underdog-bark-3-pro"])
        for model in models {
            XCTAssertTrue(model.supports(language: "en"))
            XCTAssertFalse(model.supports(language: "nl"))
            XCTAssertFalse(model.supports(language: "auto"))
            XCTAssertEqual(model.licenseIdentifier, "cc-by-4.0")
            XCTAssertFalse(BarkResources.requiredModelFiles(for: model).isEmpty)
            guard case let .huggingFaceSnapshot(_, revision) = model.acquisition else {
                return XCTFail("Expected pinned Bark variant")
            }
            XCTAssertEqual(revision.count, 40)
        }
        let pro = try XCTUnwrap(models.first { $0.id == "underdog-bark-3-pro" })
        XCTAssertEqual(pro.precision, "bf16 MLX")
        XCTAssertFalse(BarkResources.requiredModelFiles(for: pro).contains("model.bark"))
    }

    @MainActor
    func testBarkIsPinnedEnglishOnlyAndMultilingualModelsRemainAvailable() throws {
        let manager = ModelManager()
        let bark = try XCTUnwrap(manager.model(id: ReleaseConfig.defaultBarkModelID, backend: .bark))
        XCTAssertTrue(bark.supports(language: "en"))
        XCTAssertFalse(bark.supports(language: "nl"))
        XCTAssertFalse(bark.supports(language: "auto"))
        XCTAssertEqual(bark.licenseIdentifier, "cc-by-4.0")
        guard case let .huggingFaceSnapshot(repository, revision) = bark.acquisition else {
            return XCTFail("Expected a pinned snapshot")
        }
        XCTAssertEqual(repository, "ConwayResearch/Underdog-Bark-3.0")
        XCTAssertEqual(revision, "85db2ad18ab41e534a222ee253c29191d77ed919")
        XCTAssertTrue(manager.models(for: .whisperCpp).contains { $0.supports(language: "nl") })
        XCTAssertEqual(manager.models(for: .crisperWhisper).count, 4)
    }

    @MainActor
    func testBarkSelectionPersistsIndependentlyWithoutChangingExistingDefault() throws {
        let name = "BarkTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(userDefaults: defaults)
        XCTAssertEqual(settings.selectedTranscriptionBackend, .whisperCpp)
        let whisperID = settings.selectedWhisperModelID
        let crisperID = settings.selectedCrisperModelID
        settings.selectedTranscriptionBackend = .bark
        settings.selectedModelID = "saved-bark"
        let restored = AppSettings(userDefaults: defaults)
        XCTAssertEqual(restored.selectedTranscriptionBackend, .bark)
        XCTAssertEqual(restored.selectedModelID, "saved-bark")
        XCTAssertEqual(restored.selectedWhisperModelID, whisperID)
        XCTAssertEqual(restored.selectedCrisperModelID, crisperID)
    }

    @MainActor
    func testPartialBarkDownloadIsNotUsable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelManager(modelsDirectoryURL: root)
        let model = try XCTUnwrap(manager.models(for: .bark).first)
        let directory = try manager.localURL(for: model)
        XCTAssertTrue(directory.path.contains("/Bark/"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("installation.json"))
        try Data().write(to: directory.appendingPathComponent("model.safetensors"))
        XCTAssertFalse(manager.isDownloaded(model))
        for name in BarkResources.requiredModelFiles(for: model) {
            let url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        XCTAssertFalse(manager.isDownloaded(model))
        guard case let .huggingFaceSnapshot(repository, revision) = model.acquisition else { return }
        try JSONSerialization.data(withJSONObject: ["modelID": model.id, "repository": repository,
            "revision": revision, "runtimeVersion": ReleaseConfig.barkRuntimeVersion])
            .write(to: directory.appendingPathComponent("installation.json"))
        XCTAssertTrue(manager.isDownloaded(model))
    }

    func testBarkRejectsOtherLanguagesBeforeStartingRuntime() async throws {
        let transcriber = BarkTranscriber(runtimeManager: BarkRuntimeManager(rootURL: URL(fileURLWithPath: "/missing-bark")))
        let model = SpeechModelDescriptor(id: "test", backend: .bark, displayName: "test", sizeBytes: 0,
            languageSupport: ["en"], precision: "fp16",
            acquisition: .huggingFaceSnapshot(repositoryID: "test", revision: "test"))
        for language in ["nl", "auto"] {
            do {
                _ = try await transcriber.transcribe(TranscriptionRequest(samples: [0], model: model,
                    localModelURL: URL(fileURLWithPath: "/missing-model"), language: language))
                XCTFail("Expected English-only error")
            } catch BarkError.englishOnly {
                // Language rejection must precede loading Python or accessing model files.
            }
        }
    }

    func testBarkRuntimeRequiresMatchingInstallationVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".venv/bin/python"),
                                                   withDestinationURL: URL(fileURLWithPath: "/usr/bin/python3"))
        let manager = BarkRuntimeManager(rootURL: root)
        try Data("{\"version\":\"old\"}".utf8).write(to: root.appendingPathComponent("installation.json"))
        let staleStatus = await manager.status()
        XCTAssertNotEqual(staleStatus, .ready(version: ReleaseConfig.barkRuntimeVersion))
        try JSONSerialization.data(withJSONObject: ["version": ReleaseConfig.barkRuntimeVersion])
            .write(to: root.appendingPathComponent("installation.json"))
        let status = await manager.status()
        if CrisperRuntimeManager.isCompatibleHardware {
            XCTAssertEqual(status, .ready(version: ReleaseConfig.barkRuntimeVersion))
        } else {
            XCTAssertEqual(status, .incompatibleHardware)
        }
    }

    func testBarkResourcesAreBundledWithoutCollidingWithCrisper() throws {
        let bark = try XCTUnwrap(BarkResources.workerURL())
        XCTAssertNotEqual(bark, CrisperResources.workerURL())
        for (name, ext) in [("bark-requirements", "lock"), ("bark_mlx", "py"),
                            ("bark_loader", "py"), ("bark-model-files", "json"), ("BARK_NOTICE", ""),
                            ("BARK_PLUS_NOTICE", ""), ("BARK_PRO_NOTICE", "")] {
            XCTAssertNotNil(BarkResources.url(name, extension: ext))
        }
    }
}
