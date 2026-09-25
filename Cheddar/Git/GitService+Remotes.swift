import Foundation

extension GitService {
    func remotes(in repo: URL) async throws -> [String] {
        try await git.output(["remote"], in: repo)
            .split(separator: "\n").map(String.init)
    }

    /// Remote-tracking branches from the last fetch, without `<remote>/HEAD`.
    func remoteBranches(in repo: URL, remotes: [String]) async throws -> [RemoteBranch] {
        guard !remotes.isEmpty else { return [] }
        let output = try await git.output(["for-each-ref", "refs/remotes", "--format=\(GitParsers.remoteBranchFormat)"], in: repo)
        return GitParsers.remoteBranches(output, remotes: remotes)
    }

    /// When any worktree of this repo last fetched: the newest `FETCH_HEAD`. It's a per-worktree file, so
    /// it's `<common dir>/FETCH_HEAD` for the main checkout and `<common dir>/worktrees/<id>/FETCH_HEAD`
    /// for linked ones.
    static func lastFetch(commonDir: String) -> Date? {
        let files = FileManager.default
        let worktreeDirs = (try? files.contentsOfDirectory(atPath: commonDir + "/worktrees")) ?? []
        let candidates = [commonDir] + worktreeDirs.map { commonDir + "/worktrees/" + $0 }
        return candidates
            .compactMap { try? files.attributesOfItem(atPath: $0 + "/FETCH_HEAD")[.modificationDate] as? Date }
            .max()
    }

    /// `git fetch --all --prune`. Talks to the network, so it has a timeout; git can't prompt for
    /// credentials (see `GitError.needsCredentials`).
    func fetch(in repo: URL) async throws {
        try await git.output(["fetch", "--all", "--prune"], in: repo, timeout: GitRunner.networkTimeout)
    }
}
