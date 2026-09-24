import AppKit

enum DependencyStatus: Equatable {
    case found(path: String, version: Version?)
    case tooOld(path: String, version: Version)
    /// Found, but running it failed (e.g. Xcode's license hasn't been accepted).
    case failed(path: String, message: String)
    case missing

    var isAvailable: Bool {
        if case .found = self { return true }
        return false
    }

    var path: String? {
        switch self {
        case .found(let path, _), .tooOld(let path, _), .failed(let path, _): path
        case .missing: nil
        }
    }
}

struct DependencyChecker {
    /// Directories searched in order; see `SearchPath.resolve()`.
    var searchPath: [String]
    /// Settings override for the git binary.
    var gitOverride: String?

    func status(of dependency: Dependency) async -> DependencyStatus {
        switch dependency.detection {
        case .commandLineTools:
            guard let path = await commandLineToolsPath() else { return .missing }
            return .found(path: path, version: nil)
        case .app(let bundleID):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return .missing }
            return .found(path: url.path, version: nil)
        case .binary(let name):
            guard let path = await locate(name) else { return .missing }
            return await versionStatus(of: path, minimum: dependency.minimumVersion)
        }
    }

    /// Git choice order: the Settings override, then the first match on the search path.
    /// `/usr/bin/git` is skipped without the Command Line Tools: it's a stub that pops Apple's install dialog.
    func locate(_ name: String) async -> String? {
        var candidates = searchPath.map { ($0 as NSString).appendingPathComponent(name) }
        if name == "git", let gitOverride, !gitOverride.isEmpty { candidates.insert(gitOverride, at: 0) }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            if candidate == "/usr/bin/git", await commandLineToolsPath() == nil { continue }
            return candidate
        }
        return nil
    }

    func commandLineToolsPath() async -> String? {
        guard let result = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], timeout: 5),
              result.exitCode == 0 else { return nil }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func versionStatus(of path: String, minimum: Version?) async -> DependencyStatus {
        let environment = ["PATH": searchPath.joined(separator: ":"), "HOME": NSHomeDirectory()]
        let result: ProcessOutput
        do {
            result = try await ProcessRunner.run(URL(fileURLWithPath: path), ["--version"], environment: environment, timeout: 10)
        } catch {
            return .failed(path: path, message: error.localizedDescription)
        }
        guard result.exitCode == 0 else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(path: path, message: message.isEmpty ? "Exited with status \(result.exitCode)." : message)
        }
        let version = Version(result.stdoutString)
        if let minimum, let version, version < minimum { return .tooOld(path: path, version: version) }
        return .found(path: path, version: version)
    }
}

enum SearchPath {
    /// What a GUI app gets from launchd.
    static let system = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    static let extras = ["/opt/homebrew/bin", "/usr/local/bin", (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")]

    /// The user's login-shell PATH plus the usual install locations, deduplicated in order.
    static func resolve() async -> [String] {
        let login = await loginShellPath() ?? []
        var seen = Set<String>()
        return (login + extras + system).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Runs `$SHELL -lic` once to read the user's real PATH, giving up after `timeout` seconds.
    /// The shell writes to a temp file instead of a pipe, so a background process it spawns
    /// (prompt daemons, etc.) can't keep us waiting for EOF.
    static func loginShellPath(timeout: TimeInterval = 3) async -> [String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("cheddar-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", #"printf '%s' "$PATH" > "$CHEDDAR_PATH_OUT""#]
        var environment = ProcessInfo.processInfo.environment
        environment["CHEDDAR_PATH_OUT"] = outFile.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard let exit = try? ProcessRunner.launch(process) else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        await exit.wait()

        guard process.terminationReason == .exit,
              let path = try? String(contentsOf: outFile, encoding: .utf8), !path.isEmpty else { return nil }
        return path.split(separator: ":").map(String.init)
    }
}
