import Foundation

protocol RecordingController: Sendable {
    func start() async throws
    func stop() async throws -> [Float]
}
