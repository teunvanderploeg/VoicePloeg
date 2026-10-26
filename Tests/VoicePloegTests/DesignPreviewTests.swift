import XCTest
@testable import VoicePloeg

@MainActor
final class DesignPreviewTests: XCTestCase {
    func testNormalStartupDoesNotEnableTheFixture() {
        XCTAssertNil(VoiceDesignPreviewMode.resolve(arguments: ["VoicePloeg"], info: [:]))
        XCTAssertNil(VoiceDesignPreviewMode.resolve(arguments: [], info: ["PloegDesignPreviewMode": "menu"]))
        XCTAssertEqual(VoiceDesignPreviewMode.resolve(arguments: ["--design-preview"], info: [:]), .settings)
        XCTAssertEqual(VoiceDesignPreviewMode.resolve(arguments: ["--design-preview-menu"], info: [:]), .menu)
        XCTAssertEqual(VoiceDesignPreviewMode.resolve(arguments: [], info: ["PloegDesignPreview": true]), .settings)
        XCTAssertEqual(VoiceDesignPreviewMode.resolve(arguments: [], info: ["PloegDesignPreview": true, "PloegDesignPreviewMode": "menu"]), .menu)
    }

    func testPreviewPreferencesStayInMemory() {
        let domain = "VoicePloeg.DesignPreview.MemoryOnly"
        let reference = UserDefaults(suiteName: domain)!
        let original = reference.persistentDomain(forName: domain) as NSDictionary?
        let memory = PreviewMemoryDefaults()
        let settings = AppSettings(userDefaults: memory)
        settings.selectedLanguage = "nl"
        settings.liveDictationEnabled = true
        settings.addTranscriptToHistory("Preview only", maxItems: 2)
        XCTAssertEqual(memory.string(forKey: "settings.selectedLanguage"), "nl")
        XCTAssertTrue(memory.bool(forKey: "settings.liveDictationEnabled"))
        XCTAssertEqual(settings.transcriptHistory.map(\.text), ["Preview only"])
        XCTAssertEqual(reference.persistentDomain(forName: domain) as NSDictionary?, original)
    }

    func testFixtureCannotRecordOrCreateAModelDirectory() async {
        let root = "/__VoicePloegDesignPreview__"
        let existed = FileManager.default.fileExists(atPath: root)
        let coordinator = VoiceDesignPreview.coordinator()
        for model in coordinator.modelManager.catalog {
            _ = coordinator.modelManager.isDownloaded(model)
        }
        await coordinator.toggleRecording()
        XCTAssertTrue(coordinator.isDesignPreview)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.isLiveDictating)
        XCTAssertEqual(FileManager.default.fileExists(atPath: root), existed)
    }
}
