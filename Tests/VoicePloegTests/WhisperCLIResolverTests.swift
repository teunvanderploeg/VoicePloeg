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

    func testBundledExecutableIsPreferredOverDevelopmentCheckout() throws {
        let appURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: appURL) }
        let cliURL = WhisperCLIResolver.bundledCLIURL(bundleURL: appURL)
        try FileManager.default.createDirectory(at: cliURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)
        XCTAssertEqual(WhisperCLIResolver.resolve(configuredPath: nil, bundleURL: appURL), cliURL.path)
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
