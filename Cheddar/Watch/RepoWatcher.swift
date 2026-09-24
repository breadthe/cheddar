import CoreServices
import Foundation

/// What a batch of file-system events should refresh.
enum RefreshScope: Equatable {
    case none
    /// Only these worktrees' uncommitted changes (paths as git lists them).
    case worktrees(Set<String>)
    /// The whole snapshot (refs, HEAD, index, worktree list, discovery roots).
    case full
}

/// Watches a repo's git dir, worktree roots and discovery roots with FSEvents and reports changed
/// directories on the main queue.
final class RepoWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    /// `latency` coalesces bursts before they're delivered; callers debounce on top of it.
    init?(paths: [String], latency: TimeInterval = 0.3, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            watcher.handler((0..<count).compactMap { array[$0] as? String })
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// Decides what to refresh for a batch of changed directories.
    /// - Under the git common dir: a full refresh, except `objects/` and `logs/`, which are ignored.
    /// - A discovery root or a folder one level below it (worktrees appearing or disappearing, or Codex's
    ///   `<id>` folders) that isn't inside a known worktree: a full refresh. Deeper changes there belong
    ///   to other repos' worktrees and are ignored.
    /// - Otherwise the worktree with the longest matching path gets its status refreshed.
    static func route(
        _ changed: [String], commonDir: String, worktrees: [String], discoveryRoots: [String]
    ) -> RefreshScope {
        var refresh = Set<String>()
        for raw in changed {
            let path = trimmed(raw)
            if let inGit = Paths.relativeLexically(path, under: commonDir) ?? (path == commonDir ? "" : nil) {
                if inGit == "objects" || inGit.hasPrefix("objects/") || inGit == "logs" || inGit.hasPrefix("logs/") { continue }
                return .full
            }
            let owner = worktrees
                .filter { path == $0 || path.hasPrefix($0 + "/") }
                .max { $0.count < $1.count }
            for root in discoveryRoots {
                guard owner == nil || owner!.count < root.count else { continue }
                if path == root { return .full }
                if let below = Paths.relativeLexically(path, under: root), !below.contains("/") { return .full }
            }
            if let owner { refresh.insert(owner) }
        }
        return refresh.isEmpty ? .none : .worktrees(refresh)
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
