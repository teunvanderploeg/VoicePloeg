import Foundation

enum LiveDictationStatus: Equatable {
    case listening
    case transcribing
    case catchingUp
    case paused(message: String)

    var title: String {
        switch self {
        case .listening: return UserFacingMessage.liveListening
        case .transcribing: return UserFacingMessage.liveTranscribing
        case .catchingUp: return UserFacingMessage.liveCatchingUp
        case .paused: return UserFacingMessage.livePaused
        }
    }
}

enum AppState: Equatable {
    case idle
    case starting
    case listening(startedAt: Date)
    case liveListening(startedAt: Date, status: LiveDictationStatus)
    case finishingLive
    case processing
    case error(message: String)

    var isDictationActive: Bool {
        switch self {
        case .starting, .listening, .liveListening, .finishingLive, .processing:
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
        case let .liveListening(_, status):
            return status.title
        case .finishingLive:
            return UserFacingMessage.liveFinishing
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
        case .liveListening(_, .paused):
            return "pause.circle.fill"
        case .liveListening:
            return "waveform.circle.fill"
        case .finishingLive:
            return "hourglass"
        case .processing:
            return "hourglass"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}
