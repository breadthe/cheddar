import Foundation

/// What the hand-off sheet shows before anything runs.
struct HandoffPreflight {
    var worktree: Worktree
    /// The main checkout's current branch (nil when detached).
    var mainBranch: String?
    /// Uncommitted changes in the main checkout, not counting nested worktree folders.
    var mainChanges: [String]
    /// Uncommitted changes in the worktree; these are carried over.
    var worktreeChanges: [String]
    /// Top-level ignored paths in the worktree (`node_modules/`, `.env`, …); these are lost.
    var ignoredPaths: [String]
}

/// A hand-off that failed partway. Says what happened, what state things are in, and where any stash is.
struct HandoffError: LocalizedError {
    var summary: String
    var underlying: Error
    var notes: [String] = []

    var errorDescription: String? {
        ([summary, underlying.localizedDescription] + notes).joined(separator: "\n\n")
    }
}

extension GitService {
    static func mainStashMessage(branch: String) -> String { "cheddar: before handoff of \(branch)" }
    static func handoffStashMessage(branch: String) -> String { "cheddar handoff: \(branch)" }

    func handoffPreflight(for worktree: Worktree, in repo: URL) async throws -> HandoffPreflight {
        let worktrees = try await self.worktrees(in: repo)
        guard let main = worktrees.first(where: { $0.origin == .main }) else { throw BareRepositoryError() }
        let current = worktrees.first { $0.path == worktree.path } ?? worktree
        async let mainChanges = changes(at: main.path, excludingNested: worktrees.filter { $0.origin != .main }.map(\.path))
        async let worktreeChanges = changes(at: current.path)
        async let ignored = ignoredTopLevelPaths(in: current)
        return try await HandoffPreflight(
            worktree: current,
            mainBranch: main.branch,
            mainChanges: mainChanges,
            worktreeChanges: worktreeChanges,
            ignoredPaths: ignored
        )
    }

    /// Moves work on a worktree's branch into the main checkout (see specs.md → Hand off):
    /// stash W's changes, remove W, switch main to the branch, pop the stash there.
    /// A detached W first gets `newBranch`; on a branch, a different `newBranch` renames it first
    /// (`git branch -m`). A dirty main checkout needs `stashMainChanges`.
    /// Never merges, rebases or deletes the branch. Returns the branch handed off.
    @discardableResult
    func handOff(_ worktree: Worktree, newBranch: String?, stashMainChanges: Bool, in repo: URL) async throws -> String {
        // Re-read state so a stale sheet can't act on old information.
        let worktrees = try await self.worktrees(in: repo)
        guard let main = worktrees.first(where: { $0.origin == .main }) else { throw BareRepositoryError() }
        guard let w = worktrees.first(where: { $0.path == worktree.path }), w.origin != .main else {
            throw OperationError(errorDescription: "That worktree no longer exists.")
        }
        guard !w.isMissing else { throw OperationError(errorDescription: "The worktree's folder is missing.") }
        guard !w.isLocked else {
            throw OperationError(errorDescription: "The worktree is locked\(w.lockedReason.map { " (\($0))" } ?? ""). Unlock it with git worktree unlock first.")
        }
        let wURL = URL(fileURLWithPath: w.path)
        let mainURL = URL(fileURLWithPath: main.path)
        let nested = worktrees.filter { $0.origin != .main }.map(\.path)

        // Checks with no side effects first.
        let mainStatus = try await statusLines(at: main.path)
        let mainChanges = Self.filter(mainStatus, excludingNested: nested, under: main.path)
        guard mainChanges.isEmpty || stashMainChanges else {
            throw OperationError(errorDescription: "The main checkout has uncommitted changes. Stash or commit them first.")
        }
        let branch: String
        var notes: [String] = []
        if let existing = w.branch, let newBranch, !newBranch.isEmpty, newBranch != existing {
            try await git.output(["branch", "-m", existing, newBranch], in: repo)
            branch = newBranch
            notes.append("The branch was renamed from \(existing) to \(newBranch).")
        } else if let existing = w.branch {
            branch = existing
        } else if let newBranch, !newBranch.isEmpty {
            try await git.output(["switch", "-c", newBranch], in: wURL)
            branch = newBranch
        } else {
            throw OperationError(errorDescription: "The worktree has a detached HEAD. Give it a branch name first.")
        }

        if !mainChanges.isEmpty {
            let message = Self.mainStashMessage(branch: branch)
            // Exclude only nested worktrees git lists as untracked; naming an ignored path makes stash fail.
            let listed = Set(mainStatus).subtracting(mainChanges).map { Self.statusPath($0) }
            let excludes = listed.map { ":(exclude)\($0)" }
            try await git.output(["stash", "push", "-u", "-m", message, "--", "."] + excludes, in: mainURL)
            notes.append("The main checkout's earlier changes are saved as stash “\(message)”.")
        }

        // 1. Carry W's changes via the stash, which all worktrees share.
        var carried: String?
        if try await !changes(at: w.path).isEmpty {
            try await git.output(["stash", "push", "-u", "-m", Self.handoffStashMessage(branch: branch)], in: wURL)
            carried = try await git.output(["rev-parse", "stash@{0}"], in: wURL).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Remove W (plain: it's clean now).
        do {
            try await git.output(["worktree", "remove", w.path], in: repo)
        } catch {
            var restoreNotes = notes
            if let carried {
                do {
                    try await popStash(carried, in: wURL)
                } catch {
                    restoreNotes.insert(await stashNote(carried, branch: branch, in: mainURL), at: 0)
                }
            }
            if (error as? GitError)?.stderr.contains("modified or untracked") == true {
                restoreNotes.append("If the worktree has an uncommitted .gitignore, stashing it un-ignores the files it covered. Commit the .gitignore (or remove those files) and try again.")
            }
            throw HandoffError(summary: "Couldn't remove the worktree, so nothing was handed off. Its changes were put back.", underlying: error, notes: restoreNotes)
        }

        // 3. Switch the main checkout. On failure, recreate W and put its changes back.
        do {
            try await git.output(["switch", branch], in: mainURL)
        } catch {
            do {
                try await git.output(["worktree", "add", w.path, branch], in: repo)
                if let carried { try await popStash(carried, in: wURL) }
            } catch let rollbackError {
                var rollbackNotes = notes
                if let carried { rollbackNotes.insert(await stashNote(carried, branch: branch, in: mainURL), at: 0) }
                throw HandoffError(
                    summary: "Couldn't switch the main checkout to \(branch), and recreating the worktree also failed:\n\(rollbackError.localizedDescription)",
                    underlying: error,
                    notes: rollbackNotes
                )
            }
            throw HandoffError(
                summary: "Couldn't switch the main checkout to \(branch). The worktree was recreated at \(w.path) with its changes.",
                underlying: error,
                notes: notes
            )
        }

        // 4. Pop the carried changes in the main checkout. On conflict, git keeps the stash.
        if let carried {
            do {
                try await popStash(carried, in: mainURL)
            } catch {
                throw HandoffError(
                    summary: "The main checkout is now on \(branch), but the worktree's changes didn't apply cleanly.",
                    underlying: error,
                    notes: [await stashNote(carried, branch: branch, in: mainURL) + " Resolve any conflicts in the main checkout, then drop or re-apply it."] + notes
                )
            }
        }
        return branch
    }

    // MARK: Helpers

    /// `git status --porcelain -uall` lines. Paths inside `nested` (linked worktrees under this one,
    /// which git lists as untracked folders) aren't counted.
    func changes(at path: String, excludingNested nested: [String] = []) async throws -> [String] {
        Self.filter(try await statusLines(at: path), excludingNested: nested, under: path)
    }

    private func statusLines(at path: String) async throws -> [String] {
        try await git.output(["status", "--porcelain", "-uall"], in: URL(fileURLWithPath: path))
            .split(separator: "\n").map(String.init)
    }

    private static func filter(_ lines: [String], excludingNested nested: [String], under root: String) -> [String] {
        let nestedPaths = nested.compactMap { Paths.relative($0, under: root) }
        return lines.filter { line in
            let file = statusPath(line)
            return !nestedPaths.contains { file == $0 || file.hasPrefix($0 + "/") }
        }
    }

    /// The path in a porcelain status line (`XY path`), without a trailing slash.
    private static func statusPath(_ line: String) -> String {
        var file = String(line.dropFirst(3))
        if file.hasSuffix("/") { file.removeLast() }
        return file
    }

    func ignoredTopLevelPaths(in worktree: Worktree) async throws -> [String] {
        let lines = try await git.output(["status", "--ignored", "--porcelain"], in: URL(fileURLWithPath: worktree.path))
            .split(separator: "\n")
        var seen = Set<String>()
        return lines.compactMap { line -> String? in
            guard line.hasPrefix("!! ") else { return nil }
            let path = line.dropFirst(3)
            let top = path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? String(path)
            let display = path.contains("/") ? top + "/" : top
            return seen.insert(display).inserted ? display : nil
        }
    }

    /// `stash@{n}` for a stash commit. `git stash pop` only takes stash references, not SHAs, and the
    /// index shifts as other stashes are pushed.
    func stashReference(for sha: String, in repo: URL) async throws -> String? {
        let shas = try await git.output(["stash", "list", "--format=%H"], in: repo).split(separator: "\n")
        return shas.firstIndex { $0 == sha }.map { "stash@{\($0)}" }
    }

    func popStash(_ sha: String, in directory: URL) async throws {
        guard let reference = try await stashReference(for: sha, in: directory) else {
            throw OperationError(errorDescription: "The stash \(sha.prefix(7)) is no longer in the stash list.")
        }
        try await git.output(["stash", "pop", reference], in: directory)
    }

    private func stashNote(_ sha: String, branch: String, in repo: URL) async -> String {
        let message = Self.handoffStashMessage(branch: branch)
        let reference = (try? await stashReference(for: sha, in: repo)) ?? nil
        return "The worktree's changes are still saved in the stash list as \(reference.map { "\($0) " } ?? "")“\(message)”."
    }
}
