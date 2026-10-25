import Foundation

protocol RecordingController: Sendable {
    func start() async throws
    func stop() async throws -> [Float]
}

protocol LiveRecordingController: RecordingController {
    /// Drains only samples not previously read, including the final samples after stop().
    /// These are raw 16 kHz mono samples; detect silence before normalization.
    func drainLiveSamples() async -> [Float]
}
