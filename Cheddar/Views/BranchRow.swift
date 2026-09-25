import SwiftUI

struct BranchRow: View {
    let branch: Branch
    let checkedOutIn: Worktree?
    let trunk: String?
    /// The remote branch it tracks. When set, that shows as its own row below, with the upstream counts.
    var trackedRemote: RemoteBranch?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            Text(branch.name)
                .monospaced()
                .foregroundStyle(GitColors.branch(checkedOutIn: checkedOutIn))
                .lineLimit(1)
            if branch.name == trunk {
                TagBadge(text: "trunk")
            }
            if let worktree = checkedOutIn {
                Text("→ \(worktree.displayName)")
                    .foregroundStyle(.secondary)
                    .help("Checked out in \(worktree.path)")
            }
            if let upstream = branch.upstream, trackedRemote == nil {
                HStack(spacing: 4) {
                    Text(upstream)
                        .monospaced()
                        .foregroundStyle(GitColors.upstream)
                    if branch.upstreamGone {
                        Text("gone")
                            .foregroundStyle(.secondary)
                            .help("The upstream branch was deleted on the remote")
                    } else {
                        AheadBehind(ahead: branch.upstreamAhead, behind: branch.upstreamBehind)
                    }
                }
                .font(.callout)
                .lineLimit(1)
                .help("Upstream \(upstream)")
            }
            Spacer()
            AheadBehind(ahead: branch.trunkAhead ?? 0, behind: branch.trunkBehind ?? 0)
                .help(trunk.map { "Compared with \($0)" } ?? "")
            if branch.isMerged {
                TagBadge(text: "merged")
                    .help(trunk.map { "Merged into \($0)" } ?? "Merged")
            }
            Text(branch.subject)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let date = branch.lastCommitDate {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }
}

/// A remote-tracking branch. Under its local branch (`trackingBranch` set) it's indented, tagged `remote`,
/// and shows how far the local branch is ahead of or behind it. In Remote Branches it stands alone.
struct RemoteBranchRow: View {
    let remote: RemoteBranch
    var trackingBranch: Branch?

    var body: some View {
        HStack(spacing: 8) {
            if trackingBranch != nil {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
            }
            Text(remote.shortName)
                .monospaced()
                .foregroundStyle(GitColors.remoteBranch)
                .lineLimit(1)
            if let branch = trackingBranch {
                TagBadge(text: "remote")
                    .help("\(branch.name) tracks \(remote.shortName)")
                AheadBehind(ahead: branch.upstreamAhead, behind: branch.upstreamBehind)
                    .font(.callout)
                    .help("\(branch.name) compared with \(remote.shortName), as of the last fetch")
            }
            Spacer()
            Text(remote.subject)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let date = remote.lastCommitDate {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }
}
