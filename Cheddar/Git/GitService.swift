import Foundation

struct RepoSnapshot {
    var trunk: String?
    /// Main worktree first, then Cheddar-owned, then the others by origin.
    var worktrees: [Worktree]
    var branches: [Branch]
    /// Folders that point into this repo but that git doesn't list at their path.
    var orphans: [OrphanFolder] = []
    /// Exclude patterns Cheddar offers to add (discovery roots showing as untracked in the main checkout).
    var unexcludedRoots: [String] = []
    /// From `git remote`.
    var remotes: [String] = []
    /// Remote-tracking branches, sorted by ref (so grouped by remote).
    var remoteBranches: [RemoteBranch] = []
    /// When this repo last fetched, from any worktree. nil if it never has.
    var lastFetch: Date?

    var mainWorktree: Worktree? { worktrees.first { $0.origin == .main } }

    func worktree(checkingOut branch: String) -> Worktree? {
        worktrees.first { $0.branch == branch }
    }

    /// The remote branch this branch tracks, if its upstream is a remote branch that exists locally
    /// (a `[gone]` upstream has none). Linked by the configured upstream only, never by a matching name.
    func trackedRemote(of branch: Branch) -> RemoteBranch? {
        guard let ref = branch.upstreamRef else { return nil }
        return remoteBranches.first { $0.ref == ref }
    }

    /// Remote branches that no local branch tracks.
    var untrackedRemoteBranches: [RemoteBranch] {
        let tracked = Set(branches.compactMap(\.upstreamRef))
        return remoteBranches.filter { !tracked.contains($0.ref) }
    }
}

/// High-level git operations. The only caller of GitRunner.
struct GitService {
    let git: GitRunner
    var codexHome = OriginClassifier.defaultCodexHome
    /// Settings → Discovery; checked after the built-in roots.
    var extraLocations: [DiscoveryLocation] = []
    /// The project's trunk override, if set.
    var trunkOverride: String?

    func classifier(mainPath: String) -> OriginClassifier {
        OriginClassifier(mainPath: mainPath, codexHome: codexHome, extraLocations: extraLocations)
    }

    func snapshot(of repo: URL) async throws -> RepoSnapshot {
        async let branchList = branches(in: repo)
        async let trunkName = trunk(in: repo)
        async let remoteNames = remotes(in: repo)
        async let common = commonDir(of: repo)
        var worktrees = try await worktrees(in: repo)
        let orphans = try await orphanFolders(in: repo, listed: worktrees)
        async let unexcluded = unexcludedRoots(in: repo, worktrees: worktrees, orphans: orphans)
        let trunk = try await trunkName
        var branches = try await branchList
        try await addStatus(to: &worktrees, branches: &branches, trunk: trunk, in: repo)
        let remotes = try await remoteNames
        return try await RepoSnapshot(
            trunk: trunk, worktrees: worktrees, branches: branches,
            orphans: orphans, unexcludedRoots: unexcluded,
            remotes: remotes,
            remoteBranches: remoteBranches(in: repo, remotes: remotes),
            lastFetch: Self.lastFetch(commonDir: common)
        )
    }

    func worktrees(in repo: URL) async throws -> [Worktree] {
        var worktrees = GitParsers.worktrees(try await git.output(["worktree", "list", "--porcelain", "-z"], in: repo))
        guard let first = worktrees.first else { return [] }
        let classifier = classifier(mainPath: first.path)
        for index in worktrees.indices {
            // Git always lists the main working tree first (unless the repo is bare).
            let (origin, name) = index == 0 && !first.isBare
                ? (origin: WorktreeOrigin.main, name: (first.path as NSString).lastPathComponent)
                : classifier.classify(worktrees[index].path)
            worktrees[index].origin = origin
            worktrees[index].displayName = name
            worktrees[index].isMissing = !FileManager.default.fileExists(atPath: worktrees[index].path)
        }
        return worktrees.sorted {
            if $0.origin.sortRank != $1.origin.sortRank { return $0.origin.sortRank < $1.origin.sortRank }
            if $0.origin != $1.origin { return $0.origin.label < $1.origin.label }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    /// The main working tree of the repo containing `folder`, whether `folder` is the repo, a subfolder,
    /// or a linked worktree. Git lists the main working tree first, which also covers submodules and
    /// separate git dirs where the common dir's parent isn't the working tree.
    func mainWorktreePath(containing folder: URL) async throws -> String {
        let worktrees = GitParsers.worktrees(try await git.output(["worktree", "list", "--porcelain", "-z"], in: folder))
        guard let main = worktrees.first, !main.isBare else { throw BareRepositoryError() }
        return Paths.canonical(main.path)
    }

    func branches(in repo: URL) async throws -> [Branch] {
        GitParsers.branches(try await git.output(["for-each-ref", "refs/heads", "--format=\(GitParsers.branchFormat)"], in: repo))
    }

    /// The override if set, else `origin/HEAD`, else `main`, else `master`.
    func trunk(in repo: URL) async throws -> String? {
        if let trunkOverride, !trunkOverride.isEmpty { return trunkOverride }
        let originHead = try await git.run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: repo)
        let remoteTrunk = originHead.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if originHead.exitCode == 0, remoteTrunk.hasPrefix("origin/") {
            return String(remoteTrunk.dropFirst("origin/".count))
        }
        for name in ["main", "master"] {
            if try await git.run(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: repo).exitCode == 0 {
                return name
            }
        }
        return nil
    }
}
