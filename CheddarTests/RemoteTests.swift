import XCTest
@testable import Cheddar

final class RemoteTests: XCTestCase {
    private var repo: TestRepo!
    private var service: GitService!

    override func setUp() async throws {
        repo = try await TestRepo()
        service = GitService(git: repo.git, codexHome: repo.path("codex-home"))
    }

    override func tearDown() {
        repo.remove()
    }

    /// A bare repo next to the test repo, added as remote `name`.
    @discardableResult
    private func addRemote(_ name: String) async throws -> URL {
        let url = repo.root.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-") + ".git")
        try await repo.run("init", "--bare", "-b", "main", url.path)
        try await repo.run("remote", "add", name, url.path)
        return url
    }

    func testRemoteBranchesAreLinkedByUpstreamOnly() async throws {
        try await addRemote("origin")
        try await repo.run("branch", "feat/tracked")
        try await repo.run("branch", "same-name")
        try await repo.run("push", "-u", "origin", "main", "feat/tracked")
        // Pushed without -u: a remote branch with the same name, but no upstream link.
        try await repo.run("push", "origin", "same-name", "main:only-remote")
        try await repo.run("remote", "set-head", "origin", "main")
        try await repo.run("commit", "--allow-empty", "-m", "local only", in: nil)

        let snapshot = try await service.snapshot(of: repo.repo)

        XCTAssertEqual(snapshot.remotes, ["origin"])
        XCTAssertEqual(snapshot.remoteBranches.map(\.shortName),
                       ["origin/feat/tracked", "origin/main", "origin/only-remote", "origin/same-name"])
        let main = try XCTUnwrap(snapshot.branches.first { $0.name == "main" })
        XCTAssertEqual(snapshot.trackedRemote(of: main)?.shortName, "origin/main")
        XCTAssertEqual(main.upstreamAhead, 1)
        let tracked = try XCTUnwrap(snapshot.branches.first { $0.name == "feat/tracked" })
        XCTAssertEqual(snapshot.trackedRemote(of: tracked)?.name, "feat/tracked")
        let sameName = try XCTUnwrap(snapshot.branches.first { $0.name == "same-name" })
        XCTAssertNil(snapshot.trackedRemote(of: sameName))
        XCTAssertEqual(snapshot.untrackedRemoteBranches.map(\.shortName), ["origin/only-remote", "origin/same-name"])
    }

    func testRemoteNamesWithSlashes() async throws {
        try await addRemote("team/fork")
        try await repo.run("push", "team/fork", "main:feat/x")

        let snapshot = try await service.snapshot(of: repo.repo)

        let remote = try XCTUnwrap(snapshot.remoteBranches.first)
        XCTAssertEqual(remote.remote, "team/fork")
        XCTAssertEqual(remote.name, "feat/x")
        XCTAssertEqual(remote.subject, "initial")
    }

    func testNoRemotes() async throws {
        let snapshot = try await service.snapshot(of: repo.repo)

        XCTAssertEqual(snapshot.remotes, [])
        XCTAssertEqual(snapshot.remoteBranches, [])
        XCTAssertNil(snapshot.lastFetch)
    }

    func testFetchAddsAndPrunesRemoteBranches() async throws {
        let bare = try await addRemote("origin")
        try await repo.run("push", "-u", "origin", "main")
        let other = repo.root.appendingPathComponent("other")
        try await repo.run("clone", bare.path, other.path)
        try await repo.run("push", "origin", "HEAD:from-other", in: other)

        var snapshot = try await service.snapshot(of: repo.repo)
        XCTAssertNil(snapshot.lastFetch, "push doesn't write FETCH_HEAD")
        XCTAssertFalse(snapshot.remoteBranches.contains { $0.name == "from-other" })

        try await service.fetch(in: repo.repo)
        snapshot = try await service.snapshot(of: repo.repo)
        XCTAssertTrue(snapshot.remoteBranches.contains { $0.name == "from-other" })
        let fetched = try XCTUnwrap(snapshot.lastFetch)
        XCTAssertLessThan(abs(fetched.timeIntervalSinceNow), 60)

        try await repo.run("push", "origin", "--delete", "from-other", in: other)
        try await service.fetch(in: repo.repo)
        snapshot = try await service.snapshot(of: repo.repo)
        XCTAssertFalse(snapshot.remoteBranches.contains { $0.name == "from-other" })
    }

    func testFetchFromLinkedWorktreeCountsAsLastFetch() async throws {
        try await addRemote("origin")
        try await repo.run("push", "origin", "main")
        let linked = repo.path("repo/.cheddar/worktrees/x")
        try await repo.run("worktree", "add", "-b", "x", linked)
        try await repo.run("fetch", in: URL(fileURLWithPath: linked))

        let snapshot = try await service.snapshot(of: repo.repo)

        XCTAssertNotNil(snapshot.lastFetch)
    }

    @MainActor
    func testFetchNeedingCredentialsExplainsWhy() async throws {
        // An ssh that fails the way a key missing from the agent does.
        let ssh = repo.path("fake-ssh")
        try "#!/bin/sh\necho 'git@example.invalid: Permission denied (publickey).' >&2\nexit 255\n"
            .write(toFile: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh)
        try await repo.run("config", "core.sshCommand", ssh)
        try await repo.run("remote", "add", "origin", "git@example.invalid:me/repo.git")
        let model = ProjectModel(project: Project(path: repo.repo.path), service: service)

        await model.fetch()

        let alert = try XCTUnwrap(model.alert)
        XCTAssertEqual(alert.title, "Couldn't fetch")
        XCTAssertTrue(alert.message.contains("Permission denied (publickey)"))
        XCTAssertTrue(alert.message.contains(ProjectModel.credentialsHelp))
        XCTAssertFalse(model.isBusy)
    }

    func testTimeoutStopsTheProcessAndSaysSo() async throws {
        let start = Date()
        let output = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["10"], timeout: 0.3)

        XCTAssertTrue(output.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        let error = GitError(arguments: ["fetch", "--all"], exitCode: output.exitCode, stderr: "", timedOut: true)
        XCTAssertEqual(error.errorDescription, "git fetch didn't finish within 120 seconds, so Cheddar stopped it.")

        let quick = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/true"), [], timeout: 5)
        XCTAssertFalse(quick.timedOut)
    }
}
