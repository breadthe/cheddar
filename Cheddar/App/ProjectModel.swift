import Foundation
import Observation

enum ProjectSheet: Identifiable {
    /// `existingBranch` preselects "Existing branch" (from a branch row's **+ Worktree**).
    case newWorktree(existingBranch: String?)
    case newBranch(base: String?)
    /// Delete Selected… in Branches.
    case deleteBranches([Branch])
    case rename(RenameRequest)
    case deleteWorktree(Worktree, changes: [String])
    case handoff(HandoffPreflight)
    case adopt(Worktree)
    case trackRemote(RemoteBranch)
    /// `onRemotes`: the remotes that have it, or nil when no Fetch this session has checked.
    case renameTag(Tag, onRemotes: [String]?)
    /// Run's dev command for the project. `then`: run this worktree once it's saved.
    case devCommand(then: Worktree?)

    var id: String {
        switch self {
        case .newWorktree(let branch): "new-worktree-\(branch ?? "")"
        case .newBranch(let base): "new-branch-\(base ?? "")"
        case .deleteBranches: "delete-branches"
        case .rename(let request): "rename-\(request.id)"
        case .deleteWorktree(let worktree, _): "delete-\(worktree.path)"
        case .handoff(let preflight): "handoff-\(preflight.worktree.path)"
        case .adopt(let worktree): "adopt-\(worktree.path)"
        case .trackRemote(let remote): "track-\(remote.ref)"
        case .renameTag(let tag, _): "rename-tag-\(tag.name)"
        case .devCommand(let worktree): "dev-command-\(worktree?.path ?? "")"
        }
    }
}

enum RenameRequest: Identifiable {
    /// Rename a branch. If it's checked out in a Cheddar-owned linked worktree, that folder follows the
    /// new name; `askToMove` (from the branch row) offers renaming the branch only instead.
    case branch(String, checkedOutIn: Worktree?, askToMove: Bool)
    /// Move a detached Cheddar worktree's folder.
    case folder(Worktree)

    var id: String {
        switch self {
        case .branch(let name, _, _): "branch-\(name)"
        case .folder(let worktree): "folder-\(worktree.path)"
        }
    }
}

/// A tag on one remote, as the last Fetch saw it.
struct RemoteTagRef: Identifiable, Hashable {
    var id: String { "\(remote)/\(name)" }
    var name: String
    var remote: String
    var sha: String
}

/// One project's repo state and the operations on it. Runs one mutation at a time and refreshes after each.
@Observable @MainActor
final class ProjectModel {
    let project: Project
    let service: GitService

    private(set) var snapshot: RepoSnapshot?
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var isBusy = false
    /// Set when git itself couldn't be launched; the view asks DependencyStore to re-check.
    private(set) var toolMissing = false

    var sheet: ProjectSheet?
    var alert: AppAlert?
    var branchToDelete: Branch?
    /// `git branch -d` refused this branch; offer `-D` with a warning.
    var unmergedBranch: String?
    /// Asks before deleting a branch on its remote.
    var remoteBranchToDelete: RemoteBranch?
    var tagToDelete: Tag?
    var remoteTagToDelete: RemoteTagRef?
    /// Each remote's tags as of the last Fetch this session; nil before one. Kept in `remoteTagCache` too,
    /// so switching projects doesn't lose it.
    private(set) var remoteTags: RemoteTags? {
        didSet { remoteTagCache.byProject[project.path] = remoteTags }
    }
    @ObservationIgnored private let remoteTagCache: RemoteTagCache
    /// App-wide, so a run outlives this model (switching projects rebuilds it).
    @ObservationIgnored let runs: RunManager?
    /// Asks before moving an orphaned folder to the Trash.
    var orphanToTrash: OrphanFolder?
    /// Exclude offers the user chose "Not Now" for, this session.
    var dismissedExcludes: Set<String> = []

    var excludeOffers: [String] {
        (snapshot?.unexcludedRoots ?? []).filter { !dismissedExcludes.contains($0) }
    }

    private var repo: URL { project.url }

    // Auto-refresh state
    private static let debounce = Duration.milliseconds(300)
    private static let maxDebounce: TimeInterval = 2
    @ObservationIgnored private var reloadQueued = false
    /// Bumped on every full load, so a slower per-worktree refresh can't overwrite newer data.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var commonDir: String?
    @ObservationIgnored private var watcher: RepoWatcher?
    @ObservationIgnored private var watcherPaths: [String] = []
    @ObservationIgnored private var watchedWorktrees: [String] = []
    @ObservationIgnored private var watchedRoots: [String] = []
    @ObservationIgnored private var pendingScope = RefreshScope.none
    @ObservationIgnored private var pendingSince: Date?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    init(project: Project, service: GitService, remoteTagCache: RemoteTagCache = RemoteTagCache(), runs: RunManager? = nil) {
        self.project = project
        self.service = service
        self.remoteTagCache = remoteTagCache
        self.runs = runs
        remoteTags = remoteTagCache.byProject[project.path]
    }

    /// The Tags section's rows: local tags compared with `remoteTags`, plus tags only on remotes.
    var tagEntries: [TagEntry] {
        guard let snapshot else { return [] }
        return TagEntry.entries(local: snapshot.tags, remoteTags: remoteTags, remotes: snapshot.remotes)
    }

    /// Loads the whole snapshot. Overlapping requests are coalesced into one more pass.
    func load() async {
        guard !isBusy else { return }
        guard !isLoading else {
            reloadQueued = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        repeat {
            reloadQueued = false
            do {
                let fresh = try await service.snapshot(of: repo)
                snapshot = fresh
                generation += 1
                loadError = nil
                await updateWatcher(for: fresh)
                await runs?.reconcile(projectPath: project.path,
                                      presentWorktrees: Set(fresh.worktrees.filter { !$0.isMissing }.map(\.path)))
            } catch is CancellationError {
            } catch {
                noteToolMissing(error)
                snapshot = nil
                loadError = error.localizedDescription
            }
        } while reloadQueued && !isBusy
    }

    // MARK: Auto-refresh

    /// Watches the git common dir, every worktree root and the discovery roots.
    private func updateWatcher(for snapshot: RepoSnapshot) async {
        guard let main = snapshot.mainWorktree else { return }
        if commonDir == nil { commonDir = try? await service.commonDir(of: repo) }
        guard let commonDir else { return }
        let mainPath = Paths.canonical(main.path)
        watchedWorktrees = snapshot.worktrees.filter { !$0.isMissing }.map { Paths.canonical($0.path) }
        watchedRoots = service.classifier(mainPath: main.path).rules.map(\.prefix)
        let outsideMain = ([commonDir] + watchedWorktrees + watchedRoots).filter {
            $0 != mainPath && Paths.relativeLexically($0, under: mainPath) == nil
        }
        let paths = [mainPath] + Array(Set(outsideMain)).sorted()
        guard paths != watcherPaths else { return }
        watcherPaths = paths
        watcher = RepoWatcher(paths: paths) { [weak self] changed in
            MainActor.assumeIsolated { self?.filesChanged(changed) }
        }
    }

    private func filesChanged(_ changed: [String]) {
        guard let commonDir else { return }
        let scope = RepoWatcher.route(changed, commonDir: commonDir, worktrees: watchedWorktrees, discoveryRoots: watchedRoots)
        switch (pendingScope, scope) {
        case (_, .none): return
        case (.full, _), (_, .full): pendingScope = .full
        case (.worktrees(let a), .worktrees(let b)): pendingScope = .worktrees(a.union(b))
        case (.none, let new): pendingScope = new
        }
        // Debounce ~300 ms, but don't let a steady stream of changes (a build) postpone it forever.
        let now = Date()
        if let pendingSince, now.timeIntervalSince(pendingSince) > Self.maxDebounce, debounceTask != nil { return }
        if pendingSince == nil { pendingSince = now }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.flushChanges()
        }
    }

    private func flushChanges() async {
        let scope = pendingScope
        pendingScope = .none
        pendingSince = nil
        debounceTask = nil
        // A refresh never runs during a mutation; the reload after it covers these changes.
        guard !isBusy else { return }
        switch scope {
        case .none: break
        case .full: await load()
        case .worktrees(let paths): await refreshStatus(of: paths)
        }
    }

    /// Re-reads just these worktrees' changes, unless a full load replaces the snapshot meanwhile.
    private func refreshStatus(of paths: Set<String>) async {
        guard var updated = snapshot, !isLoading else { return }
        let startGeneration = generation
        let linked = updated.worktrees.filter { $0.origin != .main }.map(\.path)
        for index in updated.worktrees.indices where paths.contains(Paths.canonical(updated.worktrees[index].path)) {
            let worktree = updated.worktrees[index]
            let summary = await service.statusSummary(of: worktree, nested: worktree.origin == .main ? linked : [])
            updated.worktrees[index].status = summary.status
            updated.worktrees[index].headSubject = summary.subject
            updated.worktrees[index].headDate = summary.date
        }
        guard generation == startGeneration, !isBusy else { return }
        snapshot = updated
    }

    // MARK: Worktrees

    func createWorktree(named name: String, branch: WorktreeBranch) async throws {
        if case .new(let newBranch, _) = branch { try await validateBranchName(newBranch) }
        try await mutate { try await service.createWorktree(named: name, branch: branch, in: repo) }
    }

    /// Loads the worktree's uncommitted changes, then opens the delete confirmation.
    func requestDelete(_ worktree: Worktree) async {
        guard worktree.origin != .main else { return }
        var changes: [String] = []
        if !worktree.isMissing {
            do {
                changes = try await service.changes(at: worktree.path)
            } catch {
                report(error, title: "Couldn't check \(worktree.displayName) for changes")
                return
            }
        }
        sheet = .deleteWorktree(worktree, changes: changes)
    }

    func deleteWorktree(_ worktree: Worktree, force: Bool, alsoDeleteBranch: Bool) async throws {
        try await mutate { try await service.removeWorktree(worktree, force: force, in: repo) }
        if alsoDeleteBranch, let branch = worktree.branch {
            await deleteBranch(branch, force: false)
        }
    }

    /// Runs the hand-off preflight, then opens the confirmation sheet.
    func requestHandoff(_ worktree: Worktree) async {
        guard worktree.origin != .main, !worktree.isMissing else { return }
        do {
            sheet = .handoff(try await service.handoffPreflight(for: worktree, in: repo))
        } catch {
            report(error, title: "Couldn't check \(worktree.displayName) for hand off")
        }
    }

    func handOff(_ worktree: Worktree, newBranch: String?, stashMainChanges: Bool) async throws {
        if worktree.branch == nil, let newBranch { try await validateBranchName(newBranch) }
        try await mutate {
            try await service.handOff(worktree, newBranch: newBranch, stashMainChanges: stashMainChanges, in: repo)
        }
    }

    func moveFolder(of worktree: Worktree, to name: String) async throws {
        try await mutate { try await service.moveWorktree(worktree, toName: name, in: repo) }
    }

    // MARK: Discovery

    func repair(_ orphan: OrphanFolder) async {
        await run("Couldn't repair \(orphan.displayName)") { try await service.repair(orphan, in: repo) }
    }

    func prune(_ worktree: Worktree) async {
        await run("Couldn't prune \(worktree.displayName)") { try await service.prune(worktree, in: repo) }
    }

    func moveToTrash(_ orphan: OrphanFolder) async {
        await run("Couldn't move \(orphan.displayName) to the Trash") { try await service.moveToTrash(orphan) }
    }

    func adopt(_ worktree: Worktree, as name: String) async throws {
        try await mutate { try await service.adopt(worktree, as: name, in: repo) }
    }

    func exclude(_ pattern: String) async {
        await run("Couldn't update .git/info/exclude") { try await service.ensureExcluded(pattern, in: repo) }
    }

    // MARK: Open in

    func open(_ path: String, in app: ExternalApp) async {
        do {
            try await OpenIn.open(path, in: app)
            await service.git.log?.note("Opened \(path) in \(app.name)")
        } catch {
            report(error, title: "Couldn't open in \(app.name)")
        }
    }

    func openClaudeCode(in path: String) async {
        do {
            try OpenIn.claudeCode(in: path)
            await service.git.log?.note("Started Claude Code in Terminal at \(path)")
        } catch {
            report(error, title: "Couldn't start Claude Code")
        }
    }

    // MARK: Run

    /// Runs the worktree like main (see `RunManager`). Not a mutation: it doesn't wait for, or block, git operations.
    func run(_ worktree: Worktree, devCommand: String, searchPath: [String]) async {
        await runs?.run(worktree, projectPath: project.path, devCommand: devCommand, service: service, searchPath: searchPath)
    }

    // MARK: Branches

    func createBranch(_ name: String, base: String?) async throws {
        try await validateBranchName(name)
        try await mutate { try await service.createBranch(name, base: base, in: repo) }
    }

    func renameBranch(_ old: String, to new: String, movingWorktree worktree: Worktree?) async throws {
        guard new != old else { return }
        try await validateBranchName(new)
        try await mutate { try await service.renameBranch(old, to: new, movingWorktree: worktree, in: repo) }
    }

    /// `-d` first; if git says the branch isn't fully merged, `unmergedBranch` asks before `-D`.
    func deleteBranch(_ name: String, force: Bool) async {
        do {
            try await mutate { try await service.deleteBranch(name, force: force, in: repo) }
        } catch let error as GitError where error.isNotFullyMerged && !force {
            unmergedBranch = name
        } catch {
            report(error, title: "Couldn't delete \(name)")
        }
    }

    /// Branches checked for Delete Selected…. Kept here, not in the view, so the batch can clear them.
    var checkedBranches: Set<String> = []

    /// The checked branches that can still be deleted: they exist and aren't checked out anywhere.
    var branchesToDelete: [Branch] {
        guard let snapshot else { return [] }
        return snapshot.branches.filter { checkedBranches.contains($0.name) && snapshot.worktree(checkingOut: $0.name) == nil }
    }

    /// `-d` on each branch as one mutation; unmerged ones are skipped, and the result says which.
    func deleteBranches(_ names: [String]) async throws -> BranchDeletionResult {
        var result = BranchDeletionResult()
        try await mutate { result = try await service.deleteBranches(names, in: repo) }
        checkedBranches = []
        return result
    }

    /// `-D` for a branch the bulk delete skipped. Throws, so the summary sheet can show why it failed.
    func forceDeleteBranch(_ name: String) async throws {
        try await mutate { try await service.deleteBranch(name, force: true, in: repo) }
    }

    // MARK: Remotes

    /// Fetches every remote (with prune), then lists each remote's tags. Runs as a mutation: one at a time,
    /// then a refresh.
    func fetch() async {
        await runNetwork("Couldn't fetch") {
            try await service.fetch(in: repo)
            remoteTags = try await service.remoteTags(in: repo)
        }
    }

    func deleteRemoteBranch(_ remote: RemoteBranch) async {
        await runNetwork("Couldn't delete \(remote.shortName)") { try await service.deleteRemoteBranch(remote, in: repo) }
    }

    func createTrackingBranch(_ name: String, from remote: RemoteBranch) async throws {
        try await validateBranchName(name)
        try await mutate { try await service.createTrackingBranch(name, from: remote, in: repo) }
    }

    // MARK: Tags

    func deleteTag(_ tag: Tag) async {
        await run("Couldn't delete tag \(tag.name)") { try await service.deleteTag(tag.name, in: repo) }
    }

    func renameTag(_ tag: Tag, to newName: String) async throws {
        guard newName != tag.name else { return }
        guard try await service.isValidTagName(newName, in: repo) else {
            throw OperationError(errorDescription: "“\(newName)” isn't a valid tag name.")
        }
        try await mutate { try await service.renameTag(tag, to: newName, in: repo) }
    }

    func pushTag(_ tag: Tag, to remote: String) async {
        await runNetwork("Couldn't push tag \(tag.name) to \(remote)") {
            try await service.pushTag(tag.name, to: remote, in: repo)
            remoteTags?[remote]?[tag.name] = tag.sha
        }
    }

    func fetchTag(_ name: String, from remote: String) async {
        await runNetwork("Couldn't fetch tag \(name) from \(remote)") {
            try await service.fetchTag(name, from: remote, in: repo)
        }
    }

    func deleteRemoteTag(_ ref: RemoteTagRef) async {
        await runNetwork("Couldn't delete tag \(ref.name) on \(ref.remote)") {
            try await service.deleteRemoteTag(ref.name, expecting: ref.sha, on: ref.remote, in: repo)
            remoteTags?[ref.remote]?[ref.name] = nil
        }
    }

    /// A mutation that talks to a remote: failures become an alert, with advice when git needed credentials.
    private func runNetwork(_ title: String, _ operation: () async throws -> Void) async {
        do {
            try await mutate(operation)
        } catch let error as GitError where error.needsCredentials {
            alert = AppAlert(title: title, message: error.localizedDescription + "\n\n" + Self.credentialsHelp)
        } catch {
            report(error, title: title)
        }
    }

    static let credentialsHelp = "Cheddar can't answer password, passphrase or host key prompts. "
        + "Check that `git fetch` works in Terminal without asking for anything, using a credential helper or an SSH agent."

    // MARK: Helpers

    func report(_ error: Error, title: String) {
        alert = AppAlert(title: title, message: error.localizedDescription)
    }

    /// A mutation with no sheet to show errors in: failures become an alert.
    private func run(_ title: String, _ operation: () async throws -> Void) async {
        do {
            try await mutate(operation)
        } catch {
            report(error, title: title)
        }
    }

    private func validateBranchName(_ name: String) async throws {
        guard try await service.isValidBranchName(name, in: repo) else {
            throw OperationError(errorDescription: "“\(name)” isn't a valid branch name.")
        }
    }

    /// Runs one mutation at a time, then refreshes whether it succeeded or not.
    private func mutate(_ operation: () async throws -> Void) async throws {
        guard !isBusy else { throw OperationError(errorDescription: "Another operation is still running.") }
        isBusy = true
        do {
            try await operation()
        } catch {
            noteToolMissing(error)
            isBusy = false
            await load()
            throw error
        }
        isBusy = false
        await load()
    }

    private func noteToolMissing(_ error: Error) {
        if isToolMissing(error) { toolMissing = true }
    }
}
