import SwiftUI

struct WorktreeRow: View {
    let worktree: Worktree
    /// The branch checked out here, for ahead/behind and last commit.
    let branch: Branch?
    let trunk: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if worktree.isMissing {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Missing")
                } else {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                }
                Text(worktree.displayName)
                    .lineLimit(1)
                OriginBadge(origin: worktree.origin)
                if let branchName = worktree.branch {
                    Text(branchName)
                        .monospaced()
                        .foregroundStyle(GitColors.branch(checkedOutIn: worktree))
                        .lineLimit(1)
                } else if worktree.isDetached {
                    Text("detached")
                        .fontWeight(.semibold)
                        .foregroundStyle(GitColors.head)
                    if let sha = worktree.shortHead {
                        Text(sha)
                            .monospaced()
                            .foregroundStyle(GitColors.sha)
                    }
                }
                Spacer()
                if worktree.isLocked {
                    Image(systemName: "lock")
                        .foregroundStyle(.secondary)
                        .help(worktree.lockedReason ?? "Locked")
                        .accessibilityLabel("Locked")
                }
                if worktree.isMissing {
                    Text("missing")
                        .foregroundStyle(.secondary)
                } else if let status = worktree.status {
                    ChangeCounts(status: status)
                }
            }
            if !worktree.isMissing {
                detailLine
            }
        }
        .help(worktree.path)
    }

    /// `↑4 ↓1 vs main · subject · 2h ago`
    @ViewBuilder
    private var detailLine: some View {
        let subject = branch?.subject ?? worktree.headSubject
        let date = branch?.lastCommitDate ?? worktree.headDate
        HStack(spacing: 6) {
            if let branch, let trunk {
                AheadBehind(ahead: branch.trunkAhead ?? 0, behind: branch.trunkBehind ?? 0, against: trunk)
            }
            if let subject, !subject.isEmpty {
                Text(subject).lineLimit(1).truncationMode(.tail)
            }
            if let date {
                Text("·")
                Text(date, format: .relative(presentation: .named)).fixedSize()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 24)
    }
}

/// Uncommitted changes in git's status colors, each with its own symbol so color isn't the only signal.
struct ChangeCounts: View {
    let status: WorktreeStatus

    var body: some View {
        HStack(spacing: 8) {
            if status.isClean {
                count(symbol: "checkmark.circle", text: "clean", color: GitColors.clean, help: "No uncommitted changes")
            } else {
                if status.conflicts > 0 {
                    count(symbol: "exclamationmark.triangle.fill", text: "\(status.conflicts)", color: GitColors.conflict,
                          help: "\(status.conflicts) with merge conflicts")
                        .fontWeight(.bold)
                }
                if status.staged > 0 {
                    count(symbol: "plus.circle", text: "\(status.staged)", color: GitColors.staged, help: "\(status.staged) staged")
                }
                if status.unstaged > 0 {
                    count(symbol: "pencil.circle", text: "\(status.unstaged)", color: GitColors.unstaged, help: "\(status.unstaged) modified, not staged")
                }
                if status.untracked > 0 {
                    count(symbol: "questionmark.circle", text: "\(status.untracked)", color: GitColors.untracked, help: "\(status.untracked) untracked")
                }
            }
        }
        .font(.callout)
        .monospacedDigit()
    }

    private func count(symbol: String, text: String, color: Color, help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
            Text(text)
        }
        .foregroundStyle(color)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }
}

/// `↑3 ↓1 vs main`: ↑ commits this branch adds (green), ↓ commits it's missing (red). Hidden when even.
struct AheadBehind: View {
    let ahead: Int
    let behind: Int
    var against: String?

    var body: some View {
        if ahead > 0 || behind > 0 {
            HStack(spacing: 3) {
                if ahead > 0 { Text("↑\(ahead)").foregroundStyle(GitColors.ahead) }
                if behind > 0 { Text("↓\(behind)").foregroundStyle(GitColors.behind) }
                if let against { Text("vs \(against)").foregroundStyle(.secondary) }
            }
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(ahead) ahead, \(behind) behind\(against.map { " \($0)" } ?? "")")
        }
    }
}

/// Small neutral capsule for labels like origins, "merged" and "trunk".
struct TagBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

struct OriginBadge: View {
    let origin: WorktreeOrigin

    var body: some View {
        TagBadge(text: origin.label)
    }
}

/// A folder that points into this repo but isn't listed by git at its path.
struct OrphanRow: View {
    let orphan: OrphanFolder

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
                .accessibilityLabel("Orphaned")
            Text(orphan.displayName)
                .lineLimit(1)
            OriginBadge(origin: orphan.origin)
            Text("orphaned")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .help(orphan.isRepairable
            ? "\(orphan.path)\nIts .git file points into this repo, but git lists this worktree somewhere else (the folder was probably moved). Repair relinks it."
            : "\(orphan.path)\nIts .git file points into this repo, but git no longer has an entry for it, so it can't be repaired.")
    }
}

/// Offers (never forces) adding a discovery root to `.git/info/exclude`.
struct ExcludeOfferRow: View {
    let pattern: String
    let add: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            (Text(pattern).monospaced() + Text(" shows as untracked in the main checkout."))
                .lineLimit(2)
            Spacer()
            Button("Add to .git/info/exclude", action: add)
            Button("Not Now", action: dismiss)
                .buttonStyle(.borderless)
        }
    }
}
