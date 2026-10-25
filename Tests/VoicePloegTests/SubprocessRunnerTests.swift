import Darwin
import XCTest
@testable import VoicePloeg

final class SubprocessRunnerTests: XCTestCase {
    func testTimeoutAndCancellationStopDescendants() async throws {
        for cancel in [false, true] {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: marker) }
            let task = Task {
                try await SubprocessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "sleep 30 & child=$!; echo $child > \"$1\"; wait", "test", marker.path],
                    timeout: cancel ? 5 : 0.2)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let pid = try XCTUnwrap(Int32(String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines)))
            defer { kill(pid, SIGKILL) }
            if cancel { task.cancel() }
            do { _ = try await task.value; XCTFail("Expected interruption") } catch {}
            let exitDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while kill(pid, 0) == 0, ContinuousClock.now < exitDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(kill(pid, 0), -1, "A descendant survived its owner")
        }
    }

    func testLargeOutputCannotBlockProcessAndLogsAreBounded() async throws {
        let result = try await SubprocessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 2097152 /dev/zero; head -c 2097152 /dev/zero >&2"],
            timeout: 5
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardOutput.utf8.count, 1_024 * 1_024)
        XCTAssertEqual(result.standardError.utf8.count, 1_024 * 1_024)
    }

    func testTimeoutStopsChildProcess() async throws {
        try await assertProcessStops(cancel: false)
    }

    func testCancellationStopsChildProcess() async throws {
        try await assertProcessStops(cancel: true)
    }

    private func assertProcessStops(cancel: Bool) async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let task = Task {
            try await SubprocessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "test", pidFile.path],
                timeout: cancel ? 5 : 0.2
            )
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        if cancel { task.cancel() }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation or timeout")
        } catch is CancellationError {
            XCTAssertTrue(cancel)
        } catch SubprocessError.timedOut {
            XCTAssertFalse(cancel)
        }
        let exitDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while kill(pid, 0) == 0, ContinuousClock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
