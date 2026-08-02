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
        let item = makeItem(sha256: "  AABBCC  ")
        XCTAssertEqual(item.expectedSHA256, "aabbcc")
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
