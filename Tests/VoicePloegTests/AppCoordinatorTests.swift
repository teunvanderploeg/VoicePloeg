import CoreAudio
import CryptoKit
import XCTest
@testable import VoicePloeg

@MainActor
final class AppCoordinatorTests: XCTestCase {
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

    init(duration: TimeInterval = 120) throws {
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
        coordinator = AppCoordinator(
            settings: settings,
            modelManager: ModelManager(modelsDirectoryURL: directory, catalog: [model]),
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
    func setText(_ text: String) { self.text = text }
    func transcribe(_ request: TranscriptionRequest) -> TranscriptResult {
        requests.append(request)
        return TranscriptResult(text: text, segments: [], duration: 0, processingTime: 0)
    }
    func preloadModel(at modelURL: URL, backend: SpeechBackend) {}
    func unloadCrisperModel() {}
    func releasePreloadedModels() {}
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
