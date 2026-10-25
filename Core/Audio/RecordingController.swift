import Foundation

protocol RecordingController: Sendable {
    func start() async throws
    func stop() async throws -> [Float]
    /// Unnormalized 16 kHz mono samples, available during recording and after stop.
    func samples(from offset: Int) async -> [Float]
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void)
}

extension RecordingController {
    func samples(from offset: Int) async -> [Float] { [] }
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {}
}
