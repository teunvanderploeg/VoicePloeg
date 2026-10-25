import Foundation

struct DictationTimings: Equatable {
    var preparation: TimeInterval = 0
    var transcription: TimeInterval = 0
    var insertion: TimeInterval = 0

    static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
