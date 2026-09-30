import XCTest
@testable import VoicePloeg

final class AudioCaptureServiceTests: XCTestCase {
    func testNormalizationPreservesQuietSpeechBeforeLoudAudio() {
        let quietSpeech: [Float] = [0.002, -0.002, 0.002, -0.002]
        let samples = [Float](repeating: 0, count: 160) + quietSpeech + [0.8, -0.8]

        let normalized = AudioCaptureService.normalize(samples)

        XCTAssertEqual(normalized.count, samples.count)
        XCTAssertEqual(normalized[160], 0.002 * 0.95 / 0.8, accuracy: 0.000_001)
    }

    func testNormalizationReturnsNoSamplesWhenRecordingIsSilent() {
        let samples = [Float](repeating: 0, count: 160)

        XCTAssertTrue(AudioCaptureService.normalize(samples).isEmpty)
    }
}
