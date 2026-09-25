import Foundation
import Observation

enum ProjectSheet: Identifiable {
    /// `existingBranch` preselects "Existing branch" (from a branch row's **+ Worktree**).
    case newWorktree(existingBranch: String?)
    case newBranch(base: String?)
    case rename(RenameRequest)
    case deleteWorktree(Worktree, changes: [String])
    case handoff(HandoffPreflight)
    case adopt(Worktree)

    var id: String {
        switch self {
        case .newWorktree(let branch): "new-worktree-\(branch ?? "")"
        case .newBranch(let base): "new-branch-\(base ?? "")"
        case .rename(let request): "rename-\(request.id)"
        case .deleteWorktree(let worktree, _): "delete-\(worktree.path)"
        case .handoff(let preflight): "handoff-\(preflight.worktree.path)"
        case .adopt(let worktree): "adopt-\(worktree.path)"
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

    init(project: Project, service: GitService) {
        self.project = project
        self.service = service
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

    // MARK: Remotes

    /// Fetches every remote (with prune). Runs as a mutation: one at a time, then a refresh.
    func fetch() async {
        do {
            try await mutate { try await service.fetch(in: repo) }
        } catch let error as GitError where error.needsCredentials {
            alert = AppAlert(title: "Couldn't fetch", message: error.localizedDescription + "\n\n" + Self.credentialsHelp)
        } catch {
            report(error, title: "Couldn't fetch")
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
