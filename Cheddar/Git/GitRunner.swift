import Foundation

/// A git command that exited non-zero. Carries git's stderr so the UI can show why.
struct GitError: LocalizedError {
    var arguments: [String]
    var exitCode: Int32
    var stderr: String
    /// Killed after running past its timeout (network commands).
    var timedOut = false

    var errorDescription: String? {
        if timedOut { return "git \(arguments.first ?? "") didn't finish within \(Int(GitRunner.networkTimeout)) seconds, so Cheddar stopped it." }
        if isStaleLease {
            return "It changed on the remote since your last fetch, so Cheddar left it alone. Fetch, check what changed, then try again."
        }
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git \(arguments.joined(separator: " ")) failed (exit \(exitCode))" : message
    }

    /// `git branch -d` refused because the branch has commits not merged into HEAD or its upstream.
    var isNotFullyMerged: Bool { stderr.contains("not fully merged") }

    /// A push with `--force-with-lease` was refused: the remote ref no longer matches what we last fetched.
    var isStaleLease: Bool { stderr.contains("(stale info)") }

    /// A remote asked for a password, passphrase or host key confirmation, which Cheddar can't answer
    /// (`GIT_TERMINAL_PROMPT=0`, no terminal for ssh).
    var needsCredentials: Bool {
        ["terminal prompts disabled", "could not read Username", "could not read Password",
         "Permission denied (publickey", "Host key verification failed", "Authentication failed"]
            .contains { stderr.contains($0) }
    }
}

/// Launching git itself failed because the binary is gone (e.g. uninstalled mid-session).
func isToolMissing(_ error: Error) -> Bool {
    let error = error as NSError
    return (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError)
        || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
}

struct BareRepositoryError: LocalizedError {
    var errorDescription: String? { "This is a bare repository. It has no working tree, so Cheddar can't manage it." }
}

/// Runs git with an argument array, a working directory and a clean environment.
struct GitRunner: Sendable {
    /// How long a command that talks to a remote (fetch, push, ls-remote) may run.
    static let networkTimeout: TimeInterval = 120

    let executable: URL
    let environment: [String: String]
    let log: CommandLog?

    init(executable: URL, searchPath: [String], extraEnvironment: [String: String] = [:], log: CommandLog? = nil) {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "XDG_CONFIG_HOME"] {
            environment[key] = inherited[key]
        }
        environment["PATH"] = searchPath.joined(separator: ":")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        // Read-only commands like `git status` otherwise rewrite the index opportunistically, which
        // would trigger the file watcher and refresh again, in a loop.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment.merge(extraEnvironment) { _, new in new }
        self.executable = executable
        self.environment = environment
        self.log = log
    }

    /// Runs git and returns its output whatever the exit code. Every run goes into the command log.
    func run(_ arguments: [String], in directory: URL, timeout: TimeInterval? = nil) async throws -> ProcessOutput {
        do {
            let output = try await ProcessRunner.run(executable, arguments, in: directory, environment: environment, timeout: timeout)
            await log?.record(arguments: arguments, directory: directory, result: .success(output))
            return output
        } catch {
            await log?.record(arguments: arguments, directory: directory, result: .failure(error))
            throw error
        }
    }

    /// Runs git and returns stdout, throwing `GitError` on a non-zero exit.
    @discardableResult
    func output(_ arguments: [String], in directory: URL, timeout: TimeInterval? = nil) async throws -> String {
        let result = try await run(arguments, in: directory, timeout: timeout)
        guard result.exitCode == 0 else {
            throw GitError(arguments: arguments, exitCode: result.exitCode, stderr: result.stderrString, timedOut: result.timedOut)
        }
        return result.stdoutString
    }
}
