import XCTest
@testable import VoicePloeg

final class ModelCatalogItemTests: XCTestCase {
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
