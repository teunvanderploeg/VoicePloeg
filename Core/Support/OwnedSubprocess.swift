import Darwin
import Foundation

/// A separate process group owns descendants as well as the executable itself.
/// waitpid is always nonblocking; callers can wait without occupying the UI actor.
final class OwnedSubprocess: @unchecked Sendable {
    let processIdentifier: pid_t
    private let lock = NSLock()
    private var exitStatus: Int32?

    init(executable: URL, arguments: [String], environment: [String: String]?,
         standardInput: FileHandle = .nullDevice, standardOutput: FileHandle, standardError: FileHandle) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, standardInput.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, standardOutput.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, standardError.fileDescriptor, STDERR_FILENO)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([executable.path] + arguments).map { strdup($0) }
        let env = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") }
        defer { (argv + env).forEach { free($0) } }
        var pid: pid_t = 0
        let result = (argv + [nil]).withUnsafeBufferPointer { arguments in
            (env + [nil]).withUnsafeBufferPointer { environment in
                posix_spawn(&pid, executable.path, &actions, &attributes,
                    UnsafeMutablePointer(mutating: arguments.baseAddress!),
                    UnsafeMutablePointer(mutating: environment.baseAddress!))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        processIdentifier = pid
    }

    var isRunning: Bool {
        lock.withLock {
            if exitStatus != nil { return false }
            var status: Int32 = 0
            let result = waitpid(processIdentifier, &status, WNOHANG)
            if result == processIdentifier {
                exitStatus = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            } else if result == -1, errno == ECHILD {
                exitStatus = -1
            }
            return exitStatus == nil
        }
    }

    var terminationStatus: Int32 { lock.withLock { exitStatus ?? -1 } }

    func killGroup() {
        _ = kill(-processIdentifier, SIGKILL)
    }

    func waitForExit(timeout: Duration) async {
        // Cleanup must finish even when the request that owns us was cancelled.
        await Task.detached {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while self.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }.value
    }
}
