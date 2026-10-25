import XCTest
@testable import VoicePloeg

@MainActor
final class LiveDictationSessionTests: XCTestCase {
    func testPhrasesAreInsertedBeforeStopAndSavedAsOneTranscript() async throws {
        let fixture = LiveSessionFixture(texts: ["Hello.", "How are you?"])
        await fixture.recorder.feed(phrase())
        await fixture.session.poll()
        try await waitUntil { fixture.output.insertions.count == 1 }
        XCTAssertEqual(fixture.session.transcript, "Hello.")
        XCTAssertEqual(fixture.output.insertions, ["Hello."])
        await fixture.recorder.feed(speech()) // No trailing pause: flushed by Stop.
        await fixture.session.finish()
        XCTAssertEqual(fixture.output.insertions, ["Hello.", "How are you?"])
        XCTAssertEqual(fixture.session.transcript, "Hello. How are you?")
        XCTAssertEqual(fixture.captureStops, 1)
        XCTAssertTrue(fixture.output.closed)
        let count = await fixture.transcriber.requests.count
        XCTAssertEqual(count, 2)
    }

    func testSlowTranscriptionKeepsOrderAndStopWaitsForAllPhrases() async throws {
        let fixture = LiveSessionFixture(texts: ["One", "Two", "Three"])
        await fixture.transcriber.suspendNext()
        await fixture.recorder.feed(phrase())
        await fixture.session.poll()
        try await waitUntil { await fixture.transcriber.isSuspended }
        await fixture.recorder.feed(phrase() + phrase())
        await fixture.session.poll()
        XCTAssertTrue(fixture.statuses.contains(.catchingUp))
        let finishing = Task { await fixture.session.finish() }
        await fixture.transcriber.resume()
        await finishing.value
        XCTAssertEqual(fixture.output.insertions, ["One", "Two", "Three"])
        let maximum = await fixture.transcriber.maximumConcurrentRequests
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(fixture.session.transcript, "One Two Three")
    }

    func testFocusChangePermanentlyPausesInsertionButKeepsTranscribing() async throws {
        let fixture = LiveSessionFixture(texts: ["Already inserted.", "Keep this too.", "And this."])
        await fixture.recorder.feed(phrase())
        await fixture.session.poll()
        try await waitUntil { fixture.output.insertions.count == 1 }
        fixture.output.focusValid = false
        await fixture.recorder.feed(phrase())
        await fixture.session.poll()
        try await waitUntil { fixture.session.transcript.contains("Keep this too.") }
        fixture.output.focusValid = true // Returning to the field does not resume.
        await fixture.recorder.feed(speech())
        await fixture.session.finish()
        XCTAssertEqual(fixture.output.insertions, ["Already inserted."])
        XCTAssertEqual(fixture.session.transcript, "Already inserted. Keep this too. And this.")
        XCTAssertEqual(fixture.session.errorMessage, UserFacingMessage.liveTargetChanged)
    }

    func testInsertionFailureDoesNotRetryOrRepeatTextAtStop() async throws {
        let fixture = LiveSessionFixture(texts: ["Maybe delivered.", "Saved only."])
        fixture.output.failInsertion = true
        await fixture.recorder.feed(phrase())
        await fixture.session.poll()
        try await waitUntil { fixture.session.errorMessage != nil }
        await fixture.recorder.feed(speech())
        await fixture.session.finish()
        XCTAssertEqual(fixture.output.insertions, ["Maybe delivered."])
        XCTAssertEqual(fixture.session.transcript, "Maybe delivered. Saved only.")
    }

    func testCancellationDiscardsQueuedAndInFlightResultsWithoutErasingInsertedText() async throws {
        let fixture = LiveSessionFixture(texts: ["Keep.", "Discard."])
        await fixture.recorder.feed(phrase())
        await fixture.session.poll()
        try await waitUntil { fixture.output.insertions.count == 1 }
        await fixture.transcriber.suspendNext()
        await fixture.recorder.feed(phrase() + phrase())
        await fixture.session.poll()
        try await waitUntil { await fixture.transcriber.isSuspended }
        fixture.session.cancel()
        let finishing = Task { await fixture.session.finish() }
        await fixture.transcriber.resume()
        await finishing.value
        XCTAssertEqual(fixture.session.transcript, "Keep.")
        XCTAssertEqual(fixture.output.insertions, ["Keep."])
        XCTAssertNil(fixture.session.errorMessage)
        let count = await fixture.transcriber.requests.count
        XCTAssertEqual(count, 2)
    }

    func testTranscriptionFailureRequestsStopAndPreservesCompletedPhrases() async throws {
        let fixture = LiveSessionFixture(texts: ["Keep."])
        await fixture.recorder.feed(phrase())
        await fixture.session.poll()
        try await waitUntil { fixture.output.insertions.count == 1 }
        await fixture.transcriber.failNext()
        await fixture.recorder.feed(phrase())
        await fixture.session.poll()
        try await waitUntil { fixture.failureCount == 1 }
        await fixture.session.finish()
        XCTAssertEqual(fixture.session.transcript, "Keep.")
        XCTAssertNotNil(fixture.session.errorMessage)
        XCTAssertEqual(fixture.output.insertions, ["Keep."])
    }

    func testFinalSamplesCapturedDuringStopAreDrainedExactlyOnce() async {
        let fixture = LiveSessionFixture(texts: ["Final words."])
        await fixture.recorder.setFinalSamples(speech())
        await fixture.session.finish()
        await fixture.session.finish()
        XCTAssertEqual(fixture.output.insertions, ["Final words."])
        XCTAssertEqual(fixture.captureStops, 1)
    }

    func testSilenceDoesNotCallTranscriber() async {
        let fixture = LiveSessionFixture(texts: [])
        await fixture.recorder.feed([Float](repeating: 0, count: 32_000))
        await fixture.session.poll()
        await fixture.session.finish()
        let count = await fixture.transcriber.requests.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(fixture.session.transcript, "")
    }

    private func speech() -> [Float] {
        (0 ..< 8_000).map { $0.isMultiple(of: 2) ? 0.1 : -0.1 }
    }

    private func phrase() -> [Float] { speech() + [Float](repeating: 0, count: 16_000) }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let met = await condition()
        XCTAssertTrue(met, "Timed out waiting for live dictation")
    }
}

@MainActor
private final class LiveSessionFixture {
    let recorder = LiveTestRecording()
    let transcriber: LiveTestTranscriber
    let output = LiveTestOutput()
    var statuses: [LiveDictationStatus] = []
    var captureStops = 0
    var failureCount = 0
    lazy var session = LiveDictationSession(
        recorder: recorder, transcriber: transcriber, output: output,
        request: { samples in
            TranscriptionRequest(samples: samples,
                model: SpeechModelDescriptor(id: "test", displayName: "Test", sizeBytes: 0,
                    languageSupport: ["en"], precision: "fp16",
                    acquisition: .singleFile(url: URL(fileURLWithPath: "/unused"), sha256: "")),
                localModelURL: URL(fileURLWithPath: "/unused"), language: "en")
        },
        onUpdate: { [weak self] _, status in self?.statuses.append(status) },
        onCaptureStopped: { [weak self] in self?.captureStops += 1 },
        onTranscriptionFailure: { [weak self] in self?.failureCount += 1 }
    )

    init(texts: [String]) { transcriber = LiveTestTranscriber(texts: texts) }
}

private actor LiveTestRecording: LiveRecordingController {
    private var pending: [Float] = []
    private var finalSamples: [Float] = []
    func start() {}
    func feed(_ samples: [Float]) { pending += samples }
    func setFinalSamples(_ samples: [Float]) { finalSamples = samples }
    func stop() -> [Float] { pending += finalSamples; finalSamples = []; return [] }
    func drainLiveSamples() -> [Float] { defer { pending = [] }; return pending }
}

private actor LiveTestTranscriber: SpeechTranscribing {
    private var texts: [String]
    private var shouldSuspend = false
    private var shouldFail = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var concurrentRequests = 0
    var requests: [TranscriptionRequest] = []
    var maximumConcurrentRequests = 0
    var isSuspended: Bool { continuation != nil }
    init(texts: [String]) { self.texts = texts }
    func suspendNext() { shouldSuspend = true }
    func failNext() { shouldFail = true }
    func resume() { continuation?.resume(); continuation = nil }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptResult {
        requests.append(request)
        concurrentRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, concurrentRequests)
        defer { concurrentRequests -= 1 }
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation = $0 }
        }
        if shouldFail { shouldFail = false; throw TextOutputError.insertionFailed }
        let text = texts.isEmpty ? "" : texts.removeFirst()
        return TranscriptResult(text: text, segments: [], duration: 0, processingTime: 0)
    }
}

@MainActor
private final class LiveTestOutput: LiveTextOutputSession {
    var insertions: [String] = []
    var focusValid = true
    var failInsertion = false
    var closed = false
    func validate() throws { if !focusValid { throw LiveDictationError.targetChanged } }
    func insert(_ text: String) throws {
        try validate()
        insertions.append(text)
        if failInsertion { throw TextOutputError.insertionFailed }
    }
    func close() { closed = true }
}
