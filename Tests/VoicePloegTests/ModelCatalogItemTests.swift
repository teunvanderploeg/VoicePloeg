import XCTest
@testable import VoicePloeg

final class ModelCatalogItemTests: XCTestCase {
    @MainActor
    func testCatalogContainsFourPinnedCrisperModels() {
        let models = ModelManager().models(for: .crisperWhisper)
        XCTAssertEqual(models.count, 4)
        for model in models {
            guard case let .huggingFaceSnapshot(_, revision) = model.acquisition else {
                return XCTFail("Expected Hugging Face snapshot")
            }
            XCTAssertEqual(revision.count, 40)
            XCTAssertFalse(model.languageSupport.contains("auto"))
        }
    }

    func testExpectedSHA256ReturnsNilForUnverified() {
        let item = makeItem(sha256: "UNVERIFIED")
        XCTAssertNil(item.expectedSHA256)
    }

    func testExpectedSHA256NormalizesValue() {
        let item = makeItem(sha256: "  " + String(repeating: "AABBCCDD", count: 8) + "  ")
        XCTAssertEqual(item.expectedSHA256, String(repeating: "aabbccdd", count: 8))
    }

    @MainActor
    func testEnglishModelsRejectDutchAndAuto() throws {
        let model = try XCTUnwrap(ModelManager().model(id: "ggml-base.en-q5_1", backend: .whisperCpp))
        XCTAssertTrue(model.supports(language: "en"))
        XCTAssertFalse(model.supports(language: "auto"))
        XCTAssertFalse(model.supports(language: "nl"))
    }

    @MainActor
    func testMultilingualModelsAllowDutchAndCrisperRejectsAuto() throws {
        let manager = ModelManager()
        let whisper = try XCTUnwrap(manager.model(id: "ggml-base-q5_1", backend: .whisperCpp))
        XCTAssertTrue(whisper.supports(language: "nl"))
        let crisper = try XCTUnwrap(manager.models(for: .crisperWhisper).first)
        XCTAssertTrue(crisper.supports(language: "nl"))
        XCTAssertFalse(crisper.supports(language: "auto"))
    }

    private func makeItem(sha256: String) -> ModelCatalogItem {
        ModelCatalogItem(
            id: "test",
            displayName: "Test",
            downloadURL: "https://example.com/model.bin",
            sha256: sha256,
            sizeBytes: 1,
            languageSupport: ["en"],
            quantization: "q5_1"
        )
    }
}
