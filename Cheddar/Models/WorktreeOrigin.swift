import Foundation

/// Which tool made a worktree, decided by its path.
enum WorktreeOrigin: Hashable {
    case main, cheddar, claude, codex
    /// An extra discovery location from Settings, with its label.
    case custom(String)
    case external

    /// The built-in origins, in display order (custom ones sort between codex and external).
    static let builtIn: [WorktreeOrigin] = [.main, .cheddar, .claude, .codex, .external]

    var label: String {
        switch self {
        case .main: "main"
        case .cheddar: "cheddar"
        case .claude: "claude"
        case .codex: "codex"
        case .custom(let label): label
        case .external: "external"
        }
    }

    /// Display order: main first, then Cheddar-owned, then the others.
    var sortRank: Int {
        switch self {
        case .main: 0
        case .cheddar: 1
        case .claude: 2
        case .codex: 3
        case .custom: 4
        case .external: 5
        }
    }

    /// Worktrees made by another tool, whose paths Cheddar must not move.
    var isForeign: Bool { sortRank >= 2 }

    /// Who to name in "may lose track of" warnings.
    var toolName: String {
        switch self {
        case .main, .cheddar: "Cheddar"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .custom(let label): label
        case .external: "the tool that made it"
        }
    }
}

/// An extra discovery location from Settings → Discovery (e.g. Conductor's workspaces).
struct DiscoveryLocation: Codable, Hashable, Identifiable {
    var id = UUID()
    /// Absolute (`/…` or `~/…`) or relative to the repo.
    var path: String
    var label: String

    var rule: OriginRule? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let label = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !label.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return OriginRule(root: expanded.hasPrefix("/") ? .absolute(expanded) : .repo(trimmed), origin: .custom(label))
    }
}

/// Origin rules as data: a path prefix plus the origin it maps to. First match wins.
struct OriginRule {
    enum Root {
        /// Relative to the main working tree.
        case repo(String)
        case absolute(String)
    }

    var root: Root
    var origin: WorktreeOrigin
}

struct OriginClassifier {
    let rules: [(prefix: String, origin: WorktreeOrigin)]

    init(mainPath: String, rules: [OriginRule]) {
        let main = Paths.canonical(mainPath)
        self.rules = rules.map { rule in
            switch rule.root {
            case .repo(let relative): (prefix: Paths.canonical((main as NSString).appendingPathComponent(relative)), origin: rule.origin)
            case .absolute(let path): (prefix: Paths.canonical(path), origin: rule.origin)
            }
        }
    }

    init(mainPath: String, codexHome: String, extraLocations: [DiscoveryLocation] = []) {
        self.init(mainPath: mainPath, rules: Self.defaultRules(codexHome: codexHome) + extraLocations.compactMap(\.rule))
    }

    static func defaultRules(codexHome: String) -> [OriginRule] {
        [
            OriginRule(root: .repo(".cheddar/worktrees"), origin: .cheddar),
            OriginRule(root: .repo(".claude/worktrees"), origin: .claude),
            OriginRule(root: .absolute((codexHome as NSString).appendingPathComponent("worktrees")), origin: .codex),
            OriginRule(root: .repo(".codex"), origin: .codex),
        ]
    }

    /// `$CODEX_HOME`, usually unset for GUI apps, else `~/.codex`.
    static var defaultCodexHome: String {
        ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }

    /// Origin and display name of a linked worktree. The main worktree is identified by git (first entry), not by path.
    func classify(_ path: String) -> (origin: WorktreeOrigin, name: String) {
        let path = Paths.canonical(path)
        guard let rule = rules.first(where: { path.hasPrefix($0.prefix + "/") }) else {
            return (.external, (path as NSString).lastPathComponent)
        }
        return (rule.origin, String(path.dropFirst(rule.prefix.count + 1)))
    }
}

enum Paths {
    /// Resolves symlinks (e.g. `/var` → `/private/var`) so prefixes compare reliably.
    /// Works for paths that no longer exist by resolving the longest existing ancestor.
    static func canonical(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let resolved = realpath(existing.path, nil) else { return path }
        defer { free(resolved) }
        return missing.reduce(String(cString: resolved)) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// `path` relative to `root` by string prefix only (no file-system access), for hot paths
    /// where both are already canonical.
    static func relativeLexically(_ path: String, under root: String) -> String? {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
    }

    /// `path` relative to `root` when it's inside it, else nil. Both are canonicalized first.
    static func relative(_ path: String, under root: String) -> String? {
        let path = canonical(path)
        let root = canonical(root)
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
    }
}
