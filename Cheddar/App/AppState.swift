import Foundation
import Observation

@Observable @MainActor
final class AppState {
    /// Sorted by name.
    private(set) var projects: [Project] = []
    /// Remembered across launches.
    var selection: Project.ID? {
        didSet { defaults.set(selection, forKey: Self.selectionKey) }
    }
    /// Drives the folder picker (sidebar **+**, File → Add Project…).
    var isAddingProject = false
    /// The ⌘K palette.
    var isShowingPalette = false
    /// Set by the palette; the project view with that ID carries it out, then clears it.
    var reveal: RevealRequest?
    var alert: AppAlert?

    var selectedProject: Project? { projects.first { $0.id == selection } }

    private static let selectionKey = "selectedProject"
    private let storeURL: URL
    private let defaults: UserDefaults

    init(storeURL: URL = AppState.defaultStoreURL, defaults: UserDefaults = .standard) {
        self.storeURL = storeURL
        self.defaults = defaults
        projects = Self.load(from: storeURL)
        let remembered = defaults.string(forKey: Self.selectionKey)
        selection = projects.contains { $0.id == remembered } ? remembered : projects.first?.id
    }

    /// `~/Library/Application Support/Cheddar/projects.json`
    nonisolated static var defaultStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "Cheddar/projects.json")
    }

    /// Adds the repo containing `folder`, resolved to its main worktree, and selects it. Duplicates are ignored.
    func addProject(at folder: URL, using service: GitService) async throws {
        let path = try await service.mainWorktreePath(containing: folder)
        if !projects.contains(where: { $0.path == path }) {
            var updated = projects
            updated.append(Project(path: path))
            try save(updated)
        }
        selection = path
    }

    /// Sets or clears (nil) the project's trunk override.
    func setTrunk(_ trunk: String?, for project: Project) throws {
        try update(project) { $0.trunk = trunk }
    }

    /// Sets Run's dev command for the project; blank goes back to detecting it.
    func setDevCommand(_ command: String, for project: Project) throws {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        try update(project) { $0.devCommand = trimmed.isEmpty ? nil : trimmed }
    }

    /// Removes the project from Cheddar's list. Never touches disk.
    func removeProject(_ project: Project) throws {
        try save(projects.filter { $0.id != project.id })
        if selection == project.id { selection = projects.first?.id }
    }

    /// Changes one project's settings, keeping the others.
    private func update(_ project: Project, _ change: (inout Project) -> Void) throws {
        try save(projects.map {
            guard $0.id == project.id else { return $0 }
            var updated = $0
            change(&updated)
            return updated
        })
    }

    /// Writes first, so the in-memory list never shows something that isn't saved.
    private func save(_ updated: [Project]) throws {
        let sorted = updated.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(sorted).write(to: storeURL, options: .atomic)
        projects = sorted
    }

    /// A file that can't be decoded is moved aside rather than overwritten by the next save.
    private static func load(from url: URL) -> [Project] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([Project].self, from: data)
        } catch {
            let aside = url.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return []
        }
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}
