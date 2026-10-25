import XCTest
@testable import VoicePloeg

final class LivePhraseSegmenterTests: XCTestCase {
    func testShortWordIsKeptAndPartialFrameAtStopIsPreserved() {
        var shortWord = LivePhraseSegmenter()
        XCTAssertEqual(shortWord.append(speech(0.12) + silence(0.8)).count, 1)
        var partial = LivePhraseSegmenter()
        let input = speech(0.171)
        XCTAssertTrue(partial.append(input).isEmpty)
        XCTAssertEqual(partial.finish().first?.count, input.count)
    }

    func testTinyTailAfterForcedBoundaryIsNotDropped() {
        var segmenter = LivePhraseSegmenter()
        let input = speech(15.04)
        let output = segmenter.append(input) + segmenter.finish()
        XCTAssertEqual(output.count, 2)
        XCTAssertEqual(output.flatMap { $0 }.count, input.count)
    }

    func testPauseEmitsOnePhraseAndFinishDoesNotRepeatIt() {
        var segmenter = LivePhraseSegmenter()
        XCTAssertTrue(segmenter.append(speech(0.5)).isEmpty)
        XCTAssertTrue(segmenter.append(silence(0.7)).isEmpty)
        XCTAssertEqual(segmenter.append(silence(0.1)).count, 1)
        XCTAssertTrue(segmenter.finish().isEmpty)
    }

    func testSilenceQuietNoiseDCBiasAndClicksDoNotProducePhrases() {
        for input in [silence(2), speech(2, amplitude: 0.001), [Float](repeating: 0.05, count: 32_000),
                      speech(0.04) + silence(1)] {
            var segmenter = LivePhraseSegmenter()
            XCTAssertTrue(segmenter.append(input).isEmpty)
            XCTAssertTrue(segmenter.finish().isEmpty)
        }
    }

    func testShortPauseKeepsSpeechTogetherAndStopFlushesTailOnce() {
        var segmenter = LivePhraseSegmenter()
        XCTAssertTrue(segmenter.append(speech(0.3) + silence(0.3) + speech(0.3)).isEmpty)
        XCTAssertEqual(segmenter.finish().count, 1)
        XCTAssertTrue(segmenter.finish().isEmpty)
    }

    func testArbitraryCaptureBufferBoundariesProduceIdenticalPhrases() {
        let input = silence(0.4) + speech(0.3) + silence(0.9) + speech(0.4)
        var whole = LivePhraseSegmenter()
        var split = LivePhraseSegmenter()
        let expected = whole.append(input) + whole.finish()
        var actual: [[Float]] = []
        for start in stride(from: 0, to: input.count, by: 137) {
            actual += split.append(Array(input[start ..< min(start + 137, input.count)]))
        }
        actual += split.finish()
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.count, 2)
    }

    func testContinuousSpeechIsBoundedWithoutDroppingOrOverlappingAudio() {
        var segmenter = LivePhraseSegmenter()
        let input = speech(32)
        let phrases = segmenter.append(input) + segmenter.finish()
        XCTAssertEqual(phrases.count, 3)
        XCTAssertTrue(phrases.allSatisfy { $0.count <= 15 * 16_000 })
        XCTAssertEqual(phrases.flatMap { $0 }.count, input.count)
    }

    func testQuietSpeechAndTwoConsecutiveIdenticalPhrasesAreKept() {
        var segmenter = LivePhraseSegmenter()
        let phrase = speech(0.3, amplitude: 0.004) + silence(0.9)
        let output = segmenter.append(phrase + phrase) + segmenter.finish()
        XCTAssertEqual(output.count, 2)
        XCTAssertGreaterThan(output[0].map { abs($0) }.max() ?? 0, 0.9)
    }

    private func speech(_ seconds: Double, amplitude: Float = 0.1) -> [Float] {
        (0 ..< Int(seconds * 16_000)).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }
}
