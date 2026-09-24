import Foundation
import Observation

@Observable @MainActor
final class DependencyStore {
    static let gitOverrideKey = "gitPath"

    private(set) var searchPath = SearchPath.system
    private(set) var statuses: [Dependency.ID: DependencyStatus] = [:]
    private(set) var isChecking = false
    private(set) var lastCheck: Date?
    private var didResolvePath = false
    private let log: CommandLog

    init(log: CommandLog) {
        self.log = log
    }

    var hasChecked: Bool { lastCheck != nil }
    var hasHomebrew: Bool { statuses[Dependencies.homebrew.id]?.isAvailable ?? false }

    var missingRequired: [Dependency] {
        Dependencies.all.filter { $0.isRequired && !(statuses[$0.id]?.isAvailable ?? false) }
    }

    /// Only set while git is found and new enough.
    var git: GitRunner? {
        guard case .found(let path, _) = statuses[Dependencies.git.id] else { return nil }
        return GitRunner(executable: URL(fileURLWithPath: path), searchPath: searchPath, log: log)
    }

    /// Checks every registry entry. With `force: false` (app became active) it rechecks at most every 30 seconds.
    func check(force: Bool = true) async {
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < 30 { return }
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        if !didResolvePath {
            searchPath = await SearchPath.resolve()
            didResolvePath = true
        }
        let checker = DependencyChecker(
            searchPath: searchPath,
            gitOverride: UserDefaults.standard.string(forKey: Self.gitOverrideKey)
        )
        statuses = await withTaskGroup(of: (Dependency.ID, DependencyStatus).self) { group in
            for dependency in Dependencies.all {
                group.addTask { (dependency.id, await checker.status(of: dependency)) }
            }
            return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        lastCheck = Date()
    }
}
