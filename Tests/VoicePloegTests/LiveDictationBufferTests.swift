import XCTest
@testable import VoicePloeg

final class LiveDictationBufferTests: XCTestCase {
    private func speech(_ seconds: Double, amplitude: Float = 0.025) -> [Float] {
        (0 ..< Int(seconds * 16_000)).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    func testPauseEmitsPhraseBeforeStopAndDoesNotReplayIt() {
        var segmenter = LiveAudioSegmenter()
        XCTAssertTrue(segmenter.append(speech(1)).isEmpty)
        XCTAssertEqual(segmenter.append(silence(0.7)).count, 1)
        XCTAssertTrue(segmenter.append(silence(3), finishing: true).isEmpty)
    }

    func testShortPauseKeepsSentenceTogether() {
        var segmenter = LiveAudioSegmenter()
        XCTAssertTrue(segmenter.append(speech(1) + silence(0.3) + speech(1)).isEmpty)
        let chunks = segmenter.append(silence(0.7))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertGreaterThan(chunks[0].count, 2 * 16_000)
    }

    func testStopFlushesFinalPhraseWithoutTrailingSilence() {
        var segmenter = LiveAudioSegmenter()
        XCTAssertTrue(segmenter.append(speech(0.52)).isEmpty)
        XCTAssertEqual(segmenter.append([], finishing: true).count, 1)
        XCTAssertTrue(segmenter.append([], finishing: true).isEmpty)
    }

    func testSilenceDCAndVeryQuietBackgroundNeverReachModel() {
        for input in [silence(10), speech(4, amplitude: 0.0001), [Float](repeating: 0.05, count: 32_000)] {
            var segmenter = LiveAudioSegmenter()
            XCTAssertTrue(segmenter.append(input, finishing: true).isEmpty)
        }
    }

    func testBriefClickDoesNotBecomeDictation() {
        var segmenter = LiveAudioSegmenter()
        XCTAssertTrue(segmenter.append(speech(0.04) + silence(1), finishing: true).isEmpty)
    }

    func testLongContinuousSpeechIsBoundedAndPreservesAllSamples() {
        var segmenter = LiveAudioSegmenter()
        let input = speech(29)
        let chunks = segmenter.append(input, finishing: true)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 12 * 16_000 })
        XCTAssertEqual(chunks.flatMap { $0 }, input)
    }

    func testIrregularInputBoundariesProduceSameChunks() {
        let input = silence(1) + speech(1) + silence(0.8) + speech(0.43)
        var whole = LiveAudioSegmenter()
        let expected = whole.append(input, finishing: true)
        var incremental = LiveAudioSegmenter()
        var actual: [[Float]] = []
        for offset in stride(from: 0, to: input.count, by: 713) {
            actual += incremental.append(Array(input[offset ..< min(input.count, offset + 713)]))
        }
        actual += incremental.append([], finishing: true)
        XCTAssertEqual(actual, expected)
    }

    func testBacklogProducesOrderedDistinctPhrases() {
        var segmenter = LiveAudioSegmenter()
        let chunks = segmenter.append(speech(1) + silence(1) + speech(2) + silence(1), finishing: true)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertLessThan(chunks[0].count, chunks[1].count)
    }

    func testTranscriptSpacingUnicodeAndIntentionalRepetition() {
        var transcript = LiveTranscriptAccumulator()
        XCTAssertEqual(transcript.append("  Hello world.\n"), "Hello world.")
        XCTAssertEqual(transcript.append("Hello world."), " Hello world.")
        XCTAssertNil(transcript.append(" \n "))
        XCTAssertEqual(transcript.append("Dat is café ☕."), " Dat is café ☕.")
        XCTAssertEqual(transcript.text, "Hello world. Hello world. Dat is café ☕.")
    }
}
