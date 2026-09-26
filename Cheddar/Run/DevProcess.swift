import Darwin
import Foundation

/// A shell script started in its own session, so the whole process group (e.g. `concurrently` and the
/// servers it starts) can be stopped together. stdout and stderr arrive merged, line by line.
/// Foundation's `Process` can't start a new session, hence `posix_spawn`.
final class DevProcess: @unchecked Sendable {
    let pid: pid_t
    /// How long Stop waits after SIGTERM before sending SIGKILL.
    static let killDelay: TimeInterval = 3

    private let queue = DispatchQueue(label: "com.breadthe.Cheddar.dev-process")
    private var exitSource: DispatchSourceProcess?
    private var output: FileHandle?
    private var pending = Data()
    // Only touched on `queue`.
    private var hasExited = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    private init(pid: pid_t) {
        self.pid = pid
    }

    /// Runs `/bin/sh -c script` in `directory`. `onExit` gets the exit status (128 + signal when killed)
    /// once the shell has exited; any process it left in its group is sent SIGTERM then.
    static func start(
        _ script: String,
        in directory: String,
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> DevProcess {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw posixError("pipe") }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new session (so a new process group), no inherited descriptors, default signal handling.
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        let argv: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", script].map { (argument: String) in strdup(argument) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
        close(fds[1])
        guard status == 0 else {
            close(fds[0])
            throw posixError("posix_spawn", code: status)
        }

        let process = DevProcess(pid: pid)
        process.readLines(from: fds[0], onLine: onLine)
        process.watchExit(onExit: onExit)
        return process
    }

    /// SIGTERM to the whole group, then SIGKILL to whatever in it ignored that, after `killDelay`.
    func terminate() {
        killpg(pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + Self.killDelay) { [pid] in
            killpg(pid, SIGKILL)
        }
    }

    /// Returns once the shell has exited.
    func waitForExit() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if hasExited { continuation.resume() } else { exitWaiters.append(continuation) }
            }
        }
    }

    // MARK: Private

    private func readLines(from fd: Int32, onLine: @escaping @Sendable (String) -> Void) {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        output = handle
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.queue.async {
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if !self.pending.isEmpty { onLine(String(decoding: self.pending, as: UTF8.self)) }
                    self.pending.removeAll()
                    return
                }
                self.pending.append(data)
                // Progress bars redraw with \r; treat it as a line end too.
                while let end = self.pending.firstIndex(where: { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") }) {
                    let line = self.pending[self.pending.startIndex..<end]
                    self.pending.removeSubrange(self.pending.startIndex...end)
                    if !line.isEmpty { onLine(String(decoding: line, as: UTF8.self)) }
                }
            }
        }
    }

    private func watchExit(onExit: @escaping @Sendable (Int32) -> Void) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.reap(onExit: onExit) }
        exitSource = source
        source.resume()
        // An exit before the source was watching isn't reported; check once.
        queue.async { [weak self] in self?.reap(onExit: onExit, onlyIfExited: true) }
    }

    /// On `queue`.
    private func reap(onExit: @Sendable (Int32) -> Void, onlyIfExited: Bool = false) {
        guard !hasExited else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, onlyIfExited ? WNOHANG : 0)
        guard result == pid else { return }
        hasExited = true
        exitSource?.cancel()
        // Whatever the shell left running in its group shouldn't outlive it.
        killpg(pid, SIGTERM)
        let signal = status & 0x7f
        onExit(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
        exitWaiters.forEach { $0.resume() }
        exitWaiters.removeAll()
    }

    private static func posixError(_ call: String, code: Int32 = errno) -> OperationError {
        OperationError(errorDescription: "Couldn't start the dev command (\(call): \(String(cString: strerror(code)))).")
    }
}
