import AppKit
import Observation

/// One worktree's Run: its dev process, Herd site and output.
@Observable @MainActor
final class RunSession: Identifiable {
    enum Phase: Equatable {
        /// Cloning, linking, installing, or waiting for the server to announce itself.
        case starting
        /// The browser has been opened.
        case running
        /// Stopped from Cheddar.
        case stopped
        /// The dev command ended by itself.
        case exited(Int32)
        /// It couldn't start.
        case failed(String)
    }

    struct Line: Identifiable {
        let id: Int
        let text: String
    }

    /// The worktree's path.
    let id: String
    /// The main worktree's path.
    let projectPath: String
    let name: String
    let devCommand: String
    fileprivate(set) var phase = Phase.starting
    /// The app's URL: the Herd site, or the one the dev server announced.
    fileprivate(set) var url: URL?
    fileprivate(set) var lines: [Line] = []

    var isActive: Bool { phase == .starting || phase == .running }
    var hasFailed: Bool {
        switch phase {
        case .failed: true
        case .exited(let status): status != 0
        default: false
        }
    }

    @ObservationIgnored fileprivate var process: DevProcess?
    @ObservationIgnored fileprivate var herd: Herd?
    @ObservationIgnored fileprivate var herdSite: String?
    @ObservationIgnored fileprivate var isLaravel = false
    @ObservationIgnored fileprivate var devStarted = false
    @ObservationIgnored private var nextLineID = 0

    fileprivate init(worktreePath: String, projectPath: String, name: String, devCommand: String) {
        id = worktreePath
        self.projectPath = projectPath
        self.name = name
        self.devCommand = devCommand
    }

    fileprivate func append(_ text: String) {
        lines.append(Line(id: nextLineID, text: text))
        nextLineID += 1
        if lines.count > RunManager.outputLimit { lines.removeFirst(lines.count - RunManager.outputLimit) }
    }
}

/// Runs worktrees like main: clones main's env files and dependencies into the worktree, links it in
/// Herd when main is a Herd site, runs the dev command and opens the browser (see specs.md → Run).
/// App-wide, so runs survive switching projects; everything is stopped when the app quits.
@Observable @MainActor
final class RunManager {
    static let outputLimit = 5000
    /// With a Herd site, the browser opens this long after the dev command starts if no server has
    /// announced itself by then (a dev command that only watches files, say).
    static let herdOpenDelay = Duration.seconds(15)
    private static let herdLinksKey = "runHerdLinks"

    /// By worktree path.
    private(set) var sessions: [String: RunSession] = [:]
    /// The bottom panel's tab: a session's worktree path, or nil for the command log.
    var panelSelection: String?

    @ObservationIgnored private let log: CommandLog?
    @ObservationIgnored private let defaults: UserDefaults
    /// Opens the app in the browser (replaced in tests).
    @ObservationIgnored private let openURL: (URL) -> Void

    init(log: CommandLog?, defaults: UserDefaults = .standard, openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.log = log
        self.defaults = defaults
        self.openURL = openURL
    }

    var sortedSessions: [RunSession] {
        sessions.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var hasActiveSessions: Bool { sessions.values.contains(where: \.isActive) }

    // MARK: Run

    func run(_ worktree: Worktree, projectPath: String, devCommand: String, service: GitService, searchPath: [String]) async {
        let path = worktree.path
        if sessions[path]?.isActive == true { return }
        let session = RunSession(worktreePath: path, projectPath: projectPath, name: worktree.displayName, devCommand: devCommand)
        session.isLaravel = RunRecipe.isLaravel(path)
        sessions[path] = session
        if panelSelection != nil { panelSelection = path }
        do {
            try await cloneFromMain(into: session, service: service)
            try await linkSharedData(into: session, service: service)
            let installs = RunRecipe.installs(worktree: path, main: projectPath)
            if let herd = Herd.locate(searchPath: searchPath), let site = herd.site(servingPath: projectPath) {
                try await link(session, herd: herd, like: site)
            }
            guard session.phase == .starting else { return await cleanUpHerd(session) }
            let script = RunRecipe.script(installs: installs, devCommand: devCommand)
            session.process = try DevProcess.start(
                script, in: path, environment: Self.environment(searchPath: searchPath),
                onLine: { [weak self, weak session] line in
                    // `main.async` keeps the lines in order.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, let session else { return }
                            self.received(line, in: session)
                        }
                    }
                },
                onExit: { [weak self, weak session] status in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, let session else { return }
                            Task { await self.exited(session, status: status) }
                        }
                    }
                })
            log?.note("Run: started “\(script)” in \(path)")
        } catch {
            session.phase = .failed(error.localizedDescription)
            session.append("✗ \(error.localizedDescription)")
            await cleanUpHerd(session)
        }
    }

    /// Stops the dev process (its whole process group) and removes the Herd site.
    func stop(_ path: String) async {
        guard let session = sessions[path], session.isActive else { return }
        session.phase = .stopped
        if let process = session.process {
            process.terminate()
            await process.waitForExit()
        }
        await cleanUpHerd(session)
        session.append("Stopped.")
        log?.note("Run: stopped \(session.name)")
    }

    func stopAll() async {
        await withTaskGroup(of: Void.self) { group in
            for path in sessions.keys {
                group.addTask { await self.stop(path) }
            }
        }
    }

    /// Stops runs of this project's worktrees that are gone (deleted, handed off, moved), however that happened.
    func reconcile(projectPath: String, presentWorktrees: Set<String>) async {
        for session in sessions.values where session.projectPath == projectPath && session.isActive
            && !presentWorktrees.contains(session.id) {
            await stop(session.id)
        }
    }

    /// Forgets a session that isn't running, closing its output tab.
    func close(_ path: String) {
        guard sessions[path]?.isActive == false else { return }
        sessions[path] = nil
        if panelSelection == path { panelSelection = nil }
    }

    /// Removes Herd sites left by runs that didn't stop cleanly (Cheddar crashed or was killed).
    /// Every recorded site belongs to a run, and none survive a relaunch.
    func removeLeftoverHerdLinks(searchPath: [String]) async {
        let leftovers = herdLinks.keys.filter { name in !sessions.values.contains { $0.herdSite == name } }
        guard !leftovers.isEmpty, let herd = Herd.locate(searchPath: searchPath) else { return }
        for name in leftovers {
            try? await herd.unlink(name, log: log)
            herdLinks[name] = nil
        }
    }

    // MARK: Steps

    /// Clones what main has and the worktree lacks (`.env*`, `vendor`, `node_modules`), when git ignores it
    /// in the worktree, so nothing shows up as a change. APFS clones: instant, and no extra disk until
    /// either copy changes. They live in the worktree folder and go away with it.
    private func cloneFromMain(into session: RunSession, service: GitService) async throws {
        let main = session.projectPath
        let missing = RunRecipe.cloneCandidates(inMain: main).filter {
            !FileManager.default.fileExists(atPath: (session.id as NSString).appendingPathComponent($0))
        }
        let asPaths = missing.map { name -> String in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: (main as NSString).appendingPathComponent(name), isDirectory: &isDirectory)
            return isDirectory.boolValue ? name + "/" : name
        }
        let ignored = try await service.ignoredPaths(asPaths, in: session.id)
        for (name, path) in zip(missing, asPaths) where ignored.contains(path) {
            let source = (main as NSString).appendingPathComponent(name)
            let destination = (session.id as NSString).appendingPathComponent(name)
            try await Task.detached { try Self.clone(source, to: destination) }.value
            session.append("Cloned \(name) from main")
            log?.note("Run: cloned \(source) to \(destination)")
        }
    }

    /// Symlinks main's data that git ignores into the worktree at the same relative path, so the two
    /// share it: SQLite databases (e.g. `database/database.sqlite`, whichever way the config names it;
    /// SQLite resolves the link, so its WAL and journal files stay next to main's file) and uploaded files
    /// (`RunRecipe.uploadRoots`). Only what the worktree lacks and also ignores. Removing the worktree
    /// removes the links, never main's files.
    private func linkSharedData(into session: RunSession, service: GitService) async throws {
        let main = session.projectPath
        let roots = RunRecipe.uploadRoots(in: session.id)
        let entries = try await service.ignoredEntries(in: main).filter { entry in
            let link = (session.id as NSString).appendingPathComponent(entry)
            return RunRecipe.isSharedData(entry, uploadRoots: roots)
                && (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == nil
                && !FileManager.default.fileExists(atPath: link)
        }
        let ignored = try await service.ignoredPaths(entries, in: session.id)
        for entry in entries where ignored.contains(entry) {
            let relative = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            let source = (main as NSString).appendingPathComponent(relative)
            let link = (session.id as NSString).appendingPathComponent(relative)
            try FileManager.default.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: source)
            session.append("Linked \(relative) to main's")
            log?.note("Run: linked \(link) to \(source)")
        }
    }

    nonisolated private static func clone(_ source: String, to destination: String) throws {
        // Falls back to a plain copy off APFS (or across volumes).
        if clonefile(source, destination, UInt32(CLONE_NOFOLLOW)) == 0 { return }
        try FileManager.default.copyItem(atPath: source, toPath: destination)
    }

    private func link(_ session: RunSession, herd: Herd, like site: Herd.Site) async throws {
        let name = herd.siteName(for: session.name, of: site)
        // Recorded first, so a crash mid-link is still cleaned up on the next launch.
        herdLinks[name] = session.id
        do {
            try await herd.link(name, at: session.id, like: site, log: log)
        } catch {
            herdLinks[name] = nil
            throw error
        }
        session.herd = herd
        session.herdSite = name
        session.url = Herd.Site(name: name, tld: site.tld, isSecure: site.isSecure).url
        session.append("Linked \(session.url!.absoluteString) in Herd")
    }

    private func received(_ line: String, in session: RunSession) {
        let text = RunRecipe.strippingANSI(line)
        session.append(text)
        guard session.phase == .starting else { return }
        if text == RunRecipe.marker(for: session.devCommand) {
            session.devStarted = true
            if session.herdSite != nil {
                Task {
                    try? await Task.sleep(for: Self.herdOpenDelay)
                    if session.phase == .starting { self.open(session) }
                }
            }
            return
        }
        guard session.devStarted else { return }
        if session.herdSite != nil {
            if RunRecipe.announcesServer(text) { open(session) }
        } else if let url = RunRecipe.url(inOutputLine: text, laravel: session.isLaravel) {
            session.url = url
            open(session)
        }
    }

    private func open(_ session: RunSession) {
        guard session.phase == .starting, let url = session.url else { return }
        session.phase = .running
        openURL(url)
        log?.note("Run: opened \(url.absoluteString) for \(session.name)")
    }

    private func exited(_ session: RunSession, status: Int32) async {
        session.process = nil
        guard session.isActive else { return }
        session.phase = .exited(status)
        session.append("Exited with status \(status).")
        await cleanUpHerd(session)
        log?.note("Run: \(session.name) exited with status \(status)")
    }

    private func cleanUpHerd(_ session: RunSession) async {
        guard let herd = session.herd, let name = session.herdSite else { return }
        session.herdSite = nil
        do {
            try await herd.unlink(name, log: log)
            herdLinks[name] = nil
        } catch {
            // Stays recorded, so the next launch tries again.
            session.append("✗ Couldn't remove the Herd site \(name): \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    /// Site name → worktree path, for every Herd site a run has linked and not yet removed.
    private var herdLinks: [String: String] {
        get { (defaults.dictionary(forKey: Self.herdLinksKey) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Self.herdLinksKey) }
    }

    /// Herd's (the app's, with the user's PATH and Herd's bin), with colors off: the output panel shows plain text.
    private static func environment(searchPath: [String]) -> [String: String] {
        var environment = Herd.environment(searchPath: searchPath)
        environment["NO_COLOR"] = "1"
        environment["FORCE_COLOR"] = "0"
        environment["TERM"] = "dumb"
        return environment
    }
}
