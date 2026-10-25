import XCTest
@testable import VoicePloeg

final class WhisperCLIContractTests: XCTestCase {
    func testLanguageArgumentsIncludeAutoAndExplicitLanguages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("cli")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let modelURL = directory.appendingPathComponent("model")
        try Data([1]).write(to: modelURL)
        let model = SpeechModelDescriptor(id: "test", displayName: "test", sizeBytes: 1,
            languageSupport: ["auto", "en", "nl"], precision: "test",
            acquisition: .singleFile(url: modelURL, sha256: nil))
        for language in ["auto", "en", "nl"] {
            let result = try await WhisperCppTranscriber().transcribe(TranscriptionRequest(
                samples: [0.1, -0.1], model: model, localModelURL: modelURL,
                language: language, whisperCLIPath: cli.path))
            XCTAssertTrue(result.text.contains("-l \(language)"), result.text)
        }
    }
}
