import Foundation

extension GitService {
    /// Local tags, newest first.
    func tags(in repo: URL) async throws -> [Tag] {
        GitParsers.tags(try await git.output(
            ["for-each-ref", "refs/tags", "--sort=-creatordate", "--format=\(GitParsers.tagFormat)"], in: repo
        ))
    }

    /// Every remote's tags (network: one `ls-remote` per remote). Run as part of Fetch only.
    func remoteTags(in repo: URL) async throws -> RemoteTags {
        var result: RemoteTags = [:]
        for remote in try await remotes(in: repo) {
            let output = try await git.output(["ls-remote", "--tags", remote], in: repo, timeout: GitRunner.networkTimeout)
            result[remote] = GitParsers.lsRemoteTags(output)
        }
        return result
    }

    func isValidTagName(_ name: String, in repo: URL) async throws -> Bool {
        try await git.run(["check-ref-format", "refs/tags/\(name)"], in: repo).exitCode == 0
    }

    func deleteTag(_ name: String, in repo: URL) async throws {
        try await git.output(["tag", "-d", name], in: repo)
    }

    /// Recreates the tag under the new name, then deletes the old one. An annotated tag is recreated on
    /// what it points at with its message; `git tag new old` would make a tag of the tag. Its tagger, date
    /// and any signature are the new tag's own.
    func renameTag(_ tag: Tag, to newName: String, in repo: URL) async throws {
        if tag.isAnnotated {
            let fields = try await git.output(
                ["for-each-ref", "refs/tags/\(tag.name)", "--format=%(contents:subject)%1f%(contents:body)"], in: repo
            ).split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let subject = fields.first ?? ""
            let body = (fields.count > 1 ? fields[1] : "").trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (body.isEmpty ? subject : "\(subject)\n\n\(body)") + "\n"
            // Verbatim: git's default cleanup would drop message lines starting with #.
            try await git.output(["tag", "-a", newName, "--cleanup=verbatim", "-m", message, "\(tag.sha)^{}"], in: repo)
        } else {
            try await git.output(["tag", newName, tag.sha], in: repo)
        }
        try await deleteTag(tag.name, in: repo)
    }

    /// Pushes one tag. Git refuses if the remote already has a different tag of that name.
    func pushTag(_ name: String, to remote: String, in repo: URL) async throws {
        try await git.output(["push", remote, "refs/tags/\(name)"], in: repo, timeout: GitRunner.networkTimeout)
    }

    /// Fetches one tag that's only on the remote. Git refuses to replace a different local tag.
    func fetchTag(_ name: String, from remote: String, in repo: URL) async throws {
        let ref = "refs/tags/\(name)"
        try await git.output(["fetch", remote, "\(ref):\(ref)"], in: repo, timeout: GitRunner.networkTimeout)
    }

    /// Deletes the tag on `remote` if it still points at `sha`, what the last Fetch saw there.
    func deleteRemoteTag(_ name: String, expecting sha: String, on remote: String, in repo: URL) async throws {
        _ = try await deleteRemoteRef("refs/tags/\(name)", expecting: sha, on: remote, in: repo)
    }
}
