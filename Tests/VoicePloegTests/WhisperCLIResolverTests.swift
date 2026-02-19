import XCTest
@testable import VoicePloeg

final class WhisperCLIResolverTests: XCTestCase {
    func testResolveReturnsConfiguredExecutablePath() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-whisper-cli")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try "#!/bin/sh\nexit 0\n".write(to: tempURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)

        let resolved = WhisperCLIResolver.resolve(configuredPath: tempURL.path)
        XCTAssertEqual(resolved, tempURL.path)
    }

    func testResolveTrimsConfiguredPath() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-whisper-cli")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try "#!/bin/sh\nexit 0\n".write(to: tempURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)

        let resolved = WhisperCLIResolver.resolve(configuredPath: "  \(tempURL.path)\n")
        XCTAssertEqual(resolved, tempURL.path)
    }
}
