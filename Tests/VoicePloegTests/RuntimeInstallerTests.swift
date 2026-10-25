import XCTest
@testable import VoicePloeg

final class RuntimeInstallerTests: XCTestCase {
    func testFailedFinalHealthCheckRestoresPreviousRuntime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousManifest = Data("{\"version\":\"previous\"}".utf8)
        try previousManifest.write(to: root.appendingPathComponent("installation.json"))
        let installer = directory.appendingPathComponent("uv")
        try """
        #!/bin/sh
        if [ "$1" = venv ]; then
          for argument in "$@"; do target="$argument"; done
          mkdir -p "$target/bin"
          ln -s /usr/bin/python3 "$target/bin/python"
        fi
        """.write(to: installer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installer.path)
        let health = ["-c", "import os,sys; sys.exit(1 if os.path.exists(sys.argv[1]) else 0)", root.appendingPathExtension("previous").path]
        do {
            try await RuntimeInstaller.install(root: root, uv: installer, requirements: directory,
                version: "new", healthArguments: health, offlineEnvironment: ProcessInfo.processInfo.environment)
            XCTFail("Final validation should fail")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("installation.json")), previousManifest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathExtension("previous").path))
    }

    func testInterruptedPublicationRestoresBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("runtime")
        let backup = root.appendingPathExtension("previous")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("{\"version\":\"previous\"}".utf8).write(to: backup.appendingPathComponent("installation.json"))
        try RuntimeInstaller.recoverInterruptedReplacement(at: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("installation.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testCrisperRuntimeRejectsMalformedAndStaleManifests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bin = directory.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("python"),
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/python3"))
        let manager = CrisperRuntimeManager(rootURL: directory)
        for value in ["invalid", "{\"version\":\"old\"}"] {
            try Data(value.utf8).write(to: directory.appendingPathComponent("installation.json"))
            let status = await manager.status()
            XCTAssertNotEqual(status, .ready(version: ReleaseConfig.crisperRuntimeVersion))
        }
    }
}
