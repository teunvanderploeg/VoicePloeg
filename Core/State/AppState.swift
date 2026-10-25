import Foundation

enum AppState: Equatable {
    case idle
    case starting
    case listening(startedAt: Date)
    case processing
    case error(message: String)

    var isDictationActive: Bool {
        switch self {
        case .starting, .listening, .processing:
            return true
        case .idle, .error:
            return false
        }
    }

    var title: String {
        switch self {
        case .idle:
            return "Idle"
        case .starting:
            return UserFacingMessage.startingRecording
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case let .error(message):
            return "Error: \(message)"
        }
    }

    var symbolName: String {
        switch self {
        case .idle:
            return "mic"
        case .starting:
            return "mic.badge.ellipsis"
        case .listening:
            return "waveform.circle.fill"
        case .processing:
            return "hourglass"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}
