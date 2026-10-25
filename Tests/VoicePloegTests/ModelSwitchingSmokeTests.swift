import XCTest
@testable import VoicePloeg

@MainActor
final class ModelSwitchingSmokeTests: XCTestCase {
    func testRapidSwitchesCancelAndReleaseInstalledModelWorkers() async throws {
        guard let ids = ProcessInfo.processInfo.environment["VOICEPLOEG_MODEL_SWITCH_SMOKE"] else {
            throw XCTSkip("Set VOICEPLOEG_MODEL_SWITCH_SMOKE to two installed model IDs")
        }
        let manager = ModelManager()
        let models = try ids.split(separator: ",").map { id in
            let model = try XCTUnwrap(manager.catalog.first { $0.id == String(id) })
            XCTAssertTrue(manager.isDownloaded(model))
            return (model, try manager.localURL(for: model))
        }
        XCTAssertGreaterThanOrEqual(models.count, 2)
        let service = SpeechTranscriptionService(crisperTranscriber: CrisperWhisperTranscriber(runtimeManager: CrisperRuntimeManager()))
        var warmup: Task<Void, Error>?
        do {
            for index in 0 ..< 12 {
                warmup?.cancel()
                _ = await warmup?.result
                await service.releasePreloadedModels()
                let (model, url) = models[index % models.count]
                warmup = Task { try await service.preloadModel(at: url, backend: model.backend) }
                try await Task.sleep(for: .milliseconds(120))
            }
            warmup?.cancel()
            _ = await warmup?.result
            // Both backends must still be usable after cancelling real model loads.
            for (model, url) in models {
                try await service.preloadModel(at: url, backend: model.backend)
            }
        } catch {
            warmup?.cancel()
            _ = await warmup?.result
            await service.releasePreloadedModels()
            throw error
        }
        await service.releasePreloadedModels()
    }
}
