import Foundation

/// Splits raw microphone audio at pauses without overlapping or replaying speech.
/// The threshold uses raw levels: normalizing silence first would amplify background noise.
struct LiveAudioSegmenter: Sendable {
    static let sampleRate = 16_000
    private let frameSize = 320
    private let pauseFrames = 33
    private let paddingFrames = 9
    private let minimumSpeechFrames = 6
    private let maximumFrames = 600
    private var remainder: [Float] = []
    private var leading: [Float] = []
    private var phrase: [Float] = []
    private var voicedFrames = 0
    private var quietFrames = 0
    private var noiseFloor: Float = 0.0005

    mutating func append(_ samples: [Float], finishing: Bool = false) -> [[Float]] {
        let input = remainder + samples
        var chunks: [[Float]] = []
        var offset = 0
        while offset + frameSize <= input.count {
            consume(Array(input[offset ..< offset + frameSize]), into: &chunks)
            offset += frameSize
        }
        remainder = Array(input.dropFirst(offset))
        if finishing {
            if !remainder.isEmpty {
                consume(remainder, into: &chunks)
                remainder = []
            }
            flush(into: &chunks)
            leading = []
        }
        return chunks
    }

    private mutating func consume(_ frame: [Float], into chunks: inout [[Float]]) {
        let mean = frame.reduce(0, +) / Float(frame.count)
        let energy = frame.reduce(Float.zero) { $0 + ($1 - mean) * ($1 - mean) }
        let rms = sqrt(energy / Float(frame.count))
        let isSpeech = rms >= max(0.002, min(0.02, noiseFloor * 3))
        if !isSpeech, phrase.isEmpty {
            noiseFloor = noiseFloor * 0.98 + rms * 0.02
        }
        if phrase.isEmpty {
            guard isSpeech else {
                leading.append(contentsOf: frame)
                leading = Array(leading.suffix(paddingFrames * frameSize))
                return
            }
            phrase = leading
            leading = []
        }
        phrase.append(contentsOf: frame)
        if isSpeech {
            voicedFrames += 1
            quietFrames = 0
        } else {
            quietFrames += 1
        }
        if quietFrames >= pauseFrames || phrase.count >= maximumFrames * frameSize {
            flush(into: &chunks)
        }
    }

    private mutating func flush(into chunks: inout [[Float]]) {
        if voicedFrames >= minimumSpeechFrames {
            chunks.append(phrase)
        }
        phrase = []
        voicedFrames = 0
        quietFrames = 0
    }
}

/// Owns the audio cursor off the main actor so a slow model never blocks capture or UI.
actor LiveDictationBuffer {
    private var offset = 0
    private var segmenter = LiveAudioSegmenter()

    func read(from recorder: any RecordingController, finishing: Bool = false) async -> [[Float]] {
        let samples = await recorder.samples(from: offset)
        offset += samples.count
        return segmenter.append(samples, finishing: finishing).map(AudioCaptureService.normalize)
    }
}

struct LiveTranscriptAccumulator {
    private(set) var text = ""

    mutating func append(_ transcript: String) -> String? {
        let clean = WhisperTranscriptNormalizer.normalize(transcript)
        guard !clean.isEmpty else { return nil }
        let needsSpace = !text.isEmpty && clean.first.map { !".,;:!?)]}".contains($0) } == true
        let fragment = (needsSpace ? " " : "") + clean
        text += fragment
        return fragment
    }
}
