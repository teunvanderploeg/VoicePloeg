import XCTest
@testable import VoicePloeg

final class AppStateTests: XCTestCase {
    func testIdleStateMetadata() {
        XCTAssertEqual(AppState.idle.title, "Idle")
        XCTAssertEqual(AppState.idle.symbolName, "mic")
    }

    func testListeningStateMetadata() {
        let state = AppState.listening(startedAt: .init(timeIntervalSince1970: 0))
        XCTAssertEqual(state.title, "Listening")
        XCTAssertEqual(state.symbolName, "waveform.circle.fill")
    }

    func testErrorStateTitleContainsMessage() {
        let state = AppState.error(message: "boom")
        XCTAssertEqual(state.title, "Error: boom")
        XCTAssertEqual(state.symbolName, "exclamationmark.triangle.fill")
    }
}
