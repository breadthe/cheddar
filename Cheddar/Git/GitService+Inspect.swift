import Foundation

/// Read-only git for the inspector: a worktree's changes, a file's diff, commits and a commit's diff.
extension GitService {
    /// Uncommitted changes (staged, unstaged, untracked) in the worktree at `path`, without the linked
    /// worktree folders nested in it (git lists those as untracked in the main checkout).
    func changedFiles(at path: String, excludingNested nested: [String] = []) async throws -> [ChangedFile] {
        let output = try await git.output(["status", "--porcelain", "-uall", "-z"], in: URL(fileURLWithPath: path))
        let nestedPaths = nested.compactMap { Paths.relative($0, under: path) }
        return ChangedFile.parse(porcelainZ: output).filter { file in
            !nestedPaths.contains { file.path == $0 || file.path.hasPrefix($0 + "/") }
        }
    }

    /// The file's changes against HEAD (staged and unstaged together); an untracked file shows as all added.
    func diff(of file: ChangedFile, at path: String) async throws -> String {
        let directory = URL(fileURLWithPath: path)
        guard file.isUntracked else {
            return try await git.output(["diff", "HEAD", "--", file.path], in: directory)
        }
        // Exit 1 just means "there are differences".
        let arguments = ["diff", "--no-index", "--", "/dev/null", file.path]
        let result = try await git.run(arguments, in: directory)
        guard result.exitCode <= 1 else {
            throw GitError(arguments: arguments, exitCode: result.exitCode, stderr: result.stderrString)
        }
        return result.stdoutString
    }

    /// Up to `limit` commits on `ref`, newest first. `excluding` limits them to commits that ref isn't
    /// (e.g. trunk): `excluding..ref`.
    func commits(on ref: String, excluding: String? = nil, limit: Int = 30, in directory: String) async throws -> [Commit] {
        let range = excluding.map { "\($0)..\(ref)" } ?? ref
        let output = try await git.output(["log", "-n", String(limit), "--format=\(Commit.format)", range, "--"],
                                          in: URL(fileURLWithPath: directory))
        return Commit.parse(log: output)
    }

    /// The commit's message and patch.
    func show(_ sha: String, in directory: String) async throws -> String {
        try await git.output(["show", "--format=medium", "--patch", sha, "--"], in: URL(fileURLWithPath: directory))
    }
}
