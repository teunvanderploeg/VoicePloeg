import Darwin
import XCTest
@testable import VoicePloeg

final class LocalSpeechWorkerClientTests: XCTestCase {
    func testShutdownAllowsPythonCleanupAfterAcknowledgement() async throws {
        let fixture = try WorkerFixture()
        defer { fixture.cleanup() }
        let client = try fixture.makeClient()
        try await client.shutdown()
        XCTAssertEqual(try String(contentsOf: fixture.marker), "cleaned up")
    }
    func testClosedWorkerPipeCannotTerminateApp() async throws {
        // Exercise the regression with default SIGPIPE handling in a separate test
        // process. A future regression must fail this test, not kill the suite.
        if ProcessInfo.processInfo.environment["VOICEPLOEG_WORKER_PIPE_CHILD"] != "1" {
            var environment = ProcessInfo.processInfo.environment
            environment["VOICEPLOEG_WORKER_PIPE_CHILD"] = "1"
            let result = try await SubprocessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["xctest", "-XCTest", "VoicePloegTests.LocalSpeechWorkerClientTests/testClosedWorkerPipeCannotTerminateApp",
                    Bundle(for: Self.self).bundlePath],
                environment: environment, timeout: 10
            )
            XCTAssertEqual(result.status, 0, String((result.standardOutput + result.standardError).suffix(2_000)))
            return
        }
        let previous = signal(SIGPIPE, SIG_DFL)
        defer { signal(SIGPIPE, previous) }
        let fixture = try WorkerFixture()
        defer { fixture.cleanup() }
        let client = try fixture.makeClient()
        _ = try await client.request(.init(id: UUID(), command: "closeInput"), timeout: 2)
        do {
            _ = try await client.request(.init(id: UUID(), command: "ping"), timeout: 2)
            XCTFail("A closed pipe must report an error")
        } catch {
            // EPIPE must be catchable even though the child is still running.
        }
        try await client.shutdown()
        let running = await client.isRunning()
        XCTAssertFalse(running)
    }

    func testConcurrentRequestsKeepResponsesMatchedToTheirIDs() async throws {
        let fixture = try WorkerFixture()
        defer { fixture.cleanup() }
        let client = try fixture.makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 12 {
                group.addTask {
                    let id = UUID()
                    let response = try await client.request(.init(id: id, command: "slow"), timeout: 2)
                    XCTAssertEqual(response.id, id)
                    XCTAssertEqual(response.result?.text, "slow")
                }
            }
            try await group.waitForAll()
        }
        try await client.shutdown()
    }

    func testShutdownDuringLoadJoinsReaderAndRejectsLaterRequests() async throws {
        let fixture = try WorkerFixture()
        defer { fixture.cleanup() }
        let client = try fixture.makeClient()
        let request = Task { try await client.request(.init(id: UUID(), command: "wait", wavPath: fixture.marker.path), timeout: 5) }
        try await fixture.waitForRequest()
        async let firstShutdown: Void = client.shutdown()
        async let secondShutdown: Void = client.shutdown()
        try await firstShutdown
        try await secondShutdown
        do { _ = try await request.value; XCTFail("Shutdown must stop the pending request") } catch {}
        do {
            _ = try await client.request(.init(id: UUID(), command: "ping"), timeout: 1)
            XCTFail("A closed client must reject new requests")
        } catch {}
    }

    func testCancellingQueuedRequestDoesNotInterruptEarlierRequest() async throws {
        let fixture = try WorkerFixture()
        defer { fixture.cleanup() }
        let client = try fixture.makeClient()
        let first = Task { try await client.request(.init(id: UUID(), command: "slow", wavPath: fixture.marker.path), timeout: 2) }
        try await fixture.waitForRequest()
        let queued = Task { try await client.request(.init(id: UUID(), command: "ping"), timeout: 2) }
        queued.cancel()
        let response = try await first.value
        XCTAssertEqual(response.result?.text, "slow")
        do { _ = try await queued.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch {
            XCTFail("Unexpected error: \(error)")
        }
        _ = try await client.request(.init(id: UUID(), command: "ping"), timeout: 2)
        try await client.shutdown()
    }

    func testCancelledAndTimedOutLoadsStopTheirWorkers() async throws {
        for cancel in [false, true] {
            let fixture = try WorkerFixture()
            defer { fixture.cleanup() }
            let client = try fixture.makeClient()
            let request = Task {
                try await client.request(.init(id: UUID(), command: "wait", wavPath: fixture.marker.path), timeout: cancel ? 5 : 0.1)
            }
            if cancel {
                try await fixture.waitForRequest()
                request.cancel()
            }
            do { _ = try await request.value; XCTFail("Expected the load to stop") } catch {}
            let running = await client.isRunning()
            XCTAssertFalse(running)
            try await client.shutdown()
        }
    }
}

private struct WorkerFixture {
    let directory: URL
    let worker: URL
    let marker: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoicePloeg-WorkerTest-\(UUID().uuidString)")
        worker = directory.appendingPathComponent("worker.py")
        marker = directory.appendingPathComponent("request-started")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        import json, os, sys, time
        for line in sys.stdin:
            request = json.loads(line)
            command = request['command']
            if request.get('wavPath'):
                with open(request['wavPath'], 'w') as marker:
                    marker.write('started')
            if command == 'wait':
                time.sleep(30)
            if command == 'slow':
                time.sleep(0.05)
            if command == 'closeInput':
                os.close(0)
            print(json.dumps({'id': request['id'], 'status': 'ok', 'result': {'text': command}}), flush=True)
            if command == 'closeInput':
                time.sleep(2)
                break
            if command == 'shutdown':
                time.sleep(0.15)
                with open(os.environ['VOICEPLOEG_SHUTDOWN_MARKER'], 'w') as marker:
                    marker.write('cleaned up')
                break
        """.write(to: worker, atomically: true, encoding: .utf8)
    }

    func makeClient() throws -> LocalSpeechWorkerClient {
        var environment = ProcessInfo.processInfo.environment
        environment["VOICEPLOEG_SHUTDOWN_MARKER"] = marker.path
        return try LocalSpeechWorkerClient(pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), workerURL: worker,
            environment: environment)
    }

    func waitForRequest() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
