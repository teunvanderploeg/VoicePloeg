import Foundation

struct CrisperWorkerRequest: Codable, Sendable {
    let id: UUID
    let command: String
    var path: String? = nil
    var wavPath: String? = nil
    var language: String? = nil
    var mode: String? = nil
    var device: String? = nil
    var computeType: String? = nil
    var repository: String? = nil
    var revision: String? = nil
    var destination: String? = nil
}

struct CrisperWorkerResponse: Codable, Equatable, Sendable {
    struct Result: Codable, Equatable, Sendable {
        var text: String?
        var duration: TimeInterval?
        var processingTime: TimeInterval?
        var path: String?
        var version: String?
    }

    struct WorkerError: Codable, Equatable, Sendable {
        let code: String
        let message: String
    }

    let id: UUID
    let status: String
    var result: Result?
    var error: WorkerError?
}

enum CrisperWorkerProtocolError: Error, LocalizedError, Equatable {
    case invalidResponse
    case mismatchedResponseID
    case workerError(code: String, message: String)
    case workerExited(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "CrisperWhisper returned an invalid response"
        case .mismatchedResponseID:
            return "CrisperWhisper returned a response for a different request"
        case let .workerError(_, message):
            return message
        case let .workerExited(message):
            return "CrisperWhisper worker exited unexpectedly: \(message)"
        }
    }
}

enum CrisperWorkerCodec {
    static func encode(_ request: CrisperWorkerRequest) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        return data
    }

    static func decode(_ data: Data, expectedID: UUID) throws -> CrisperWorkerResponse {
        guard let response = try? JSONDecoder().decode(CrisperWorkerResponse.self, from: data) else {
            throw CrisperWorkerProtocolError.invalidResponse
        }
        guard response.id == expectedID else {
            throw CrisperWorkerProtocolError.mismatchedResponseID
        }
        if response.status == "error" {
            let error = response.error ?? .init(code: "unknown", message: "Unknown CrisperWhisper error")
            throw CrisperWorkerProtocolError.workerError(code: error.code, message: error.message)
        }
        guard response.status == "ok" else {
            throw CrisperWorkerProtocolError.invalidResponse
        }
        return response
    }
}

enum CrisperResources {
    static func workerURL() -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "worker", withExtension: "py", subdirectory: "CrisperWorker")
            ?? Bundle.module.url(forResource: "worker", withExtension: "py")
        #else
        return Bundle.main.url(forResource: "worker", withExtension: "py", subdirectory: "CrisperWorker")
            ?? Bundle.main.url(forResource: "worker", withExtension: "py")
        #endif
    }

    static func requirementsURL() -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "requirements", withExtension: "lock", subdirectory: "CrisperWorker")
            ?? Bundle.module.url(forResource: "requirements", withExtension: "lock")
        #else
        return Bundle.main.url(forResource: "requirements", withExtension: "lock", subdirectory: "CrisperWorker")
            ?? Bundle.main.url(forResource: "requirements", withExtension: "lock")
        #endif
    }

    static func bundledUVURL() -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "uv", withExtension: nil, subdirectory: "CrisperWorker")
            ?? Bundle.module.url(forResource: "uv", withExtension: nil)
        #else
        return Bundle.main.url(forResource: "uv", withExtension: nil, subdirectory: "CrisperWorker")
            ?? Bundle.main.url(forResource: "uv", withExtension: nil)
        #endif
    }
}
