import CoreAudio
import CryptoKit
import XCTest
@testable import VoicePloeg

@MainActor
final class AppCoordinatorTests: XCTestCase {
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
        XCTAssertTrue(models.isEmpty)
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
    let permissions = TestPermissions()
    let recorder = TestRecording()
    let transcriber = TestTranscriber()
    let coordinator: AppCoordinator

    init(duration: TimeInterval = 120, includeMultilingualModel: Bool = false) throws {
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
        var catalog = [model]
        if includeMultilingualModel {
            let multilingual = SpeechModelDescriptor(
                id: "test-multilingual", displayName: "Test multilingual", sizeBytes: Int64(data.count),
                languageSupport: ["en", "nl", "de"], precision: "fp16", acquisition: model.acquisition
            )
            catalog.append(multilingual)
            catalog.append(contentsOf: ModelManager().models(for: .bark))
            try data.write(to: directory.appendingPathComponent("test-multilingual.bin"))
            settings.defaultDictationModelID = multilingual.id
            settings.englishDictationModelID = model.id
            settings.dutchDictationModelID = multilingual.id
        }
        coordinator = AppCoordinator(
            settings: settings,
            modelManager: ModelManager(modelsDirectoryURL: directory, catalog: catalog),
            permissionController: permissions,
            recordingController: recorder,
            textOutputController: TestOutput(),
            hotkeyService: TestHotkeys(),
            audioInputDeviceManager: TestDevices(),
            recordingFeedbackPlayer: TestFeedback(),
            transcriber: transcriber,
            maxRecordingDurationSeconds: duration
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
    func start() { startCount += 1 }
    func stop() -> [Float] { stopCount += 1; return [] }
}

private actor TestTranscriber: ManagedSpeechTranscribing {
    var requests: [TranscriptionRequest] = []
    private var text = ""
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
    func transcribe(_ request: TranscriptionRequest) -> TranscriptResult {
        requests.append(request)
        return TranscriptResult(text: text, segments: [], duration: 0, processingTime: 0)
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
    func insert(_ text: String, targetProcessID: pid_t) throws -> TextInsertionMethod {
        throw TextOutputError.insertionFailed
    }
}

private final class TestHotkeys: GlobalHotkeyManaging {
    var onTrigger: (() -> Void)?
    var onLanguageCycleTrigger: (() -> Void)?
    func register(_ combination: HotkeyCombination) {}
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
