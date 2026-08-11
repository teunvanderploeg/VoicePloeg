import Foundation
import XCTest
@testable import VoicePloeg

final class WhisperModelPreloadTests: XCTestCase {
    func testPreloadAcceptsAnExistingModelAndCanBeRepeated() async throws {
        let modelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicePloeg-preload-\(UUID().uuidString).bin")
        try Data(repeating: 0x2A, count: 1_024).write(to: modelURL)
        defer { try? FileManager.default.removeItem(at: modelURL) }

        let transcriber = WhisperCppTranscriber()
        try await transcriber.preloadModel(at: modelURL)
        try await transcriber.preloadModel(at: modelURL)
    }

    func testPreloadRejectsAMissingModel() async {
        let modelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicePloeg-missing-\(UUID().uuidString).bin")

        do {
            try await WhisperCppTranscriber().preloadModel(at: modelURL)
            XCTFail("Expected the missing model to be rejected")
        } catch WhisperTranscriberError.modelNotLoaded {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
