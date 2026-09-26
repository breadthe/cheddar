import Foundation
import Observation

/// The inspector's content for the selected row: a worktree's uncommitted changes and its commits, or a
/// branch's commits; and the diff of the selected file or commit (see specs.md → Inspector).
@Observable @MainActor
final class InspectorModel {
    enum Target: Hashable {
        /// `nested`: linked worktrees inside it, left out of its changes (for main).
        case worktree(Worktree, nested: [String])
        case branch(Branch)
    }

    enum Item: Hashable {
        case file(ChangedFile)
        case commit(Commit)
    }

    /// nil for a branch (it has no working tree).
    private(set) var files: [ChangedFile]?
    private(set) var commits: [Commit] = []
    /// What `commits` are: "Not on main" (the range), or "Recent" when nothing is ahead of trunk.
    private(set) var commitsTitle = "Commits"
    private(set) var selected: Item?
    private(set) var diff: [DiffLine] = []
    private(set) var isDiffTruncated = false
    private(set) var error: String?

    @ObservationIgnored private let service: GitService
    @ObservationIgnored private var directory = ""

    init(service: GitService) {
        self.service = service
    }

    /// Loads the lists, keeping the selection if it's still there (so auto-refresh doesn't lose it),
    /// else selecting the first changed file.
    func load(_ target: Target, trunk: String?, repo: String) async {
        error = nil
        do {
            let ref: String
            switch target {
            case .worktree(let worktree, let nested):
                directory = worktree.path
                ref = "HEAD"
                files = try await service.changedFiles(at: worktree.path, excludingNested: nested)
            case .branch(let branch):
                directory = repo
                ref = branch.name
                files = nil
            }
            let isTrunk = ref == trunk || (ref == "HEAD" && target.branchName == trunk)
            var list: [Commit] = []
            if let trunk, !isTrunk {
                list = try await service.commits(on: ref, excluding: trunk, in: directory)
            }
            if list.isEmpty {
                commits = try await service.commits(on: ref, limit: 20, in: directory)
                commitsTitle = "Recent commits"
            } else {
                commits = list
                commitsTitle = "Not on \(trunk ?? "trunk")"
            }
        } catch {
            self.error = error.localizedDescription
            files = files == nil ? nil : []
            commits = []
        }
        let stillThere: Item? = switch selected {
        case .file(let file): files?.first { $0.path == file.path }.map(Item.file)
        case .commit(let commit): commits.contains(commit) ? .commit(commit) : nil
        case nil: nil
        }
        await select(stillThere ?? files?.first.map(Item.file))
    }

    func select(_ item: Item?) async {
        selected = item
        guard let item else {
            diff = []
            isDiffTruncated = false
            return
        }
        do {
            let output = switch item {
            case .file(let file): try await service.diff(of: file, at: directory)
            case .commit(let commit): try await service.show(commit.sha, in: directory)
            }
            guard selected == item else { return }
            (diff, isDiffTruncated) = DiffLine.parse(output)
        } catch {
            guard selected == item else { return }
            (diff, isDiffTruncated) = DiffLine.parse(error.localizedDescription)
        }
    }
}

private extension InspectorModel.Target {
    var branchName: String? {
        if case .worktree(let worktree, _) = self { return worktree.branch }
        return nil
    }
}
