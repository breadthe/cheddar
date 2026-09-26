import Foundation

/// One entry of `git status --porcelain -z`, for the inspector's Changes list.
struct ChangedFile: Identifiable, Hashable {
    var id: String { path }
    /// Relative to the worktree.
    var path: String
    /// Porcelain `XY`: index then worktree status, e.g. `M `, ` M`, `??`, `R `.
    var status: String
    /// For a rename or copy.
    var originalPath: String?

    var isUntracked: Bool { status == "??" }

    /// `git status --porcelain -uall -z`: `XY path\0`, with renames and copies followed by `origPath\0`.
    static func parse(porcelainZ output: String) -> [ChangedFile] {
        var files: [ChangedFile] = []
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let field = fields.popFirst(), field.count > 3 {
            let status = String(field.prefix(2))
            var file = ChangedFile(path: String(field.dropFirst(3)), status: status)
            if status.contains("R") || status.contains("C") { file.originalPath = fields.popFirst() }
            files.append(file)
        }
        return files
    }
}

/// A commit in the inspector's Commits list.
struct Commit: Identifiable, Hashable {
    var id: String { sha }
    var sha: String
    var shortSHA: String
    var subject: String
    var author: String
    var date: Date

    /// `%H %h %s %an %ct` separated by `\u{1F}`, records ending in `\u{1E}`.
    static let format = "%H%x1f%h%x1f%s%x1f%an%x1f%ct%x1e"

    static func parse(log output: String) -> [Commit] {
        output.split(separator: "\u{1E}").compactMap { record in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, let seconds = TimeInterval(fields[4]) else { return nil }
            return Commit(sha: fields[0], shortSHA: fields[1], subject: fields[2], author: fields[3],
                          date: Date(timeIntervalSince1970: seconds))
        }
    }
}

/// A line of a diff or `git show`, classified for git's diff colors.
struct DiffLine: Identifiable, Hashable {
    enum Kind { case added, removed, hunk, meta, commit, context }

    let id: Int
    let text: String
    let kind: Kind

    /// At most this many lines are shown.
    static let limit = 5000

    static func parse(_ output: String) -> (lines: [DiffLine], isTruncated: Bool) {
        let raw = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let trimmed = raw.last == "" ? raw.dropLast() : raw[...]
        let lines = trimmed.prefix(limit).enumerated().map { index, text in
            DiffLine(id: index, text: text, kind: kind(of: text))
        }
        return (Array(lines), trimmed.count > limit)
    }

    private static func kind(of line: String) -> Kind {
        if line.hasPrefix("+++ ") || line.hasPrefix("--- ") { return .meta }
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        if line.hasPrefix("commit ") { return .commit }
        for prefix in ["diff --git ", "index ", "new file mode", "deleted file mode", "similarity index", "rename from",
                       "rename to", "old mode", "new mode", "Binary files", "Author:", "AuthorDate:", "Commit:", "CommitDate:",
                       "Date:", "Merge:"] where line.hasPrefix(prefix) {
            return .meta
        }
        return .context
    }
}
