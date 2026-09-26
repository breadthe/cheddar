import Foundation

/// Disk usage and build artifacts in worktrees (see specs.md → Disk usage & build artifacts).
enum DiskUsage {
    /// Bytes allocated for everything under `path`, not following symlinks (so Run's links to main's
    /// database and uploads don't count) and skipping `excluded` folders (linked worktrees nested in main).
    /// APFS clones (Run's copies of `vendor/`, `node_modules/`) count in full, though they share blocks
    /// with main: the total is an upper bound.
    static func size(of path: String, excluding excluded: Set<String> = []) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true), includingPropertiesForKeys: keys, options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if !excluded.isEmpty, excluded.contains(url.path) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A regenerable folder in a worktree: dependencies or build output.
struct BuildArtifact: Identifiable, Hashable {
    var id: String { path }
    /// Relative to the worktree.
    var path: String
    var size: Int64
}

enum BuildArtifacts {
    /// Folders that hold installed dependencies, build output or tool caches, relative to the worktree root.
    /// Never `.env`, databases or uploads. Only offered when git ignores them there.
    static let candidates = [
        "node_modules", "vendor", "dist", "build", "out", "target", "coverage",
        ".next", ".nuxt", ".svelte-kit", ".astro", ".turbo", ".parcel-cache", ".cache",
        "public/build",
    ]

    /// The candidates present in the worktree as real folders (not Run's symlinks).
    static func present(in worktree: String) -> [String] {
        candidates.filter { relative in
            let path = (worktree as NSString).appendingPathComponent(relative)
            guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }
}
