import Foundation

/// Runs on a worker actor, never in the audio callback. Frame-based detection makes
/// boundaries independent of the capture/poll buffer sizes.
struct LivePhraseSegmenter: Sendable {
    static let sampleRate = 16_000
    private let frameSize = 320
    private let pauseFrames = 38 // 760 ms
    private let preRollFrames = 10
    private let minimumSpeechFrames = 6
    private let maximumPhraseFrames = 750 // 15 seconds of continuous speech
    private var remainder: [Float] = []
    private var preRoll: [Float] = []
    private var phrase: [Float] = []
    private var speechFrames = 0
    private var silentFrames = 0
    private var continuesPreviousPhrase = false

    mutating func append(_ samples: [Float]) -> [[Float]] {
        let input = remainder + samples
        var output: [[Float]] = []
        var offset = 0
        while offset + frameSize <= input.count {
            process(Array(input[offset ..< offset + frameSize]), into: &output)
            offset += frameSize
        }
        remainder = Array(input[offset...])
        return output
    }

    mutating func finish() -> [[Float]] {
        var output: [[Float]] = []
        if !remainder.isEmpty {
            process(remainder, into: &output)
            remainder.removeAll()
        }
        emit(into: &output)
        preRoll.removeAll()
        return output
    }

    private mutating func process(_ frame: [Float], into output: inout [[Float]]) {
        // Remove DC bias, but do not amplify microphone noise before detection.
        let mean = frame.reduce(0, +) / Float(frame.count)
        let power = frame.reduce(Float.zero) { $0 + ($1 - mean) * ($1 - mean) } / Float(frame.count)
        let hasSpeech = power >= 0.000_009 // RMS 0.003, approximately -50 dBFS
        if phrase.isEmpty, !hasSpeech {
            silentFrames += 1
            if silentFrames >= pauseFrames { continuesPreviousPhrase = false }
            preRoll.append(contentsOf: frame)
            if preRoll.count > preRollFrames * frameSize {
                preRoll.removeFirst(preRoll.count - preRollFrames * frameSize)
            }
            return
        }
        if phrase.isEmpty {
            phrase = preRoll
            preRoll.removeAll(keepingCapacity: true)
        }
        phrase.append(contentsOf: frame)
        if hasSpeech {
            speechFrames += 1
            silentFrames = 0
        } else {
            silentFrames += 1
        }
        if silentFrames >= pauseFrames || phrase.count >= maximumPhraseFrames * frameSize {
            let continues = silentFrames < pauseFrames
            emit(into: &output)
            continuesPreviousPhrase = continues
        }
    }

    private mutating func emit(into output: inout [[Float]]) {
        if speechFrames >= minimumSpeechFrames || continuesPreviousPhrase && speechFrames > 0 {
            output.append(AudioCaptureService.normalize(phrase))
        }
        phrase.removeAll(keepingCapacity: true)
        speechFrames = 0
        silentFrames = 0
        continuesPreviousPhrase = false
    }
}

actor LivePhraseBuffer {
    private var segmenter = LivePhraseSegmenter()

    func append(_ samples: [Float]) -> [[Float]] {
        segmenter.append(samples)
    }

    func finish() -> [[Float]] {
        segmenter.finish()
    }
}
