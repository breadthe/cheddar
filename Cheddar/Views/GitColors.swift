import SwiftUI

/// Status colors, following git's default terminal colors. System colors only, so they adapt to
/// light/dark and Increase Contrast. Color is never the only signal: rows always carry text or a symbol too.
enum GitColors {
    /// `color.branch.current`: checked out in the main worktree.
    static let currentBranch = Color.green
    /// `color.branch.worktree`: checked out in another worktree.
    static let worktreeBranch = Color.cyan
    /// `color.branch.local`
    static let localBranch = Color.primary
    /// `color.branch.upstream`
    static let upstream = Color.blue
    /// `color.branch.remote`
    static let remoteBranch = Color.red
    /// `color.decorate.HEAD` (detached HEAD)
    static let head = Color.cyan
    /// `color.diff.commit`
    static let sha = yellow
    /// `color.decorate.tag`
    static let tag = yellow
    /// Yellow, darkened to orange in light mode so it stays readable.
    private static let yellow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .systemYellow : .systemOrange
    })

    /// `color.status.added`
    static let staged = Color.green
    /// `color.status.changed`
    static let unstaged = Color.red
    /// `color.status.untracked`
    static let untracked = Color.red
    /// `color.status.unmerged` (shown bold, with ⚠)
    static let conflict = Color.red
    /// Not colored by git. Cheddar's convention: commits to add are green, commits missing are red.
    static let ahead = Color.green
    static let behind = Color.red
    static let clean = Color.secondary

    /// Diff lines: `color.diff.new` green, `color.diff.old` red, `color.diff.frag` cyan, `color.diff.commit`
    /// yellow; `color.diff.meta` is bold, shown bold and primary.
    static func diff(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green
        case .removed: .red
        case .hunk: .cyan
        case .commit: sha
        case .meta: .primary
        case .context: .secondary
        }
    }

    /// Command log words: `git` and the subcommand in the accent color, flags secondary, the rest primary.
    static func command(_ role: CommandToken.Role) -> Color {
        switch role {
        case .program, .subcommand: .accentColor
        case .flag: .secondary
        case .argument: .primary
        }
    }

    static func branch(checkedOutIn worktree: Worktree?) -> Color {
        guard let worktree else { return localBranch }
        return worktree.origin == .main ? currentBranch : worktreeBranch
    }
}
