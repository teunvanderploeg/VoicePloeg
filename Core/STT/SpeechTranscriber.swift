import Foundation

struct TranscriptSegment: Codable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct TranscriptResult: Codable, Equatable {
    let text: String
    let segments: [TranscriptSegment]
    let duration: TimeInterval
    let processingTime: TimeInterval
}

protocol SpeechTranscriber {
    func loadModel(at url: URL) async throws
    func transcribe(samples: [Float], language: String?) async throws -> TranscriptResult
}
