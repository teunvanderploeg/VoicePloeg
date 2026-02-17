import Foundation

enum AppState: Equatable {
    case idle
    case listening(startedAt: Date)
    case processing
    case error(message: String)

    var title: String {
        switch self {
        case .idle:
            return "Idle"
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
        case .listening:
            return "waveform.circle.fill"
        case .processing:
            return "hourglass"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}
