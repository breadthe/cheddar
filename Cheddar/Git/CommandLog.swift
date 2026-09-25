import Foundation
import Observation

/// Every git command the app runs, with its output, so nothing is hidden.
@Observable @MainActor
final class CommandLog {
    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        /// e.g. `git worktree add -b feat .cheddar/worktrees/feat`, or a note for non-git edits.
        var command: String
        /// The command's words by role, for highlighting; empty for notes.
        var tokens: [CommandToken] = []
        var directory: String?
        /// nil for notes and processes that never launched.
        var exitCode: Int32?
        var output: String
        var failed: Bool
    }

    static let limit = 1000
    static let outputLimit = 4000

    private(set) var entries: [Entry] = []

    nonisolated init() {}

    func record(arguments: [String], directory: URL, result: Result<ProcessOutput, Error>) {
        let tokens = Self.tokens(for: arguments)
        let command = tokens.map(\.text).joined(separator: " ")
        switch result {
        case .success(let output):
            let text = [output.stdoutString, output.stderrString]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            append(Entry(command: command, tokens: tokens, directory: directory.path, exitCode: output.exitCode,
                         output: Self.truncated(text), failed: output.exitCode != 0))
        case .failure(let error):
            append(Entry(command: command, tokens: tokens, directory: directory.path, exitCode: nil,
                         output: error.localizedDescription, failed: !(error is CancellationError)))
        }
    }

    func note(_ message: String) {
        append(Entry(command: message, directory: nil, exitCode: nil, output: "", failed: false))
    }

    func clear() {
        entries.removeAll()
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    private static func truncated(_ text: String) -> String {
        text.count > outputLimit ? String(text.prefix(outputLimit)) + "\n… (truncated)" : text
    }

    /// Classifies `git <arguments>` from the argument array it ran with, so no shell parsing is needed:
    /// `git` and the subcommand, flags (`-x`, `--x`, `--x=y`, and `--` itself), and everything else.
    /// After `--`, everything is a path.
    nonisolated static func tokens(for arguments: [String]) -> [CommandToken] {
        var tokens = [CommandToken(text: "git", role: .program)]
        var hasSubcommand = false
        var afterSeparator = false
        for argument in arguments {
            let role: CommandToken.Role
            if afterSeparator {
                role = .argument
            } else if argument.hasPrefix("-") && argument.count > 1 {
                role = .flag
                afterSeparator = argument == "--"
            } else if !hasSubcommand {
                role = .subcommand
                hasSubcommand = true
            } else {
                role = .argument
            }
            tokens.append(CommandToken(text: quoted(argument), role: role))
        }
        return tokens
    }

    /// Shell-style quoting for display only; commands never run through a shell.
    private nonisolated static func quoted(_ argument: String) -> String {
        let plain = argument.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }
        return plain && !argument.isEmpty ? argument : "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// One word of a logged git command, quoted for display.
struct CommandToken: Equatable {
    enum Role { case program, subcommand, flag, argument }

    var text: String
    var role: Role
}
