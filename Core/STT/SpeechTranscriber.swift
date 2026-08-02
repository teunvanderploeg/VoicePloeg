import Foundation

struct TranscriptSegment: Codable, Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct TranscriptResult: Codable, Equatable, Sendable {
    let text: String
    let segments: [TranscriptSegment]
    let duration: TimeInterval
    let processingTime: TimeInterval
}

struct TranscriptionRequest: Sendable {
    let samples: [Float]
    let model: SpeechModelDescriptor
    let localModelURL: URL
    let language: String
    let whisperCLIPath: String?

    init(
        samples: [Float],
        model: SpeechModelDescriptor,
        localModelURL: URL,
        language: String,
        whisperCLIPath: String? = nil
    ) {
        self.samples = samples
        self.model = model
        self.localModelURL = localModelURL
        self.language = language
        self.whisperCLIPath = whisperCLIPath
    }
}

protocol SpeechTranscribing: Sendable {
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptResult
}
