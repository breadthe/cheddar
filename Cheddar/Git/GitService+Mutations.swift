import Foundation

/// An operation Cheddar refuses to run (ownership rules, invalid names, one at a time), with the reason.
struct OperationError: LocalizedError {
    var errorDescription: String?
}

/// A multi-step operation failed partway, and undoing the earlier step failed too.
struct RollbackError: LocalizedError {
    var failure: Error
    var rollbackFailure: Error

    var errorDescription: String? {
        "\(failure.localizedDescription)\n\nUndoing the earlier step also failed:\n\(rollbackFailure.localizedDescription)"
    }
}

enum WorktreeBranch {
    case new(name: String, base: String?)
    case existing(String)

    var name: String {
        switch self {
        case .new(let name, _), .existing(let name): name
        }
    }
}

extension GitService {
    static let cheddarRoot = ".cheddar/worktrees"

    /// Worktree folder name for a branch: slashes become dashes.
    static func folderName(forBranch branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }

    static func isValidFolderName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && name.trimmingCharacters(in: .whitespaces) == name
    }

    /// `git check-ref-format --branch`, plus a guard against names git would read as options or `@{-N}` shorthand.
    func isValidBranchName(_ name: String, in repo: URL) async throws -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("@{") else { return false }
        return try await git.run(["check-ref-format", "--branch", name], in: repo).exitCode == 0
    }

    /// `<repo>/.cheddar/worktrees/<name>`, with a numeric suffix if that folder exists.
    /// `excluding` is the worktree's current path, which may keep its own name.
    func availableWorktreePath(named name: String, in repo: URL, excluding: String? = nil) -> String {
        let root = repo.appendingPathComponent(Self.cheddarRoot).path
        var candidate = (root as NSString).appendingPathComponent(name)
        let current = excluding.map(Paths.canonical)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate), Paths.canonical(candidate) != current {
            candidate = (root as NSString).appendingPathComponent("\(name)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    /// Adds `pattern` to `.git/info/exclude` unless it's already there, so no tracked file changes.
    func ensureExcluded(_ pattern: String, in repo: URL) async throws {
        let path = try await git.output(["rev-parse", "--path-format=absolute", "--git-path", "info/exclude"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: path)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let bare = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let present = existing.split(whereSeparator: \.isNewline).contains {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return [bare, "\(bare)/", "/\(bare)", "/\(bare)/"].contains(line)
        }
        guard !present else { return }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (existing + separator + pattern + "\n").write(to: url, atomically: true, encoding: .utf8)
        await git.log?.note("Added \(pattern) to \(path)")
    }

    /// Creates a Cheddar-owned worktree at `.cheddar/worktrees/<name>` (suffixed if taken). Returns its path.
    @discardableResult
    func createWorktree(named name: String, branch: WorktreeBranch, in repo: URL) async throws -> String {
        guard Self.isValidFolderName(name) else {
            throw OperationError(errorDescription: "“\(name)” isn't a usable folder name.")
        }
        try await ensureExcluded(".cheddar/", in: repo)
        let path = availableWorktreePath(named: name, in: repo)
        switch branch {
        case .new(let newBranch, let base):
            try await git.output(["worktree", "add", "-b", newBranch, path] + (base.map { [$0] } ?? []), in: repo)
        case .existing(let existing):
            try await git.output(["worktree", "add", path, existing], in: repo)
        }
        return path
    }

    /// `git worktree remove`. `force` is needed when the worktree has uncommitted or untracked changes.
    func removeWorktree(_ worktree: Worktree, force: Bool, in repo: URL) async throws {
        guard worktree.origin != .main else {
            throw OperationError(errorDescription: "The main worktree can't be deleted.")
        }
        try await git.output(["worktree", "remove"] + (force ? ["--force"] : []) + [worktree.path], in: repo)
    }

    /// Moves a Cheddar-owned worktree to `.cheddar/worktrees/<name>`. Other tools track their paths, so
    /// moving their worktrees would break their link to them.
    func moveWorktree(_ worktree: Worktree, toName name: String, in repo: URL) async throws {
        guard worktree.origin == .cheddar else {
            throw OperationError(errorDescription: "Only Cheddar's own worktrees can be moved. \(worktree.origin.label) tracks this folder's path.")
        }
        guard Self.isValidFolderName(name) else {
            throw OperationError(errorDescription: "“\(name)” isn't a usable folder name.")
        }
        let target = availableWorktreePath(named: name, in: repo, excluding: worktree.path)
        guard Paths.canonical(target) != Paths.canonical(worktree.path) else { return }
        try await git.output(["worktree", "move", worktree.path, target], in: repo)
    }

    /// Renames a branch. With `movingWorktree` (Cheddar-owned only), the folder follows the new name;
    /// if that move fails, the branch rename is rolled back.
    func renameBranch(_ old: String, to new: String, movingWorktree worktree: Worktree? = nil, in repo: URL) async throws {
        try await git.output(["branch", "-m", old, new], in: repo)
        guard let worktree else { return }
        do {
            try await moveWorktree(worktree, toName: Self.folderName(forBranch: new), in: repo)
        } catch {
            do {
                try await git.output(["branch", "-m", new, old], in: repo)
            } catch let rollbackFailure {
                throw RollbackError(failure: error, rollbackFailure: rollbackFailure)
            }
            throw error
        }
    }

    func createBranch(_ name: String, base: String?, in repo: URL) async throws {
        try await git.output(["branch", name] + (base.map { [$0] } ?? []), in: repo)
    }

    /// `git branch -d`, or `-D` with `force`. A `GitError` with `isNotFullyMerged` means `-d` refused.
    func deleteBranch(_ name: String, force: Bool, in repo: URL) async throws {
        try await git.output(["branch", force ? "-D" : "-d", name], in: repo)
    }

    /// `git branch -d` on each branch, one at a time. Branches git refuses (unmerged, checked out) are
    /// skipped, never force-deleted. Anything other than a git refusal (git missing, cancellation) stops
    /// the batch and is thrown.
    func deleteBranches(_ names: [String], in repo: URL) async throws -> BranchDeletionResult {
        var result = BranchDeletionResult()
        for name in names {
            do {
                try await deleteBranch(name, force: false, in: repo)
                result.deleted.append(name)
            } catch let error as GitError {
                result.skipped.append(.init(name: name, reason: error.localizedDescription, isUnmerged: error.isNotFullyMerged))
            }
        }
        return result
    }

    /// Clean Up: prunes missing worktrees, then deletes branches with `-d` (after the prunes, so a branch
    /// whose only checkout was a missing worktree can go too). A refusal from git skips that item.
    func cleanUp(pruning worktrees: [Worktree], deletingBranches names: [String], in repo: URL) async throws -> BranchDeletionResult {
        var pruned: [String] = []
        var notPruned: [BranchDeletionResult.Skipped] = []
        for worktree in worktrees {
            do {
                try await prune(worktree, in: repo)
                pruned.append(worktree.displayName)
            } catch let error as GitError {
                notPruned.append(.init(name: worktree.displayName, reason: error.localizedDescription, isUnmerged: false))
            }
        }
        var result = try await deleteBranches(names, in: repo)
        result.pruned = pruned
        result.skipped.insert(contentsOf: notPruned, at: 0)
        return result
    }
}

/// What a bulk `git branch -d` (or Clean Up, which also prunes) did.
struct BranchDeletionResult: Equatable {
    struct Skipped: Equatable, Identifiable {
        var id: String { name }
        var name: String
        /// git's error.
        var reason: String
        /// `-d` refused because it isn't fully merged, so `-D` is offered.
        var isUnmerged: Bool
    }

    /// Missing worktrees pruned by Clean Up, by display name.
    var pruned: [String] = []
    var deleted: [String] = []
    /// Branches, and worktrees Clean Up couldn't prune.
    var skipped: [Skipped] = []
}
