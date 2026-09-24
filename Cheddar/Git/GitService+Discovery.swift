import Foundation

/// A folder under a discovery root whose `.git` file points into this repo's `.git/worktrees/`, but which
/// git doesn't list at that path (moved by hand, or its entry was pruned).
struct OrphanFolder: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var origin: WorktreeOrigin
    var displayName: String
    /// Where the `.git` file points (`<common dir>/worktrees/<id>`).
    var adminPath: String
    /// `git worktree repair` can relink it only while that admin folder still exists.
    var isRepairable: Bool
}

extension GitService {
    /// How deep to look under a discovery root. Codex nests worktrees as `<id>/<repo>`.
    static let scanDepth = 2

    func commonDir(of repo: URL) async throws -> String {
        Paths.canonical(try await git.output(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Scans the discovery roots for orphaned folders. Folders belonging to other repos (common in the
    /// shared Codex root) are skipped: a folder is matched by its `gitdir` pointer, never by its name.
    func orphanFolders(in repo: URL, listed worktrees: [Worktree]) async throws -> [OrphanFolder] {
        guard let main = worktrees.first(where: { $0.origin == .main }) else { return [] }
        let worktreesDir = try await commonDir(of: repo) + "/worktrees/"
        let classifier = classifier(mainPath: main.path)
        let listed = Set(worktrees.map { Paths.canonical($0.path) })
        var seen = Set<String>()
        var orphans: [OrphanFolder] = []
        for root in classifier.rules.map(\.prefix) {
            for folder in Self.foldersWithGitFile(under: root, depth: Self.scanDepth) where seen.insert(folder).inserted {
                guard let pointer = Self.gitdirPointer(of: folder),
                      pointer.hasPrefix(worktreesDir),
                      !listed.contains(folder) else { continue }
                let (origin, name) = classifier.classify(folder)
                orphans.append(OrphanFolder(
                    path: folder,
                    origin: origin,
                    displayName: name,
                    adminPath: pointer,
                    isRepairable: FileManager.default.fileExists(atPath: pointer)
                ))
            }
        }
        return orphans
    }

    /// Relinks a moved worktree folder with its entry in `.git/worktrees`.
    func repair(_ orphan: OrphanFolder, in repo: URL) async throws {
        try await git.output(["worktree", "repair", orphan.path], in: repo)
    }

    /// Drops the entry for one worktree whose folder is gone. (`git worktree prune` would drop every
    /// missing entry at once; `git worktree remove` on a missing path drops just this one.)
    func prune(_ worktree: Worktree, in repo: URL) async throws {
        guard worktree.isMissing, worktree.origin != .main else {
            throw OperationError(errorDescription: "Only worktrees whose folder is missing can be pruned.")
        }
        try await git.output(["worktree", "remove", worktree.path], in: repo)
    }

    /// Moves an orphaned folder to the Trash (never a permanent delete).
    func moveToTrash(_ orphan: OrphanFolder) async throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: orphan.path), resultingItemURL: nil)
        await git.log?.note("Moved \(orphan.path) to the Trash")
    }

    /// Moves another tool's worktree into `.cheddar/worktrees/<name>`, making it Cheddar-owned.
    func adopt(_ worktree: Worktree, as name: String, in repo: URL) async throws {
        guard worktree.origin.isForeign, !worktree.isMissing else {
            throw OperationError(errorDescription: "Only other tools' worktrees can be adopted.")
        }
        guard Self.isValidFolderName(name) else {
            throw OperationError(errorDescription: "“\(name)” isn't a usable folder name.")
        }
        try await ensureExcluded(".cheddar/", in: repo)
        let target = availableWorktreePath(named: name, in: repo)
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try await git.output(["worktree", "move", worktree.path, target], in: repo)
    }

    /// Exclude patterns for discovery roots inside the main checkout that hold worktrees but aren't
    /// ignored, so git shows them as untracked there (e.g. `.claude/worktrees/`). Cheddar offers to add
    /// these to `.git/info/exclude` but never does it unasked.
    func unexcludedRoots(in repo: URL, worktrees: [Worktree], orphans: [OrphanFolder]) async throws -> [String] {
        guard let main = worktrees.first(where: { $0.origin == .main }) else { return [] }
        let classifier = classifier(mainPath: main.path)
        let paths = worktrees.filter { $0.origin != .main }.map(\.path) + orphans.map(\.path)
        var patterns: [String] = []
        for rule in classifier.rules {
            guard let relative = Paths.relative(rule.prefix, under: main.path),
                  paths.contains(where: { Paths.relative($0, under: rule.prefix) != nil }) else { continue }
            let pattern = rule.origin == .cheddar ? ".cheddar/" : relative + "/"
            guard !patterns.contains(pattern) else { continue }
            let ignored = try await git.run(["check-ignore", "-q", pattern], in: URL(fileURLWithPath: main.path))
            if ignored.exitCode == 1 { patterns.append(pattern) }
        }
        return patterns
    }

    // MARK: Folder scan

    /// Directories under `root` (up to `depth` levels) that contain a `.git` *file*, as linked worktrees do.
    static func foldersWithGitFile(under root: String, depth: Int) -> [String] {
        guard depth > 0,
              let children = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        var result: [String] = []
        for child in children.sorted() {
            let path = (root as NSString).appendingPathComponent(child)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let dotGit = (path as NSString).appendingPathComponent(".git")
            var dotGitIsDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &dotGitIsDirectory) {
                if !dotGitIsDirectory.boolValue { result.append(Paths.canonical(path)) }
            } else {
                result += foldersWithGitFile(under: path, depth: depth - 1)
            }
        }
        return result
    }

    /// The canonical target of a worktree's `.git` file (`gitdir: <path>`), resolving relative pointers
    /// (written with `worktree.useRelativePaths`) against the folder.
    static func gitdirPointer(of folder: String) -> String? {
        let file = (folder as NSString).appendingPathComponent(".git")
        guard let contents = try? String(contentsOfFile: file, encoding: .utf8),
              let line = contents.split(whereSeparator: \.isNewline).first,
              line.hasPrefix("gitdir: ") else { return nil }
        let target = String(line.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespaces)
        let absolute = target.hasPrefix("/") ? target : (folder as NSString).appendingPathComponent(target)
        return Paths.canonical(absolute)
    }
}
