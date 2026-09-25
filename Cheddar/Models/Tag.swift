import Foundation

struct Tag: Identifiable, Hashable {
    var id: String { name }

    var name: String
    /// The tag's own object: the tag object for an annotated tag, the commit for a lightweight one.
    /// This is what `git ls-remote` reports, so it's what's compared with the remotes.
    var sha: String
    var isAnnotated: Bool
    /// The tagger date for an annotated tag, the commit date for a lightweight one.
    var date: Date?
    /// The tag message's subject for an annotated tag, the commit's for a lightweight one.
    var subject: String
}

/// What each remote has under `refs/tags` (remote → tag name → object), from `git ls-remote --tags` at the
/// last Fetch. Tags have no remote-tracking refs, so this is the only way to know.
typealias RemoteTags = [String: [String: String]]

/// Remote tag lists from each project's last Fetch this session, by project path. Owned by RootView, so they
/// survive switching projects, which replaces the ProjectModel. Only used from the main actor.
final class RemoteTagCache {
    var byProject: [String: RemoteTags] = [:]
}

/// A row in the Tags section: a local tag, a tag only on remotes, and how it compares with each remote.
struct TagEntry: Identifiable, Hashable {
    var id: String { name }

    var name: String
    /// nil when the tag is only on remotes.
    var local: Tag?
    /// nil until a Fetch this session compared tags with the remotes.
    var status: Status?

    struct Status: Hashable {
        /// Remotes with the same tag object.
        var on: [String] = []
        /// Remotes whose tag of this name is a different object.
        var differsOn: [String] = []
        /// Remotes without it.
        var missingFrom: [String] = []
        /// What each remote that has it points at; the lease for deleting it there.
        var remoteObjects: [String: String] = [:]
    }

    /// Local tags in their order (newest first), then tags only on remotes, by name. Remotes missing from
    /// `remoteTags` (added since the last Fetch) aren't compared.
    static func entries(local: [Tag], remoteTags: RemoteTags?, remotes: [String]) -> [TagEntry] {
        guard let remoteTags else { return local.map { TagEntry(name: $0.name, local: $0) } }
        let checked = remotes.filter { remoteTags[$0] != nil }
        func status(_ name: String, sha: String?) -> Status {
            var status = Status()
            for remote in checked {
                guard let object = remoteTags[remote]?[name] else {
                    status.missingFrom.append(remote)
                    continue
                }
                status.remoteObjects[remote] = object
                if sha == nil || object == sha { status.on.append(remote) } else { status.differsOn.append(remote) }
            }
            return status
        }
        let localNames = Set(local.map(\.name))
        let remoteOnly = Set(checked.flatMap { remoteTags[$0]?.keys.map { $0 } ?? [] })
            .subtracting(localNames)
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        return local.map { TagEntry(name: $0.name, local: $0, status: status($0.name, sha: $0.sha)) }
            + remoteOnly.map { TagEntry(name: $0, status: status($0, sha: nil)) }
    }
}
