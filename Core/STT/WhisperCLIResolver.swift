import Foundation

enum WhisperCLIResolver {
    static func resolve(configuredPath: String?) -> String? {
        for candidate in candidates(configuredPath: configuredPath) {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func defaultHintPath() -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // STT
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // VoicePloeg root
            .path
        return "\(projectRoot)/Vendor/whisper.cpp/build/bin/whisper-cli"
    }

    private static func candidates(configuredPath: String?) -> [String] {
        var values: [String] = []

        if let configuredPath {
            let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                values.append(trimmed)
            }
        }

        if let envPath = ProcessInfo.processInfo.environment["VOICEPLOEG_WHISPER_CLI"] {
            let trimmed = envPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                values.append(trimmed)
            }
        }

        values.append(defaultHintPath())
        values.append("\(FileManager.default.currentDirectoryPath)/Vendor/whisper.cpp/build/bin/whisper-cli")
        values.append("/opt/homebrew/bin/whisper-cli")
        values.append("/usr/local/bin/whisper-cli")

        var deduped: [String] = []
        for value in values where !deduped.contains(value) {
            deduped.append(value)
        }
        return deduped
    }
}
