import XCTest
@testable import VoicePloeg

@MainActor
final class LanguageModelSettingsTests: XCTestCase {
    func testAssignmentsPersistAndResolveIndependently() throws {
        try withDefaults { defaults in
            let settings = AppSettings(userDefaults: defaults)
            settings.defaultDictationModelID = "default-model"
            settings.englishDictationModelID = "english-model"
            settings.dutchDictationModelID = "dutch-model"
            let restored = AppSettings(userDefaults: defaults)
            XCTAssertEqual(restored.dictationModelID(for: "en"), "english-model")
            XCTAssertEqual(restored.dictationModelID(for: "nl"), "dutch-model")
            for language in ["auto", "de", "fr", "es"] {
                XCTAssertEqual(restored.dictationModelID(for: language), "default-model")
            }
        }
    }

    func testRemovingAnOverrideUsesDefaultAndSurvivesRestart() throws {
        try withDefaults { defaults in
            let settings = AppSettings(userDefaults: defaults)
            settings.defaultDictationModelID = "first-default"
            settings.englishDictationModelID = "english"
            settings.dutchDictationModelID = "dutch"
            settings.dutchDictationModelID = nil
            settings.defaultDictationModelID = "second-default"
            let restored = AppSettings(userDefaults: defaults)
            XCTAssertEqual(restored.dictationModelID(for: "en"), "english")
            XCTAssertEqual(restored.dictationModelID(for: "nl"), "second-default")
            XCTAssertEqual(restored.dictationModelID(for: "auto"), "second-default")
            settings.englishDictationModelID = nil
            XCTAssertEqual(settings.dictationModelID(for: "en"), "second-default")
        }
    }

    func testMigratingBarkKeepsEnglishAndRestoresPreviousDutchAndDefaultModels() throws {
        try withDefaults { defaults in
            defaults.set("bark", forKey: "settings.selectedTranscriptionBackend")
            defaults.set(ReleaseConfig.defaultBarkModelID, forKey: "settings.selectedBarkModelID")
            defaults.set("ggml-large-v3-turbo-q5_0", forKey: "settings.selectedModelID")
            defaults.set("crisper-whisper-2-turbo", forKey: "settings.selectedCrisperModelID")
            let settings = AppSettings(userDefaults: defaults)
            settings.migrateModelAssignmentsIfNeeded(catalog: ModelManager().catalog)
            XCTAssertEqual(settings.dictationModelID(for: "en"), ReleaseConfig.defaultBarkModelID)
            XCTAssertEqual(settings.dictationModelID(for: "nl"), "crisper-whisper-2-turbo")
            XCTAssertEqual(settings.dictationModelID(for: "auto"), "ggml-large-v3-turbo-q5_0")
            XCTAssertEqual(settings.dictationModelID(for: "fr"), "ggml-large-v3-turbo-q5_0")
        }
    }

    func testMigratingMultilingualSelectionKeepsItAsDefault() throws {
        try withDefaults { defaults in
            defaults.set("crisperWhisper", forKey: "settings.selectedTranscriptionBackend")
            defaults.set("crisper-whisper-2-turbo", forKey: "settings.selectedCrisperModelID")
            let settings = AppSettings(userDefaults: defaults)
            settings.migrateModelAssignmentsIfNeeded(catalog: ModelManager().catalog)
            XCTAssertEqual(settings.defaultDictationModelID, "crisper-whisper-2-turbo")
            XCTAssertNil(settings.englishDictationModelID)
            XCTAssertNil(settings.dutchDictationModelID)
        }
    }

    func testNewInstallKeepsEnglishWhisperAndAddsMultilingualFallback() throws {
        try withDefaults { defaults in
            let settings = AppSettings(userDefaults: defaults)
            settings.migrateModelAssignmentsIfNeeded(catalog: ModelManager().catalog)
            XCTAssertEqual(settings.dictationModelID(for: "en"), ReleaseConfig.defaultModelID)
            XCTAssertEqual(settings.dictationModelID(for: "nl"), ReleaseConfig.defaultMultilingualModelID)
            XCTAssertEqual(settings.dictationModelID(for: "de"), ReleaseConfig.defaultMultilingualModelID)
        }
    }

    func testSavedAssignmentsAreNotReplacedByLegacyDownloadSelections() throws {
        try withDefaults { defaults in
            let settings = AppSettings(userDefaults: defaults)
            settings.defaultDictationModelID = "chosen-default"
            settings.englishDictationModelID = "chosen-english"
            settings.dutchDictationModelID = nil
            settings.selectedTranscriptionBackend = .bark
            let restored = AppSettings(userDefaults: defaults)
            restored.migrateModelAssignmentsIfNeeded(catalog: ModelManager().catalog)
            XCTAssertEqual(restored.defaultDictationModelID, "chosen-default")
            XCTAssertEqual(restored.dictationModelID(for: "en"), "chosen-english")
            XCTAssertEqual(restored.dictationModelID(for: "nl"), "chosen-default")
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "LanguageModelSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
}
