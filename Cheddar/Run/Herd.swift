import Foundation

/// Laravel Herd, used by Run when main is one of its sites: the worktree gets its own site, linked like
/// main's (HTTPS, PHP version) and unlinked again when it stops (see specs.md → Run).
struct Herd {
    /// A Herd site: `<name>.<tld>`.
    struct Site: Equatable {
        var name: String
        var tld: String
        var isSecure: Bool
        /// The PHP version the site is pinned to (`herd isolate`), if any.
        var phpVersion: String?

        var url: URL { URL(string: "\(isSecure ? "https" : "http")://\(name).\(tld)")! }
    }

    static let binDirectory = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Herd/bin")
    static let configDirectory = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Herd/config/valet")

    let executable: String
    let searchPath: [String]
    var configDirectory = Herd.configDirectory

    /// The `herd` CLI on the search path, else in Herd's own bin folder.
    static func locate(searchPath: [String]) -> Herd? {
        let candidates = (searchPath + [binDirectory]).map { ($0 as NSString).appendingPathComponent("herd") }
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        return Herd(executable: executable, searchPath: searchPath)
    }

    // MARK: Reading Herd's config

    /// The site serving `path`: a link to it, else its folder in a parked directory.
    func site(servingPath path: String) -> Site? {
        let target = Paths.canonical(path)
        let name = links.first(where: { $0.path == target })?.name
            ?? (parkedPaths.contains(Paths.canonical((target as NSString).deletingLastPathComponent))
                ? (target as NSString).lastPathComponent : nil)
        guard let name else { return nil }
        let host = "\(name).\(tld)"
        let nginx = try? String(contentsOfFile: (configDirectory as NSString).appendingPathComponent("Nginx/\(host)"), encoding: .utf8)
        let certificate = (configDirectory as NSString).appendingPathComponent("Certificates/\(host).crt")
        return Site(
            name: name,
            tld: tld,
            isSecure: FileManager.default.fileExists(atPath: certificate),
            phpVersion: nginx.flatMap(Self.phpVersion(inNginxConfig:))
        )
    }

    /// `<main site>-<worktree>`, lowercased to letters, digits and dashes, with a number added if another
    /// site already has the name. A dotted name like `<worktree>.<site>` would be caught by the main
    /// site's `*.<site>.test` nginx server name.
    func siteName(for worktreeName: String, of site: Site) -> String {
        let slug = worktreeName.lowercased()
            .replacing(#/[^a-z0-9]+/#, with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = slug.isEmpty ? site.name : "\(site.name)-\(slug)"
        let taken = Set(links.map(\.name))
        var name = base
        var suffix = 2
        while taken.contains(name) {
            name = "\(base)-\(suffix)"
            suffix += 1
        }
        return name
    }

    /// `fastcgi_pass $herd_sock_84;` → `8.4`.
    static func phpVersion(inNginxConfig config: String) -> String? {
        guard let match = config.firstMatch(of: #/herd_sock_(\d)(\d+)/#) else { return nil }
        return "\(match.output.1).\(match.output.2)"
    }

    private var tld: String {
        (config?["tld"] as? String) ?? "test"
    }

    private var parkedPaths: Set<String> {
        Set(((config?["paths"] as? [String]) ?? []).map(Paths.canonical))
    }

    /// Links are symlinks in `Sites/`, named after the site.
    private var links: [(name: String, path: String)] {
        let sites = (configDirectory as NSString).appendingPathComponent("Sites")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sites)) ?? []
        return names.compactMap { name in
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(
                atPath: (sites as NSString).appendingPathComponent(name)) else { return nil }
            return (name, Paths.canonical(destination))
        }
    }

    private var config: [String: Any]? {
        guard let data = FileManager.default.contents(atPath: (configDirectory as NSString).appendingPathComponent("config.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Commands

    /// Links the folder as `name`, like `site` (HTTPS, PHP version), and points `APP_URL` in its `.env` at it.
    func link(_ name: String, at path: String, like site: Site, log: CommandLog?) async throws {
        var arguments = ["link", "--no-interaction", "--update-env"]
        if site.isSecure { arguments.append("--secure") }
        if let version = site.phpVersion { arguments.append("--isolate=\(version)") }
        arguments.append(name)
        try await run(arguments, in: path, log: log)
    }

    /// Removes the link, its certificate, nginx config and PHP version pin (`herd unlink` does all of it).
    func unlink(_ name: String, log: CommandLog?) async throws {
        try await run(["unlink", "--no-interaction", name], in: NSHomeDirectory(), log: log)
    }

    /// The app's environment with the user's PATH plus Herd's bin (for its `php` and `composer`). The
    /// herd CLI needs more than PATH and HOME: it crashes without USER, for one.
    static func environment(searchPath: [String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("__XPC_")
        }
        environment["PATH"] = (searchPath + [binDirectory]).joined(separator: ":")
        return environment
    }

    private func run(_ arguments: [String], in directory: String, log: CommandLog?) async throws {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        let result: Result<ProcessOutput, Error>
        do {
            result = .success(try await ProcessRunner.run(URL(fileURLWithPath: executable), arguments, in: url,
                                                          environment: Self.environment(searchPath: searchPath), timeout: 60))
        } catch {
            result = .failure(error)
        }
        await log?.record(program: "herd", arguments: arguments, directory: url, result: result)
        let output = try result.get()
        guard output.exitCode == 0 else {
            let message = [output.stderrString, output.stdoutString]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            throw OperationError(errorDescription: "herd \(arguments.first ?? "") failed: \(message ?? "exit \(output.exitCode)")")
        }
    }
}
