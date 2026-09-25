import Foundation

struct Branch: Identifiable, Hashable {
    var id: String { name }

    var name: String
    var sha: String
    /// e.g. `origin/main`
    var upstream: String?
    /// The full upstream ref, e.g. `refs/remotes/origin/main` (or `refs/heads/x` for a local upstream).
    /// This, not a matching name, is what links a local branch to a remote branch.
    var upstreamRef: String? = nil
    /// e.g. `[ahead 1, behind 2]` or `[gone]`
    var upstreamTrack: String?
    var lastCommitDate: Date?
    var subject: String

    // Status at a glance, filled in by GitService.
    /// Commits on this branch that trunk doesn't have, and vice versa. nil for trunk itself or without a trunk.
    var trunkAhead: Int?
    var trunkBehind: Int?
    /// Merged into trunk (and isn't trunk).
    var isMerged = false

    /// Parsed from `upstreamTrack` (`[ahead 1, behind 2]`).
    var upstreamAhead: Int { Self.count("ahead", in: upstreamTrack) }
    var upstreamBehind: Int { Self.count("behind", in: upstreamTrack) }
    /// The upstream branch was deleted on the remote.
    var upstreamGone: Bool { upstreamTrack == "[gone]" }

    private static func count(_ word: String, in track: String?) -> Int {
        guard let track, let range = track.range(of: "\(word) ") else { return 0 }
        return Int(track[range.upperBound...].prefix { $0.isNumber }) ?? 0
    }
}
