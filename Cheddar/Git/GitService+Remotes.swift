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

    /// Deletes the branch on its remote, unless it moved since our last fetch (see `deleteRemoteRef`).
    /// If it was already gone, its stale remote-tracking ref is removed.
    func deleteRemoteBranch(_ remote: RemoteBranch, in repo: URL) async throws {
        let alreadyGone = try await deleteRemoteRef("refs/heads/\(remote.name)", expecting: remote.sha, on: remote.remote, in: repo)
        if alreadyGone {
            try await git.output(["update-ref", "-d", remote.ref], in: repo)
        }
    }

    /// Deletes `ref` on `remote`, but only if it still points at `sha` (`--force-with-lease`), so work
    /// pushed since we last looked isn't thrown away. A ref that's already gone counts as deleted; returns
    /// true in that case.
    func deleteRemoteRef(_ ref: String, expecting sha: String, on remote: String, in repo: URL) async throws -> Bool {
        let push = ["push", "--force-with-lease=\(ref):\(sha)", remote, ":\(ref)"]
        let result = try await git.run(push, in: repo, timeout: GitRunner.networkTimeout)
        guard result.exitCode != 0 else { return false }
        let error = GitError(arguments: push, exitCode: result.exitCode, stderr: result.stderrString, timedOut: result.timedOut)
        // Git rejects the lease the same way whether the ref moved or was deleted; ask the remote which.
        guard error.isStaleLease else { throw error }
        let current = try await git.output(["ls-remote", remote, ref], in: repo, timeout: GitRunner.networkTimeout)
        let stillThere = current.split(separator: "\n").contains { $0.split(separator: "\t").last.map(String.init) == ref }
        guard !stillThere else { throw error }
        return true
    }

    /// A local branch at the remote branch, with it as the upstream. Nothing is checked out.
    func createTrackingBranch(_ name: String, from remote: RemoteBranch, in repo: URL) async throws {
        try await git.output(["branch", "--track", name, remote.ref], in: repo)
    }

    /// `git fetch --all --prune`. Talks to the network, so it has a timeout; git can't prompt for
    /// credentials (see `GitError.needsCredentials`).
    func fetch(in repo: URL) async throws {
        try await git.output(["fetch", "--all", "--prune"], in: repo, timeout: GitRunner.networkTimeout)
    }
}
