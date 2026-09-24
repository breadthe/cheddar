import Foundation
@testable import Cheddar

/// A throwaway repo in a temp dir, driven by real git. The user's global and system git config are ignored.
struct TestRepo {
    let root: URL
    let repo: URL
    let git: GitRunner

    static func makeGit() async throws -> GitRunner {
        let searchPath = SearchPath.extras + SearchPath.system
        guard let path = await DependencyChecker(searchPath: searchPath).locate("git") else {
            throw GitError(arguments: [], exitCode: -1, stderr: "git not found for tests")
        }
        return GitRunner(
            executable: URL(fileURLWithPath: path),
            searchPath: searchPath,
            extraEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        )
    }

    init() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cheddar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: Paths.canonical(temp.path), isDirectory: true)
        repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        git = try await Self.makeGit()

        try await run("init", "-b", "main")
        try await run("config", "user.name", "Cheddar Tests")
        try await run("config", "user.email", "tests@cheddar.invalid")
        try await run("commit", "--allow-empty", "-m", "initial")
    }

    @discardableResult
    func run(_ arguments: String..., in directory: URL? = nil) async throws -> String {
        try await git.output(arguments, in: directory ?? repo)
    }

    func path(_ relative: String) -> String {
        root.appendingPathComponent(relative).path
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
