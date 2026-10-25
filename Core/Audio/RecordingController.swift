import Foundation

protocol RecordingController: Sendable {
    func start() async throws
    func stop() async throws -> [Float]
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void)
}

extension RecordingController {
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {}
}
