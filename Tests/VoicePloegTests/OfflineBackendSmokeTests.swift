import AVFoundation
import XCTest
@testable import VoicePloeg

/// Opt-in, local-only recognition and normalization measurements. Never records or downloads.
@MainActor
final class OfflineBackendSmokeTests: XCTestCase {
    private struct Corpus: Decodable { let cases: [Example] }
    private struct Example: Decodable {
        let id: String
        let wavPath: String
        let language: String
        let reference: String
        let maximumWordErrorRate: Double?
    }

    func testInstalledBackendsAndAudioNormalization() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let selected = environment["VOICEPLOEG_OFFLINE_SMOKE_MODELS"] else {
            throw XCTSkip("Set VOICEPLOEG_OFFLINE_SMOKE_MODELS to installed catalog IDs")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let corpusURL = environment["VOICEPLOEG_DICTATION_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("Tests/Fixtures/dictation-corpus.example.json")
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpusURL))
        let manager = ModelManager()
        let service = SpeechTranscriptionService(crisperTranscriber: CrisperWhisperTranscriber(runtimeManager: CrisperRuntimeManager()))
        do {
            for id in selected.split(separator: ",").map(String.init) {
                let model = try XCTUnwrap(manager.catalog.first { $0.id == id })
                let modelURL = try await manager.verifiedInstalledURL(for: model)
                let started = ContinuousClock.now
                try await service.preloadModel(at: modelURL, backend: model.backend)
                let load = DictationTimings.seconds(started.duration(to: .now))
                for example in corpus.cases where model.supports(language: example.language) {
                    let wav = URL(fileURLWithPath: example.wavPath, relativeTo: corpusURL.deletingLastPathComponent()).standardizedFileURL
                    let samples = try await Task.detached { try Self.samples(at: wav) }.value
                    for variant in ["raw", "normalized", "quiet-normalized"] {
                        let input: [Float]
                        switch variant {
                        case "raw": input = samples
                        case "normalized": input = AudioCaptureService.normalize(samples)
                        default: input = AudioCaptureService.normalize(samples.map { $0 * 0.05 })
                        }
                        let result = try await service.transcribe(TranscriptionRequest(samples: input, model: model,
                            localModelURL: modelURL, language: example.language,
                            whisperCLIPath: root.appendingPathComponent("Vendor/whisper.cpp/build/bin/whisper-cli").path))
                        let wer = Self.wordErrorRate(reference: example.reference, hypothesis: result.text)
                        if let limit = example.maximumWordErrorRate { XCTAssertLessThanOrEqual(wer, limit, "\(id), \(example.id), \(variant): \(result.text)") }
                        let observation: [String: Any] = ["model": id, "case": example.id, "language": example.language,
                            "variant": variant, "loadSeconds": load, "processingSeconds": result.processingTime,
                            "audioSeconds": result.duration, "wordErrorRate": wer, "text": result.text]
                        let data = try JSONSerialization.data(withJSONObject: observation, options: .sortedKeys)
                        print("DICTATION_BENCHMARK \(String(decoding: data, as: UTF8.self))")
                    }
                }
                await service.releasePreloadedModels()
            }
        } catch {
            await service.releasePreloadedModels()
            throw error
        }
    }

    nonisolated private static func samples(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioCaptureError.engineNotReady
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData?[0] else { throw AudioCaptureError.engineNotReady }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    nonisolated private static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let expected = reference.lowercased().split { !$0.isLetter && !$0.isNumber }
        let actual = hypothesis.lowercased().split { !$0.isLetter && !$0.isNumber }
        var previous = Array(0 ... actual.count)
        for (index, word) in expected.enumerated() {
            var row = [index + 1]
            for (column, candidate) in actual.enumerated() {
                row.append(min(row[column] + 1, previous[column + 1] + 1, previous[column] + (word == candidate ? 0 : 1)))
            }
            previous = row
        }
        return Double(previous[actual.count]) / Double(max(1, expected.count))
    }
}
