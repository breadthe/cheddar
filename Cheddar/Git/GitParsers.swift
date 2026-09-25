import Foundation

enum GitParsers {
    /// Parses `git worktree list --porcelain -z`: NUL-terminated attributes, an empty one ends a record.
    static func worktrees(_ output: String) -> [Worktree] {
        var result: [Worktree] = []
        var current: Worktree?
        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            let (key, value) = splitAttribute(field)
            switch key {
            case "":
                if let finished = current { result.append(finished) }
                current = nil
            case "worktree":
                if let finished = current { result.append(finished) }
                current = Worktree(path: value ?? "")
            case "HEAD": current?.head = value
            case "branch": current?.branch = value.map(shortBranchName)
            case "detached": current?.isDetached = true
            case "bare": current?.isBare = true
            case "locked":
                current?.isLocked = true
                current?.lockedReason = value
            case "prunable":
                current?.isPrunable = true
                current?.prunableReason = value
            default: break
            }
        }
        if let finished = current { result.append(finished) }
        return result
    }

    /// Fields separated by 0x1F, records terminated by 0x1E (for-each-ref adds a newline after each).
    static let branchFormat = [
        "%(refname)", "%(objectname)", "%(upstream:short)", "%(upstream:track)",
        "%(committerdate:unix)", "%(contents:subject)", "%(upstream)",
    ].joined(separator: "%1f") + "%1e"

    /// Parses `git for-each-ref refs/heads --format=<branchFormat>`.
    static func branches(_ output: String) -> [Branch] {
        output.split(separator: "\u{1e}").compactMap { record in
            let fields = record.drop { $0 == "\n" }.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7, !fields[0].isEmpty else { return nil }
            return Branch(
                name: shortBranchName(fields[0]),
                sha: fields[1],
                upstream: fields[2].isEmpty ? nil : fields[2],
                upstreamRef: fields[6].isEmpty ? nil : fields[6],
                upstreamTrack: fields[3].isEmpty ? nil : fields[3],
                lastCommitDate: TimeInterval(fields[4]).map(Date.init(timeIntervalSince1970:)),
                subject: fields[5]
            )
        }
    }

    /// Same separators as `branchFormat`.
    static let remoteBranchFormat = [
        "%(refname)", "%(symref)", "%(objectname)", "%(committerdate:unix)", "%(contents:subject)",
    ].joined(separator: "%1f") + "%1e"

    /// Parses `git for-each-ref refs/remotes --format=<remoteBranchFormat>`. `remotes` comes from `git remote`
    /// and is needed to split `refs/remotes/a/b/c`, since remote and branch names can both contain slashes.
    /// Symbolic refs (`origin/HEAD`) are skipped.
    static func remoteBranches(_ output: String, remotes: [String]) -> [RemoteBranch] {
        output.split(separator: "\u{1e}").compactMap { record in
            let fields = record.drop { $0 == "\n" }.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, fields[1].isEmpty, let (remote, name) = splitRemoteRef(fields[0], remotes: remotes) else {
                return nil
            }
            return RemoteBranch(
                ref: fields[0],
                remote: remote,
                name: name,
                sha: fields[2],
                lastCommitDate: TimeInterval(fields[3]).map(Date.init(timeIntervalSince1970:)),
                subject: fields[4]
            )
        }
    }

    /// `refs/remotes/<remote>/<name>` → (remote, name), preferring the longest configured remote that fits.
    /// A ref left over from a remote that's no longer configured falls back to its first path component.
    static func splitRemoteRef(_ ref: String, remotes: [String]) -> (remote: String, name: String)? {
        let prefix = "refs/remotes/"
        guard ref.hasPrefix(prefix) else { return nil }
        let rest = String(ref.dropFirst(prefix.count))
        if let remote = remotes.filter({ rest.hasPrefix("\($0)/") }).max(by: { $0.count < $1.count }) {
            return (remote, String(rest.dropFirst(remote.count + 1)))
        }
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return (String(rest[..<slash]), String(rest[rest.index(after: slash)...]))
    }

    /// Same separators as `branchFormat`.
    static let tagFormat = [
        "%(refname)", "%(objectname)", "%(objecttype)", "%(creatordate:unix)", "%(contents:subject)",
    ].joined(separator: "%1f") + "%1e"

    /// Parses `git for-each-ref refs/tags --format=<tagFormat>`.
    static func tags(_ output: String) -> [Tag] {
        output.split(separator: "\u{1e}").compactMap { record in
            let fields = record.drop { $0 == "\n" }.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, fields[0].hasPrefix("refs/tags/") else { return nil }
            return Tag(
                name: String(fields[0].dropFirst("refs/tags/".count)),
                sha: fields[1],
                isAnnotated: fields[2] == "tag",
                date: TimeInterval(fields[3]).map(Date.init(timeIntervalSince1970:)),
                subject: fields[4]
            )
        }
    }

    /// Parses `git ls-remote --tags <remote>` into tag name → object. The peeled `^{}` lines are skipped:
    /// the tag's own object is what local tags are compared by.
    static func lsRemoteTags(_ output: String) -> [String: String] {
        var tags: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1].hasPrefix("refs/tags/"), !parts[1].hasSuffix("^{}") else { continue }
            tags[String(parts[1].dropFirst("refs/tags/".count))] = parts[0]
        }
        return tags
    }

    static func shortBranchName(_ ref: String) -> String {
        ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }

    private static func splitAttribute(_ field: Substring) -> (String, String?) {
        guard let space = field.firstIndex(of: " ") else { return (String(field), nil) }
        return (String(field[..<space]), String(field[field.index(after: space)...]))
    }
}
