import Foundation

/// A remote-tracking branch (`refs/remotes/<remote>/<name>`), as of the last fetch.
struct RemoteBranch: Identifiable, Hashable {
    var id: String { ref }

    /// e.g. `refs/remotes/origin/feat/x`
    var ref: String
    /// e.g. `origin`. Remote names can contain slashes too.
    var remote: String
    /// The branch's name on the remote, e.g. `feat/x`.
    var name: String
    var sha: String
    var lastCommitDate: Date?
    var subject: String

    /// e.g. `origin/feat/x`
    var shortName: String { "\(remote)/\(name)" }
}
