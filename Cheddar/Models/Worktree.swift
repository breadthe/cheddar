import Foundation

struct Worktree: Identifiable, Hashable {
    var id: String { path }

    // From `git worktree list --porcelain -z`
    var path: String
    var head: String?
    /// Short branch name (without `refs/heads/`); nil when detached or bare.
    var branch: String?
    var isDetached = false
    var isBare = false
    var isLocked = false
    var lockedReason: String?
    var isPrunable = false
    var prunableReason: String?

    // Filled in by GitService
    var origin: WorktreeOrigin = .external
    /// Path relative to the discovery root it sits under (Codex nests worktrees as `<id>/<repo>`),
    /// else the folder name.
    var displayName = ""
    /// Git lists the worktree but its folder is gone.
    var isMissing = false
    /// Uncommitted changes; nil when missing or not read.
    var status: WorktreeStatus?
    /// HEAD's subject and date, for detached worktrees (branch rows carry their own).
    var headSubject: String?
    var headDate: Date?

    var shortHead: String? { head.map { String($0.prefix(7)) } }
}

/// Counts from `git status --porcelain=v2`.
struct WorktreeStatus: Hashable {
    var staged = 0
    var unstaged = 0
    var untracked = 0
    var conflicts = 0

    var isClean: Bool { staged == 0 && unstaged == 0 && untracked == 0 && conflicts == 0 }
}
