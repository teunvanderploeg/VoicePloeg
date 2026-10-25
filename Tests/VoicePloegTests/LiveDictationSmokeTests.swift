import AVFoundation
import XCTest
@testable import VoicePloeg

/// Opt-in offline diagnostic using already installed models, never downloads.
/// See Docs/QA.md for the command and an optional custom 16 kHz mono WAV.
@MainActor
final class LiveDictationSmokeTests: XCTestCase {
    func testInstalledModelsWithPauseSeparatedAudio() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelIDs = environment["VOICEPLOEG_LIVE_SMOKE_MODELS"] else {
            throw XCTSkip("Set VOICEPLOEG_LIVE_SMOKE_MODELS to exercise installed models")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let audioURL = environment["VOICEPLOEG_LIVE_SMOKE_WAV"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("Vendor/whisper.cpp/samples/jfk.wav")
        let language = environment["VOICEPLOEG_LIVE_SMOKE_LANGUAGE"] ?? "en"
        let samples = try await Task.detached { try Self.readSamples(audioURL) }.value
        let buffer = LivePhraseBuffer()
        var phrases: [[Float]] = []
        let repeated = samples + [Float](repeating: 0, count: 16_000) + samples
        for start in stride(from: 0, to: repeated.count, by: 1_600) {
            phrases += await buffer.append(Array(repeated[start ..< min(start + 1_600, repeated.count)]))
        }
        phrases += await buffer.finish()
        XCTAssertGreaterThanOrEqual(phrases.count, 2)
        let manager = ModelManager()
        let service = SpeechTranscriptionService(crisperTranscriber: CrisperWhisperTranscriber(runtimeManager: CrisperRuntimeManager()))
        do {
            for id in modelIDs.split(separator: ",").map(String.init) {
                let model = try XCTUnwrap(manager.catalog.first { $0.id == id })
                XCTAssertTrue(manager.isDownloaded(model), "Install \(id) before running the diagnostic")
                let localURL = try manager.localURL(for: model)
                var texts: [String] = []
                var times: [TimeInterval] = []
                for phrase in phrases {
                    let result = try await service.transcribe(TranscriptionRequest(
                        samples: phrase, model: model, localModelURL: localURL,
                        language: language, whisperCLIPath: root.appendingPathComponent("Vendor/whisper.cpp/build/bin/whisper-cli").path
                    ))
                    texts.append(result.text)
                    times.append(result.processingTime)
                }
                XCTAssertTrue(texts.allSatisfy { !$0.isEmpty }, "Each phrase should produce text")
                if environment["VOICEPLOEG_LIVE_SMOKE_WAV"] == nil {
                    XCTAssertTrue(texts.allSatisfy { $0.lowercased().contains("country") })
                }
                print("LIVE_SMOKE \(id): \(phrases.count) phrases, processing seconds \(times), text \(texts)")
            }
        } catch {
            await service.releasePreloadedModels()
            throw error
        }
        await service.releasePreloadedModels()
    }

    nonisolated private static func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw LiveDictationError.unavailable
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw LiveDictationError.unavailable }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
