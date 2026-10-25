import XCTest
@testable import VoicePloeg

@MainActor
final class TranscriptRetentionTests: XCTestCase {
    func testTurningHistoryOffClearsStoredEntriesAndStopsSaving() throws {
        let name = "Retention-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(userDefaults: defaults)
        settings.addTranscriptToHistory("old", maxItems: 40)
        settings.transcriptRetention = .off
        settings.addTranscriptToHistory("private", maxItems: 40)
        XCTAssertTrue(settings.transcriptHistory.isEmpty)
        XCTAssertTrue(AppSettings(userDefaults: defaults).transcriptHistory.isEmpty)
    }

    func testRetentionPrunesOnLaunchAndDeletionPersists() throws {
        let name = "Retention-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let recent = TranscriptHistoryItem(id: UUID(), text: "recent", createdAt: Date())
        let old = TranscriptHistoryItem(id: UUID(), text: "old", createdAt: Date().addingTimeInterval(-8 * 86_400))
        defaults.set(try JSONEncoder().encode([recent, old]), forKey: "settings.transcriptHistory")
        defaults.set(TranscriptRetention.sevenDays.rawValue, forKey: "settings.transcriptRetention")
        let settings = AppSettings(userDefaults: defaults)
        XCTAssertEqual(settings.transcriptHistory, [recent])
        settings.removeTranscript(id: recent.id)
        XCTAssertTrue(AppSettings(userDefaults: defaults).transcriptHistory.isEmpty)
    }
}
