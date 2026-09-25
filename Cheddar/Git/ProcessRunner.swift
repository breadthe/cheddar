import Foundation

struct ProcessOutput: Sendable {
    var stdout: Data
    var stderr: Data
    var exitCode: Int32
    /// The process was terminated because it ran past its timeout.
    var timedOut = false

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

enum ProcessRunner {
    /// Runs an executable with an argument array (never a shell string).
    /// Cancelling the calling task terminates the process; `timeout` does the same after that many seconds.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment { process.environment = environment }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let exit = try launch(process)
            let deadline = timeout.map { Date().addingTimeInterval($0) }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
            }
            // Drain both pipes concurrently so a full pipe buffer can't stall the child.
            async let out = readToEnd(stdout.fileHandleForReading)
            async let err = readToEnd(stderr.fileHandleForReading)
            let (outData, errData) = await (out, err)
            await exit.wait()
            try Task.checkCancellation()
            let timedOut = process.terminationReason == .uncaughtSignal && deadline.map { Date() >= $0 } == true
            return ProcessOutput(stdout: outData, stderr: errData, exitCode: process.terminationStatus, timedOut: timedOut)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }

    /// Launches `process` and returns a handle to await its exit. The termination handler is installed
    /// before launch, so an exit can't be missed (`waitUntilExit()` can hang off the main run loop).
    static func launch(_ process: Process) throws -> ProcessExit {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in continuation.finish() }
        try process.run()
        return ProcessExit(stream: stream)
    }
}

struct ProcessExit {
    fileprivate let stream: AsyncStream<Void>

    func wait() async {
        for await _ in stream {}
    }
}
