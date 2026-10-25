import XCTest
@testable import VoicePloeg

@MainActor
final class AppSettingsBackendTests: XCTestCase {
    func testLiveDictationDefaultsOffAndPersistsIndependently() {
        let suiteName = "AppSettingsLiveTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: defaults)
        XCTAssertFalse(settings.liveDictationEnabled)
        settings.liveDictationEnabled = true
        let restored = AppSettings(userDefaults: defaults)
        XCTAssertTrue(restored.liveDictationEnabled)
        XCTAssertEqual(restored.selectedLanguage, settings.selectedLanguage)
        restored.liveDictationEnabled = false
        XCTAssertFalse(AppSettings(userDefaults: defaults).liveDictationEnabled)
    }

    func testMigratesLegacyModelAndKeepsWhisperDefault() {
        let suiteName = "AppSettingsBackendTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("legacy-model", forKey: "settings.selectedModelID")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(userDefaults: defaults)

        XCTAssertEqual(settings.selectedTranscriptionBackend, .whisperCpp)
        XCTAssertEqual(settings.selectedWhisperModelID, "legacy-model")
        XCTAssertEqual(settings.selectedCrisperModelID, ReleaseConfig.defaultCrisperModelID)
    }

    func testKeepsIndependentModelSelections() {
        let suiteName = "AppSettingsBackendTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: defaults)

        settings.selectedWhisperModelID = "whisper"
        settings.selectedCrisperModelID = "crisper"
        settings.selectedTranscriptionBackend = .crisperWhisper
        XCTAssertEqual(settings.selectedModelID, "crisper")
        settings.selectedTranscriptionBackend = .whisperCpp
        XCTAssertEqual(settings.selectedModelID, "whisper")
    }
}
