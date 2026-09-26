import Foundation

/// What Run does in a worktree, worked out from the files in it and in main (see specs.md → Run).
/// Pure file checks, so it's testable without running anything.
enum RunRecipe {
    /// Installed dependencies, and how to reinstall them from a lockfile without changing it.
    struct Ecosystem {
        var lockfile: String
        var dependencies: String
        var install: String
    }

    static let ecosystems = [
        Ecosystem(lockfile: "composer.lock", dependencies: "vendor", install: "composer install"),
        Ecosystem(lockfile: "package-lock.json", dependencies: "node_modules", install: "npm ci"),
        Ecosystem(lockfile: "pnpm-lock.yaml", dependencies: "node_modules", install: "pnpm install --frozen-lockfile"),
        Ecosystem(lockfile: "yarn.lock", dependencies: "node_modules", install: "yarn install --frozen-lockfile"),
        Ecosystem(lockfile: "bun.lock", dependencies: "node_modules", install: "bun install --frozen-lockfile"),
        Ecosystem(lockfile: "bun.lockb", dependencies: "node_modules", install: "bun install --frozen-lockfile"),
    ]

    /// Top-level things in main a worktree needs but git never gives it: env files and installed
    /// dependencies. The caller still checks they're missing from the worktree and ignored there.
    static func cloneCandidates(inMain main: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: main)) ?? []
        return names.filter { name in
            name.hasPrefix(".env") && !isDirectory((main as NSString).appendingPathComponent(name))
                || name == "vendor" || name == "node_modules"
        }
        .sorted()
    }

    /// A SQLite database file (not its `-wal`/`-shm`/`-journal` companions), by extension.
    static func isDatabase(_ path: String) -> Bool {
        ["sqlite", "sqlite3", "db", "db3"].contains((path as NSString).pathExtension.lowercased())
    }

    /// Where the app keeps uploaded files, by stack: Laravel's `storage/app/` plus `public/storage` (its
    /// `storage:link`), Rails' `storage/` (Active Storage), Django's `media/`. Not all of Laravel's
    /// `storage/`: `framework/` holds compiled views and caches with main's paths in them.
    static func uploadRoots(in path: String) -> [String] {
        let has = { FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent($0)) }
        if has("artisan") { return ["storage/app/", "public/storage"] }
        if has("bin/rails") { return ["storage/"] }
        if has("manage.py") { return ["media/"] }
        return []
    }

    /// Whether one of main's ignored entries (as `git ls-files --directory` lists them: folders end in `/`)
    /// is data the worktree should share with main through a link: a SQLite database, or anything in an
    /// upload root.
    static func isSharedData(_ entry: String, uploadRoots: [String]) -> Bool {
        (isDatabase(entry) && !entry.hasSuffix("/"))
            || uploadRoots.contains { root in entry == root || (root.hasSuffix("/") && entry.hasPrefix(root)) }
    }

    /// Installs to run before the dev command: for each lockfile in the worktree whose dependencies are
    /// missing there, or that differs from main's (so the dependencies cloned from main may not match).
    static func installs(worktree: String, main: String) -> [String] {
        var installs: [String] = []
        for ecosystem in ecosystems {
            let lockfile = (worktree as NSString).appendingPathComponent(ecosystem.lockfile)
            guard FileManager.default.fileExists(atPath: lockfile) else { continue }
            let hasDependencies = FileManager.default.fileExists(atPath: (worktree as NSString).appendingPathComponent(ecosystem.dependencies))
            let matchesMain = FileManager.default.contentsEqual(
                atPath: lockfile, andPath: (main as NSString).appendingPathComponent(ecosystem.lockfile))
            if (!hasDependencies || !matchesMain) && !installs.contains(ecosystem.install) {
                installs.append(ecosystem.install)
            }
        }
        return installs
    }

    /// `composer run dev` when composer.json has a dev script, else `<package manager> run dev` when
    /// package.json has one.
    static func devCommand(in path: String) -> String? {
        if scripts(in: (path as NSString).appendingPathComponent("composer.json")).contains("dev") {
            return "composer run dev"
        }
        if scripts(in: (path as NSString).appendingPathComponent("package.json")).contains("dev") {
            return "\(packageManager(in: path)) run dev"
        }
        return nil
    }

    /// Chosen by lockfile; npm when there's none.
    static func packageManager(in path: String) -> String {
        let has = { FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent($0)) }
        if has("pnpm-lock.yaml") { return "pnpm" }
        if has("yarn.lock") { return "yarn" }
        if has("bun.lock") || has("bun.lockb") { return "bun" }
        return "npm"
    }

    /// A Laravel app, whose dev output has two URLs: Vite's (only an asset server) and the app's.
    static func isLaravel(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("artisan"))
    }

    /// The shell script Run executes: each install, then the dev command, each announced with a `$ ` line
    /// (`marker(for:)`, which tells the output reader when the dev command starts). The dev command is
    /// grouped, so one like `a; b` doesn't run `b` after a failed install.
    static func script(installs: [String], devCommand: String) -> String {
        let steps = installs.map { "printf '%s\\n' \(shellQuoted(marker(for: $0))) && \($0)" }
        return (steps + ["printf '%s\\n' \(shellQuoted(marker(for: devCommand))) && {\n\(devCommand)\n}"])
            .joined(separator: " && ")
    }

    static func marker(for command: String) -> String { "$ \(command)" }

    // MARK: Output

    /// The app's URL, if this line of dev-server output announces one. Only local addresses count;
    /// `0.0.0.0` and `[::]` become `localhost`. In a Laravel app only `artisan serve`'s line counts.
    static func url(inOutputLine line: String, laravel: Bool) -> URL? {
        let line = strippingANSI(line)
        if laravel && !line.contains("Server running on") { return nil }
        guard let match = line.firstMatch(of: localURL) else { return nil }
        var text = String(match.output)
        for wildcard in ["//0.0.0.0", "//[::]"] {
            text = text.replacingOccurrences(of: wildcard, with: "//localhost")
        }
        return URL(string: text)
    }

    /// Whether the line announces any local server, e.g. Vite's "Local: http://localhost:5173/".
    static func announcesServer(_ line: String) -> Bool {
        strippingANSI(line).contains(localURL)
    }

    static func strippingANSI(_ text: String) -> String {
        text.replacing(#/\u{1B}\[[0-9;?]*[A-Za-z]/#, with: "")
    }

    private static var localURL: Regex<Substring> {
        #/https?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(?::\d+)?(?:\/[^\s\]\)'"]*)?/#
    }

    // MARK: Helpers

    private static func scripts(in file: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else { return [] }
        return Array(scripts.keys)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
