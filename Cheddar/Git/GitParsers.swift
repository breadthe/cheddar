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
        "%(committerdate:unix)", "%(contents:subject)",
    ].joined(separator: "%1f") + "%1e"

    /// Parses `git for-each-ref refs/heads --format=<branchFormat>`.
    static func branches(_ output: String) -> [Branch] {
        output.split(separator: "\u{1e}").compactMap { record in
            let fields = record.drop { $0 == "\n" }.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, !fields[0].isEmpty else { return nil }
            return Branch(
                name: shortBranchName(fields[0]),
                sha: fields[1],
                upstream: fields[2].isEmpty ? nil : fields[2],
                upstreamTrack: fields[3].isEmpty ? nil : fields[3],
                lastCommitDate: TimeInterval(fields[4]).map(Date.init(timeIntervalSince1970:)),
                subject: fields[5]
            )
        }
    }

    static func shortBranchName(_ ref: String) -> String {
        ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }

    private static func splitAttribute(_ field: Substring) -> (String, String?) {
        guard let space = field.firstIndex(of: " ") else { return (String(field), nil) }
        return (String(field[..<space]), String(field[field.index(after: space)...]))
    }
}
