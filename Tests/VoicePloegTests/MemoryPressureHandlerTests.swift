import Dispatch
import XCTest
@testable import VoicePloeg

final class MemoryPressureHandlerTests: XCTestCase {
    func testHandlerHopsFromBackgroundQueueToMainActor() async {
        let didRun = await withCheckedContinuation { continuation in
            let handler = AppCoordinator.makeMemoryPressureHandler {
                MainActor.preconditionIsolated()
                continuation.resume(returning: true)
            }

            DispatchQueue.global(qos: .utility).async(execute: handler)
        }

        XCTAssertTrue(didRun)
    }
}
