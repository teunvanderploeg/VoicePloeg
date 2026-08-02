import XCTest
@testable import VoicePloeg

final class CrisperWorkerProtocolTests: XCTestCase {
    func testRoundTripsSuccessfulResponse() throws {
        let id = UUID()
        let response = CrisperWorkerResponse(
            id: id,
            status: "ok",
            result: .init(text: "hello", duration: 1, processingTime: 0.5)
        )
        let decoded = try CrisperWorkerCodec.decode(try JSONEncoder().encode(response), expectedID: id)
        XCTAssertEqual(decoded, response)
    }

    func testRejectsMismatchedResponseID() throws {
        let response = CrisperWorkerResponse(id: UUID(), status: "ok", result: .init())
        XCTAssertThrowsError(
            try CrisperWorkerCodec.decode(try JSONEncoder().encode(response), expectedID: UUID())
        ) { error in
            XCTAssertEqual(error as? CrisperWorkerProtocolError, .mismatchedResponseID)
        }
    }

    func testSurfacesTypedWorkerError() throws {
        let id = UUID()
        let response = CrisperWorkerResponse(
            id: id,
            status: "error",
            error: .init(code: "model_load_failed", message: "bad model")
        )
        XCTAssertThrowsError(
            try CrisperWorkerCodec.decode(try JSONEncoder().encode(response), expectedID: id)
        ) { error in
            XCTAssertEqual(
                error as? CrisperWorkerProtocolError,
                .workerError(code: "model_load_failed", message: "bad model")
            )
        }
    }
}
