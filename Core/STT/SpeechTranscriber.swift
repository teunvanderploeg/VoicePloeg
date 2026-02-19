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

@MainActor
protocol SpeechTranscriber {
    func loadModel(at url: URL) async throws
    func transcribe(samples: [Float], language: String?) async throws -> TranscriptResult
}
