import Foundation

/// What the ⌘K palette lists: every project, and every worktree and local branch in every project
/// (see specs.md → Command palette).
enum PaletteItem: Identifiable, Hashable {
    case project(Project)
    case worktree(Worktree, in: Project)
    case branch(Branch, in: Project)

    var id: String {
        switch self {
        case .project(let project): "p:\(project.id)"
        case .worktree(let worktree, let project): "w:\(project.id):\(worktree.path)"
        case .branch(let branch, let project): "b:\(project.id):\(branch.name)"
        }
    }

    var project: Project {
        switch self {
        case .project(let project), .worktree(_, let project), .branch(_, let project): project
        }
    }

    /// The project view's row tag to select, if any.
    var rowTag: String? {
        switch self {
        case .project: nil
        case .worktree(let worktree, _): "w:\(worktree.path)"
        case .branch(let branch, _): "b:\(branch.name)"
        }
    }

    /// What typing is matched against.
    var searchText: String {
        switch self {
        case .project(let project): project.name
        case .worktree(let worktree, let project): "\(project.name) \(worktree.displayName) \(worktree.branch ?? "")"
        case .branch(let branch, let project): "\(project.name) \(branch.name)"
        }
    }
}

/// A project's worktrees and local branches, read when the palette opens.
struct PaletteContents {
    var worktrees: [Worktree] = []
    var branches: [Branch] = []
}

/// Picked in the palette: the project view switches to this project, then selects the row (a worktree's
/// `w:<path>` or a branch's `b:<name>`, if any) once the project has loaded, and clears the request.
struct RevealRequest: Equatable {
    var projectID: Project.ID
    var rowTag: String?
}

enum PaletteMatcher {
    /// nil if the query's characters (ignoring spaces and case) don't all appear in `text`, in order.
    /// Higher is better: matches at word starts and runs of consecutive characters score more, gaps less.
    static func score(_ query: String, in text: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(text.lowercased())
        var score = 0
        var index = 0
        var previous: Int?
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return nil }
            let atWordStart = found == 0 || !(haystack[found - 1].isLetter || haystack[found - 1].isNumber)
            if atWordStart { score += 10 }
            if let previous, found == previous + 1 { score += 5 } else if let previous { score -= min(found - previous - 1, 5) }
            previous = found
            index = found + 1
        }
        return score
    }

    /// Matching items, best first; ties keep their order. An empty query keeps them all.
    static func filter(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items.enumerated()
            .compactMap { offset, item in score(query, in: item.searchText).map { (item, $0, offset) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }

    /// Worktrees, then branches, then projects; within each, the selected project's first.
    static func items(projects: [Project], contents: [Project.ID: PaletteContents], selected: Project.ID?) -> [PaletteItem] {
        let ordered = projects.filter { $0.id == selected } + projects.filter { $0.id != selected }
        let worktrees = ordered.flatMap { project in (contents[project.id]?.worktrees ?? []).map { PaletteItem.worktree($0, in: project) } }
        let branches = ordered.flatMap { project in (contents[project.id]?.branches ?? []).map { PaletteItem.branch($0, in: project) } }
        return worktrees + branches + ordered.map(PaletteItem.project)
    }
}
