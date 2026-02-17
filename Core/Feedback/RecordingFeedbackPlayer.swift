import AppKit
import Foundation

@MainActor
protocol RecordingFeedbackPlayer {
    func playStartCue()
    func playStopCue()
}

@MainActor
final class SystemRecordingFeedbackPlayer: RecordingFeedbackPlayer {
    private let startSound: NSSound?
    private let stopSound: NSSound?

    init() {
        startSound = Self.loadSystemSound(named: "Tink")
        stopSound = Self.loadSystemSound(named: "Pop")
    }

    func playStartCue() {
        play(startSound)
    }

    func playStopCue() {
        play(stopSound)
    }

    private func play(_ sound: NSSound?) {
        guard let sound else {
            NSSound.beep()
            return
        }

        sound.stop()
        sound.play()
    }

    private static func loadSystemSound(named name: String) -> NSSound? {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        return NSSound(contentsOf: url, byReference: true)
    }
}
