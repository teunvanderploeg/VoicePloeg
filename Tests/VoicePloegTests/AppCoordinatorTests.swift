import CoreAudio
import CryptoKit
import XCTest
@testable import VoicePloeg

@MainActor
final class AppCoordinatorTests: XCTestCase {
    func testLiveShutdownWhileFinishingSavesRecognizedTextOnlyOnce() async throws {
        let fixture = try Fixture(live: true)
        defer { fixture.cleanup() }
        await fixture.transcriber.setText("Keep this.")
        await fixture.coordinator.toggleRecording()
        await fixture.recorder.append(speech(1) + silence(0.8))
        try await waitUntil { fixture.output.liveInsertions.count == 1 }
        await fixture.transcriber.setDelay(.seconds(30))
        await fixture.recorder.append(speech(1))
        let stop = Task { await fixture.coordinator.toggleRecording() }
        try await waitUntil { await fixture.transcriber.requests.count == 2 }
        await fixture.coordinator.shutdown()
        await stop.value
        XCTAssertEqual(fixture.settings.transcriptHistory.map(\.text), ["Keep this."])
        XCTAssertEqual(fixture.output.liveInsertions, ["Keep this."])
        XCTAssertFalse(fixture.coordinator.isLiveDictating)
        XCTAssertEqual(fixture.coordinator.state, .idle)
    }

    func testLiveShutdownDuringInferenceStopsWithoutPasting() async throws {
        let fixture = try Fixture(live: true)
        defer { fixture.cleanup() }
        await fixture.transcriber.setDelay(.seconds(30))
        await fixture.coordinator.toggleRecording()
        await fixture.recorder.append(speech(1) + silence(0.8))
        try await waitUntil { await fixture.transcriber.requests.count == 1 }
        await fixture.coordinator.shutdown()
        XCTAssertTrue(fixture.output.liveInsertions.isEmpty)
        XCTAssertFalse(fixture.coordinator.isLiveDictating)
        XCTAssertEqual(fixture.coordinator.state, .idle)
        let stops = await fixture.recorder.stopCount
        XCTAssertEqual(stops, 1)
    }

    func testLiveFailedAudioCanRetryWithoutReplayingInsertedPhrases() async throws {
        let fixture = try Fixture(live: true)
        defer { fixture.cleanup() }
        await fixture.transcriber.setText("Already inserted.")
        await fixture.coordinator.toggleRecording()
        await fixture.recorder.append(speech(1) + silence(0.8))
        try await waitUntil { fixture.output.liveInsertions.count == 1 }
        await fixture.transcriber.setFailures(2)
        await fixture.transcriber.setText("Recovered tail.")
        await fixture.recorder.append(speech(1) + silence(0.8))
        try await waitUntil { !fixture.coordinator.state.isDictationActive }
        XCTAssertTrue(fixture.coordinator.hasRetainedRecording)
        XCTAssertEqual(fixture.coordinator.lastTranscript, "Already inserted.")
        await fixture.coordinator.retryTranscription()
        XCTAssertFalse(fixture.coordinator.hasRetainedRecording)
        XCTAssertEqual(fixture.coordinator.lastTranscript, "Recovered tail.")
        XCTAssertEqual(fixture.output.liveInsertions, ["Already inserted."])
        XCTAssertTrue(fixture.output.regularInsertions.isEmpty)
    }

    func testLivePhrasesInsertBeforeStopAndFinalTailIsNotDuplicated() async throws {
        let fixture = try Fixture(live: true)
        defer { fixture.cleanup() }
        await fixture.transcriber.setResponses(["First sentence.", "Second sentence."])
        await fixture.coordinator.toggleRecording()
        await fixture.recorder.append(speech(1) + silence(0.8))
        try await waitUntil { fixture.output.liveInsertions.count == 1 }
        guard case .listening = fixture.coordinator.state else { return XCTFail("Must keep listening") }
        XCTAssertEqual(fixture.coordinator.liveTranscript, "First sentence.")
        await fixture.recorder.append(speech(0.6))
        await fixture.coordinator.toggleRecording()
        XCTAssertEqual(fixture.output.liveInsertions, ["First sentence.", " Second sentence."])
        XCTAssertEqual(fixture.settings.transcriptHistory.map(\.text), ["First sentence. Second sentence."])
        XCTAssertEqual(fixture.coordinator.state, .idle)
        XCTAssertFalse(fixture.coordinator.isLiveDictating)
        XCTAssertTrue(fixture.output.regularInsertions.isEmpty)
    }

    func testLiveStopWaitsForInferenceAndPasteWhileDrainingNewAudio() async throws {
        let fixture = try Fixture(live: true)
        defer { fixture.cleanup() }
        await fixture.transcriber.setDelay(.milliseconds(150))
        fixture.output.delay = .milliseconds(150)
        await fixture.transcriber.setResponses(["One.", "Two."])
        await fixture.coordinator.toggleRecording()
        await fixture.recorder.append(speech(1) + silence(0.8))
        try await waitUntil { await fixture.transcriber.requests.count == 1 }
        await fixture.recorder.append(speech(1))
        await fixture.coordinator.toggleRecording()
        XCTAssertEqual(fixture.output.liveInsertions, ["One.", " Two."])
        let requests = await fixture.transcriber.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(fixture.settings.transcriptHistory.count, 1)
    }

    func testLiveFocusFailureStopsAllFurtherOutputAndSavesFullTranscript() async throws {
        let fixture = try Fixture(live: true)
        defer { fixture.cleanup() }
        await fixture.transcriber.setResponses(["One.", "Two.", "Three."])
        await fixture.coordinator.toggleRecording()
        await fixture.recorder.append(speech(1) + silence(0.8))
        try await waitUntil { fixture.output.liveInsertions.count == 1 }
        fixture.output.failInsertion = true
        await fixture.recorder.append(speech(1) + silence(0.8))
        try await waitUntil { fixture.coordinator.liveOutputMessage != nil }
        await fixture.recorder.append(speech(1))
        await fixture.coordinator.toggleRecording()
        XCTAssertEqual(fixture.output.liveInsertions, ["One."])
        XCTAssertEqual(fixture.output.liveAttempts, 2)
        XCTAssertEqual(fixture.settings.transcriptHistory.first?.text, "One. Two. Three.")
        XCTAssertEqual(fixture.coordinator.state, .error(message: UserFacingMessage.liveOutputSaved))
    }

    func testLiveSessionPinsModeLanguageAndModelAndResetsForNextRecording() async throws {
        let fixture = try Fixture(includeMultilingualModel: true, live: true)
        defer { fixture.cleanup() }
        await fixture.transcriber.setText("Hello.")
        await fixture.coordinator.toggleRecording()
        fixture.settings.liveDictationEnabled = false
        fixture.coordinator.cycleLanguage()
        await fixture.recorder.append(speech(1))
        await fixture.coordinator.toggleRecording()
        await fixture.coordinator.toggleRecording()
        await fixture.coordinator.toggleRecording()
        let requests = await fixture.transcriber.requests
        XCTAssertEqual(requests.map(\.language), ["en", "nl"])
        XCTAssertEqual(requests.map(\.model.id), ["test-model", "test-multilingual"])
        XCTAssertEqual(fixture.output.liveInsertions, ["Hello."])
        XCTAssertEqual(fixture.output.regularInsertions, ["Hello."])
    }

    func testSilentLiveRecordingDoesNotRunModelOrCreateHistory() async throws {
        let fixture = try Fixture(live: true)
        defer { fixture.cleanup() }
        await fixture.coordinator.toggleRecording()
        await fixture.recorder.append(silence(3))
        await fixture.coordinator.toggleRecording()
        let requests = await fixture.transcriber.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(fixture.settings.transcriptHistory.isEmpty)
        XCTAssertEqual(fixture.coordinator.state, .idle)
    }

    func testLiveAutomaticStopFlushesTailOnce() async throws {
        let fixture = try Fixture(duration: 0.1, live: true)
        defer { fixture.cleanup() }
        await fixture.transcriber.setText("Finished.")
        await fixture.coordinator.toggleRecording()
        await fixture.recorder.append(speech(1))
        try await waitUntil { !fixture.coordinator.state.isDictationActive }
        XCTAssertEqual(fixture.output.liveInsertions, ["Finished."])
        let stops = await fixture.recorder.stopCount
        XCTAssertEqual(stops, 1)
    }

    func testTransientLiveInferenceFailureRetriesOnlyUntranscribedAudio() async throws {
        let fixture = try Fixture(live: true)
        defer { fixture.cleanup() }
        await fixture.transcriber.setFailures(1)
        await fixture.transcriber.setText("Recovered.")
        await fixture.coordinator.toggleRecording()
        await fixture.recorder.append(speech(1) + silence(0.8))
        try await waitUntil { !fixture.coordinator.state.isDictationActive }
        XCTAssertEqual(fixture.output.liveInsertions, ["Recovered."])
        XCTAssertEqual(fixture.settings.transcriptHistory.map(\.text), ["Recovered."])
        XCTAssertEqual(fixture.coordinator.state, .idle)
    }

    func testLiveMissingTextFocusRejectsStartBeforeMicrophoneOpens() async throws {
        let fixture = try Fixture(live: true)
        defer { fixture.cleanup() }
        fixture.output.failBegin = true
        await fixture.coordinator.toggleRecording()
        let starts = await fixture.recorder.startCount
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(fixture.coordinator.isLiveDictating)
        guard case .error = fixture.coordinator.state else { return XCTFail("Expected focus error") }
    }

    private func speech(_ seconds: Double) -> [Float] {
        (0 ..< Int(seconds * 16_000)).map { $0.isMultiple(of: 2) ? 0.025 : -0.025 }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    func testModelUnloadsAfterConfiguredIdlePeriod() async throws {
        let fixture = try Fixture(idleTimeout: 0.05)
        defer { fixture.cleanup() }
        try await waitUntil { await fixture.transcriber.warmupReleaseCount > 0 }
        XCTAssertFalse(fixture.coordinator.isPreparingModel)
    }

    func testShutdownWhilePermissionPendingCannotStartCaptureLater() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.permissions.suspendRequest = true
        let start = Task { await fixture.coordinator.toggleRecording() }
        try await waitUntil { fixture.permissions.requestCount == 1 }
        await fixture.coordinator.shutdown()
        fixture.permissions.resumeRequest()
        await start.value
        let starts = await fixture.recorder.startCount
        XCTAssertEqual(starts, 0)
    }

    func testClearTranscriptsAlsoClearsCurrentTranscript() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.coordinator.lastTranscript = "private"
        fixture.settings.addTranscriptToHistory("private", maxItems: 40)
        fixture.coordinator.clearTranscriptHistory()
        XCTAssertEqual(fixture.coordinator.lastTranscript, "")
        XCTAssertTrue(fixture.settings.transcriptHistory.isEmpty)
    }

    func testHotkeyChangeCannotOverwriteRecordingOrBypassLimit() async throws {
        let fixture = try Fixture(duration: 0.05)
        defer { fixture.cleanup() }
        await fixture.coordinator.toggleRecording()
        fixture.hotkeys.shouldFail = true
        fixture.coordinator.changeHotkey(HotkeyCombination(keyCode: 0, carbonModifiers: 4096))
        XCTAssertTrue(fixture.coordinator.state.isDictationActive)
        XCTAssertFalse(fixture.coordinator.canManageModels)
        XCTAssertNotNil(fixture.coordinator.configurationError)
        try await waitUntil { !fixture.coordinator.state.isDictationActive }
        let stops = await fixture.recorder.stopCount
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(fixture.settings.hotkey, .default)
    }

    func testFailedHotkeyChangeKeepsWorkingPreferenceAndState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.hotkeys.shouldFail = true
        fixture.coordinator.changeHotkey(HotkeyCombination(keyCode: 0, carbonModifiers: 4096))
        XCTAssertEqual(fixture.settings.hotkey, .default)
        XCTAssertEqual(fixture.coordinator.state, .idle)
        XCTAssertNotNil(fixture.coordinator.configurationError)
    }

    func testMissingModelAndCorruptionPreventMicrophoneCapture() async throws {
        for missing in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            if missing { try FileManager.default.removeItem(at: fixture.modelURL) }
            else { try Data("bad model!".utf8).write(to: fixture.modelURL) }
            await fixture.coordinator.toggleRecording()
            let starts = await fixture.recorder.startCount
            XCTAssertEqual(starts, 0)
            XCTAssertEqual(fixture.permissions.requestCount, 0)
            guard case .error = fixture.coordinator.state else { return XCTFail("Expected readiness error") }
        }
    }

    func testFailedTranscriptionCanRetryWithoutRecordingOrPastingTwice() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        await fixture.transcriber.failNextTranscription()
        await fixture.transcriber.setText("Recovered")
        await fixture.coordinator.toggleRecording()
        await fixture.coordinator.toggleRecording()
        XCTAssertTrue(fixture.coordinator.hasRetainedRecording)
        await fixture.coordinator.retryTranscription()
        XCTAssertFalse(fixture.coordinator.hasRetainedRecording)
        XCTAssertEqual(fixture.coordinator.lastTranscript, "Recovered")
        XCTAssertEqual(fixture.settings.transcriptHistory.first?.text, "Recovered")
        XCTAssertEqual(fixture.output.insertCount, 0)
        let starts = await fixture.recorder.startCount
        XCTAssertEqual(starts, 1)
    }

    func testShutdownStopsCaptureAndPreventsFurtherStarts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        await fixture.coordinator.toggleRecording()
        await fixture.coordinator.shutdown()
        await fixture.coordinator.toggleRecording()
        let starts = await fixture.recorder.startCount
        let stops = await fixture.recorder.stopCount
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(fixture.coordinator.hasRetainedRecording)
    }

    func testRapidLanguageShortcutsWarmOnlyTheFinalSelection() async throws {
        let fixture = try Fixture(includeMultilingualModel: true)
        defer { fixture.cleanup() }
        try await waitUntil { await fixture.transcriber.warmupModels.count == 1 }
        await fixture.transcriber.resetWarmupMeasurements()
        for _ in 0 ..< 21 {
            fixture.coordinator.cycleLanguage()
            await Task.yield()
        }
        XCTAssertEqual(fixture.settings.selectedLanguage, "nl")
        try await waitUntil { await fixture.transcriber.warmupModels.count == 1 }
        let models = await fixture.transcriber.warmupModels
        let releases = await fixture.transcriber.warmupReleaseCount
        XCTAssertEqual(models, ["test-multilingual.bin"])
        XCTAssertEqual(releases, 1)
    }

    func testNewLanguageWarmupWaitsForCancelledLoadCleanup() async throws {
        let fixture = try Fixture(includeMultilingualModel: true)
        defer { fixture.cleanup() }
        try await waitUntil { await fixture.transcriber.warmupModels.count == 1 }
        await fixture.transcriber.resetWarmupMeasurements()
        await fixture.transcriber.suspendNextWarmup()
        fixture.coordinator.cycleLanguage()
        try await waitUntil { await fixture.transcriber.activeWarmups == 1 }
        fixture.coordinator.cycleLanguage()
        try await waitUntil { await fixture.transcriber.warmupModels.count == 2 }
        let maximum = await fixture.transcriber.maximumActiveWarmups
        let models = await fixture.transcriber.warmupModels
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(models, ["test-multilingual.bin", "test-model.bin"])
    }

    func testPendingLanguageWarmupDoesNotUnloadModelsDuringRecording() async throws {
        let fixture = try Fixture(includeMultilingualModel: true)
        defer { fixture.cleanup() }
        try await waitUntil { await fixture.transcriber.warmupModels.count == 1 }
        await fixture.transcriber.resetWarmupMeasurements()
        fixture.coordinator.cycleLanguage()
        await fixture.coordinator.toggleRecording()
        try await Task.sleep(for: .milliseconds(350))
        let releases = await fixture.transcriber.warmupReleaseCount
        let models = await fixture.transcriber.warmupModels
        XCTAssertEqual(releases, 0)
        XCTAssertEqual(models, ["test-multilingual.bin"])
        await fixture.coordinator.toggleRecording()
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let met = await condition()
        XCTAssertTrue(met, "Timed out waiting for model warmup")
    }

    func testLanguageShortcutSelectsAssignedModelAndBackendImmediately() throws {
        let fixture = try Fixture(includeMultilingualModel: true)
        defer { fixture.cleanup() }
        fixture.settings.englishDictationModelID = ReleaseConfig.defaultBarkModelID
        // The download browser can remain on Bark while Dutch uses a different backend.
        fixture.settings.selectedTranscriptionBackend = .bark
        XCTAssertEqual(fixture.coordinator.selectedModel()?.backend, .bark)
        fixture.coordinator.cycleLanguage()
        XCTAssertEqual(fixture.settings.selectedLanguage, "nl")
        XCTAssertEqual(fixture.coordinator.selectedModel()?.id, "test-multilingual")
        XCTAssertEqual(fixture.coordinator.selectedModel()?.backend, .whisperCpp)
        XCTAssertTrue(fixture.coordinator.canUseSelectedBackend())
        fixture.coordinator.cycleLanguage()
        XCTAssertEqual(fixture.coordinator.selectedModel()?.backend, .bark)
    }

    func testLanguageChangeKeepsInFlightModelAndUsesNewModelForNextRecording() async throws {
        let fixture = try Fixture(includeMultilingualModel: true)
        defer { fixture.cleanup() }
        await fixture.coordinator.toggleRecording()
        fixture.coordinator.cycleLanguage()
        await fixture.coordinator.toggleRecording()
        await fixture.coordinator.toggleRecording()
        await fixture.coordinator.toggleRecording()
        let requests = await fixture.transcriber.requests
        XCTAssertEqual(requests.map(\.language), ["en", "nl"])
        XCTAssertEqual(requests.map(\.model.id), ["test-model", "test-multilingual"])
    }

    func testOtherLanguagesAndUnassignedDutchUseDefaultModel() throws {
        let fixture = try Fixture(includeMultilingualModel: true)
        defer { fixture.cleanup() }
        fixture.settings.dutchDictationModelID = nil
        for language in ["nl", "de", "auto"] {
            fixture.settings.selectedLanguage = language
            XCTAssertEqual(fixture.coordinator.selectedModel()?.id, "test-multilingual")
        }
    }

    func testRapidTriggersCannotStartTwiceWhilePermissionIsPending() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.permissions.suspendRequest = true
        let first = Task { await fixture.coordinator.toggleRecording() }
        while fixture.permissions.requestCount == 0 { await Task.yield() }
        XCTAssertEqual(fixture.coordinator.state, .starting)

        await fixture.coordinator.toggleRecording()
        await fixture.coordinator.removeSelectedModel()
        await fixture.coordinator.downloadSelectedModel()
        XCTAssertEqual(fixture.permissions.requestCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.modelURL.path))
        XCTAssertFalse(fixture.coordinator.isDownloadingModel)

        fixture.permissions.resumeRequest()
        await first.value
        let starts = await fixture.recorder.startCount
        XCTAssertEqual(starts, 1)
        await fixture.coordinator.toggleRecording()
    }

    func testRecordingAutomaticallyStopsAndTranscribesAtLimit() async throws {
        let fixture = try Fixture(duration: 0.05)
        defer { fixture.cleanup() }
        await fixture.coordinator.toggleRecording()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fixture.coordinator.state.isDictationActive, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fixture.coordinator.state, .idle)
        let stops = await fixture.recorder.stopCount
        let requests = await fixture.transcriber.requests
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(requests.count, 1)
    }

    func testManualStopCancelsAutomaticStop() async throws {
        let fixture = try Fixture(duration: 0.05)
        defer { fixture.cleanup() }
        await fixture.coordinator.toggleRecording()
        await fixture.coordinator.toggleRecording()
        try await Task.sleep(for: .milliseconds(100))
        let stops = await fixture.recorder.stopCount
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(fixture.coordinator.state, .idle)
    }

    func testIncompatibleLanguageIsRejectedBeforeRequestingMicrophone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.settings.selectedLanguage = "nl"
        await fixture.coordinator.toggleRecording()
        XCTAssertEqual(fixture.coordinator.state, .error(message: UserFacingMessage.modelLanguageMismatch))
        XCTAssertEqual(fixture.permissions.requestCount, 0)
    }

    func testInstallationInProgressBlocksRecording() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.coordinator.isInstallingCrisperRuntime = true
        await fixture.coordinator.toggleRecording()
        XCTAssertEqual(fixture.permissions.requestCount, 0)
        XCTAssertEqual(fixture.coordinator.state, .idle)
    }

    func testDeniedPermissionCanBeRetried() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.permissions.granted = false
        await fixture.coordinator.toggleRecording()
        XCTAssertEqual(fixture.coordinator.state, .error(message: UserFacingMessage.microphonePermissionDenied))
        fixture.permissions.granted = true
        await fixture.coordinator.toggleRecording()
        XCTAssertTrue(fixture.coordinator.state.isDictationActive)
        await fixture.coordinator.toggleRecording()
        XCTAssertEqual(fixture.coordinator.state, .idle)
    }

    func testLanguageChangeDuringRecordingDoesNotChangeItsRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        await fixture.coordinator.toggleRecording()
        fixture.settings.selectedLanguage = "nl"
        await fixture.coordinator.toggleRecording()
        let requests = await fixture.transcriber.requests
        XCTAssertEqual(requests.first?.language, "en")
    }

    func testTranscriptIsSavedWhenInsertionFails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        await fixture.transcriber.setText("Keep this dictation")
        await fixture.coordinator.toggleRecording()
        await fixture.coordinator.toggleRecording()
        XCTAssertEqual(fixture.coordinator.lastTranscript, "Keep this dictation")
        XCTAssertEqual(fixture.settings.transcriptHistory.first?.text, "Keep this dictation")
        guard case .error = fixture.coordinator.state else { return XCTFail("Expected insertion failure") }
    }
}

@MainActor
private final class Fixture {
    let directory: URL
    let modelURL: URL
    let suiteName = "VoicePloeg-CoordinatorTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: AppSettings
    let hotkeys = TestHotkeys()
    let output = TestOutput()
    let permissions = TestPermissions()
    let recorder = TestRecording()
    let transcriber = TestTranscriber()
    let coordinator: AppCoordinator

    init(duration: TimeInterval = 120, includeMultilingualModel: Bool = false, live: Bool = false, idleTimeout: TimeInterval = 600) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data("test model".utf8)
        let model = SpeechModelDescriptor(
            id: "test-model", displayName: "Test model", sizeBytes: Int64(data.count),
            languageSupport: ["en"], precision: "fp16",
            acquisition: .singleFile(url: URL(string: "https://invalid.example/model")!,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        )
        modelURL = directory.appendingPathComponent("test-model.bin")
        try data.write(to: modelURL)
        defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(userDefaults: defaults)
        settings.selectedWhisperModelID = model.id
        settings.selectedLanguage = "en"
        settings.liveDictationEnabled = live
        output.failInsertion = !live
        settings.whisperCLIPath = "/usr/bin/true"
        var catalog = [model]
        if includeMultilingualModel {
            let multilingual = SpeechModelDescriptor(
                id: "test-multilingual", displayName: "Test multilingual", sizeBytes: Int64(data.count),
                languageSupport: ["auto", "en", "nl", "de"], precision: "fp16", acquisition: model.acquisition
            )
            catalog.append(multilingual)
            catalog.append(contentsOf: ModelManager().models(for: .bark))
            try data.write(to: directory.appendingPathComponent("test-multilingual.bin"))
            settings.defaultDictationModelID = multilingual.id
            settings.automaticDictationModelID = multilingual.id
            settings.englishDictationModelID = model.id
            settings.dutchDictationModelID = multilingual.id
        }
        coordinator = AppCoordinator(
            settings: settings,
            modelManager: ModelManager(modelsDirectoryURL: directory, catalog: catalog),
            permissionController: permissions,
            recordingController: recorder,
            textOutputController: output,
            hotkeyService: hotkeys,
            audioInputDeviceManager: TestDevices(),
            recordingFeedbackPlayer: TestFeedback(),
            transcriber: transcriber,
            maxRecordingDurationSeconds: duration, idleTimeoutSeconds: idleTimeout, outputTargetProvider: { 42 }
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class TestPermissions: PermissionController {
    var suspendRequest = false
    var granted = true
    var requestCount = 0
    private var continuation: CheckedContinuation<Bool, Never>?

    func requestMicrophoneIfNeeded() async -> Bool {
        requestCount += 1
        if suspendRequest {
            return await withCheckedContinuation { continuation = $0 }
        }
        return granted
    }

    func resumeRequest() {
        continuation?.resume(returning: granted)
        continuation = nil
    }

    func requestAccessibilityIfNeeded(prompt: Bool) -> Bool { true }
    func currentStatus() -> PermissionStatus {
        PermissionStatus(microphoneGranted: granted, accessibilityGranted: true)
    }
    func accessibilityDiagnostics() -> AccessibilityDiagnostics {
        AccessibilityDiagnostics(trustedLegacy: true, trustedWithOptionsNoPrompt: true,
            bundleID: "test", bundlePath: "test", executablePath: "test", processIdentifier: 1)
    }
    func openAccessibilitySettings() {}
}

private actor TestRecording: RecordingController {
    var startCount = 0
    var stopCount = 0
    private var audio: [Float] = []
    func start() { startCount += 1; audio = [] }
    func stop() -> [Float] { stopCount += 1; return audio.isEmpty ? [0.1, -0.1] : AudioCaptureService.normalize(audio) }
    func append(_ samples: [Float]) { audio += samples }
    func samples(from offset: Int) -> [Float] { Array(audio.dropFirst(offset)) }
}

private actor TestTranscriber: ManagedSpeechTranscribing {
    var requests: [TranscriptionRequest] = []
    private var text = ""
    private var responses: [String] = []
    private var delay: Duration = .zero
    private var failures = 0
    func failNextTranscription() { failures = 1 }
    private var shouldSuspendWarmup = false
    var warmupModels: [String] = []
    var warmupReleaseCount = 0
    var activeWarmups = 0
    var maximumActiveWarmups = 0
    func resetWarmupMeasurements() {
        warmupModels = []
        warmupReleaseCount = 0
        maximumActiveWarmups = 0
    }
    func suspendNextWarmup() { shouldSuspendWarmup = true }
    func setText(_ text: String) { self.text = text }
    func setResponses(_ responses: [String]) { self.responses = responses }
    func setDelay(_ delay: Duration) { self.delay = delay }
    func setFailures(_ count: Int) { failures = count }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptResult {
        requests.append(request)
        if delay > .zero { try await Task.sleep(for: delay) }
        if failures > 0 { failures -= 1; throw TextOutputError.insertionFailed }
        return TranscriptResult(text: responses.isEmpty ? text : responses.removeFirst(), segments: [], duration: 0, processingTime: 0)
    }
    func preloadModel(at modelURL: URL, backend: SpeechBackend) async throws {
        warmupModels.append(modelURL.lastPathComponent)
        activeWarmups += 1
        maximumActiveWarmups = max(maximumActiveWarmups, activeWarmups)
        defer { activeWarmups -= 1 }
        if shouldSuspendWarmup {
            shouldSuspendWarmup = false
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                // A model worker needs time to finish cleanup after cancellation.
                await Task.detached { try? await Task.sleep(for: .milliseconds(400)) }.value
                throw error
            }
        }
    }
    func unloadBarkModel() {}
    func unloadCrisperModel() {}
    func releasePreloadedModels() { warmupReleaseCount += 1 }
}

@MainActor
private final class TestOutput: TextOutputController {
    var insertCount = 0
    var failBegin = false
    var failInsertion = true
    var delay: Duration = .zero
    var liveInsertions: [String] = []
    var regularInsertions: [String] = []
    var liveAttempts = 0
    func beginLiveInsertion(targetProcessID: pid_t) throws {
        if failBegin { throw TextOutputError.targetFocusUnavailable }
    }
    func insertLive(_ text: String, targetProcessID: pid_t) async throws -> TextInsertionMethod {
        liveAttempts += 1
        if failInsertion { throw TextOutputError.targetFocusUnavailable }
        if delay > .zero { try await Task.sleep(for: delay) }
        liveInsertions.append(text)
        return .clipboardPaste
    }
    func insert(_ text: String, targetProcessID: pid_t) throws -> TextInsertionMethod {
        insertCount += 1
        if failInsertion { throw TextOutputError.insertionFailed }
        regularInsertions.append(text)
        return .clipboardPaste
    }
}

private final class TestHotkeys: GlobalHotkeyManaging {
    var onTrigger: (() -> Void)?
    var onLanguageCycleTrigger: (() -> Void)?
    var shouldFail = false
    var registrations: [HotkeyCombination] = []
    func register(_ combination: HotkeyCombination) throws {
        if shouldFail { throw GlobalHotkeyError.registrationFailed(-9878) }
        registrations.append(combination)
    }
}

private final class TestDevices: AudioInputDeviceManaging {
    func availableInputDevices() -> [AudioInputDevice] {
        [AudioInputDevice(id: 1, name: "Test mic", transportType: kAudioDeviceTransportTypeBuiltIn)]
    }
    func defaultInputDeviceID() -> AudioDeviceID? { 1 }
    func setDefaultInputDeviceID(_ id: AudioDeviceID) {}
    func setInputDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void) {}
}

@MainActor
private final class TestFeedback: RecordingFeedbackPlayer {
    func playStartCue() {}
    func playStopCue() {}
}
