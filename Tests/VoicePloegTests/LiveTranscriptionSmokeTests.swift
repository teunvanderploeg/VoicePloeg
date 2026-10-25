import AVFoundation
import XCTest
@testable import VoicePloeg

final class LiveTranscriptionSmokeTests: XCTestCase {
    func testInstalledModelsTranscribePauseSeparatedAudio() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let wavPath = environment["VOICEPLOEG_LIVE_SMOKE_WAV"],
              let modelIDs = environment["VOICEPLOEG_LIVE_SMOKE_MODELS"] else {
            throw XCTSkip("Set VOICEPLOEG_LIVE_SMOKE_WAV and VOICEPLOEG_LIVE_SMOKE_MODELS for real local audio/model validation")
        }
        let samples = try Self.readSamples(URL(fileURLWithPath: wavPath))
        let manager = await ModelManager()
        let catalog = await manager.catalog
        let service = SpeechTranscriptionService(crisperTranscriber: CrisperWhisperTranscriber(runtimeManager: CrisperRuntimeManager()))
        for id in modelIDs.split(separator: ",").map(String.init) {
            let model = try XCTUnwrap(catalog.first { $0.id == id })
            let modelURL = try await manager.localURL(for: model)
            let recorder = ReplayRecording()
            let buffer = LiveDictationBuffer()
            let input = samples + [Float](repeating: 0, count: 16_000) + samples
            var chunks: [[Float]] = []
            var emittedBeforeStop = false
            for offset in stride(from: 0, to: input.count, by: 1_600) {
                await recorder.append(Array(input[offset ..< min(input.count, offset + 1_600)]))
                let ready = await buffer.read(from: recorder)
                if !ready.isEmpty { emittedBeforeStop = true }
                chunks += ready
            }
            chunks += await buffer.read(from: recorder, finishing: true)
            XCTAssertTrue(emittedBeforeStop)
            XCTAssertGreaterThanOrEqual(chunks.count, 2)
            var transcript = LiveTranscriptAccumulator()
            for chunk in chunks {
                let result = try await service.transcribe(TranscriptionRequest(
                    samples: chunk, model: model, localModelURL: modelURL, language: "en",
                    whisperCLIPath: environment["VOICEPLOEG_LIVE_SMOKE_CLI"]
                ))
                _ = transcript.append(result.text)
                print("LIVE SMOKE \(id): \(Double(chunk.count) / 16_000)s audio, \(result.processingTime)s inference: \(result.text)")
            }
            XCTAssertFalse(transcript.text.isEmpty)
            XCTAssertTrue(transcript.text.lowercased().contains("country"), transcript.text)
            await service.releasePreloadedModels()
        }
    }

    private static func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

private actor ReplayRecording: RecordingController {
    private var audio: [Float] = []
    func start() { audio = [] }
    func stop() -> [Float] { audio }
    func append(_ samples: [Float]) { audio += samples }
    func samples(from offset: Int) -> [Float] { Array(audio.dropFirst(offset)) }
}
