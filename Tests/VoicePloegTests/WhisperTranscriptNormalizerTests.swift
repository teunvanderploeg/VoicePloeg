import XCTest
@testable import VoicePloeg

final class WhisperTranscriptNormalizerTests: XCTestCase {
    func testJoinsLFSeparatedSegmentsWithSingleSpace() {
        let result = WhisperTranscriptNormalizer.normalize("First segment\nSecond segment")

        XCTAssertEqual(result, "First segment Second segment")
    }

    func testJoinsCRLFSeparatedSegmentsWithSingleSpace() {
        let result = WhisperTranscriptNormalizer.normalize("First segment\r\nSecond segment")

        XCTAssertEqual(result, "First segment Second segment")
    }

    func testJoinsMultipleSegments() {
        let result = WhisperTranscriptNormalizer.normalize("One\nTwo\nThree")

        XCTAssertEqual(result, "One Two Three")
    }

    func testIgnoresBlankLinesAndTrimsSegments() {
        let result = WhisperTranscriptNormalizer.normalize("  One  \n\n \r\n\tTwo\t\n")

        XCTAssertEqual(result, "One Two")
    }

    func testPreservesPunctuationAndWordBoundaries() {
        let result = WhisperTranscriptNormalizer.normalize("This is one sentence.\nIs this another? Yes!")

        XCTAssertEqual(result, "This is one sentence. Is this another? Yes!")
    }
}
