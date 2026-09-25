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

    // MARK: Delete and track (milestone 8)

    /// A remote with branch `name` pushed from this repo and fetched, plus a second clone to act as a teammate.
    private func remoteWithTeammate(branch name: String) async throws -> (remote: RemoteBranch, teammate: URL) {
        let bare = try await addRemote("origin")
        try await repo.run("push", "-u", "origin", "main")
        try await repo.run("push", "origin", "main:\(name)")
        let teammate = repo.root.appendingPathComponent("teammate")
        try await repo.run("clone", bare.path, teammate.path)
        try await repo.run("config", "user.name", "Teammate", in: teammate)
        try await repo.run("config", "user.email", "teammate@cheddar.invalid", in: teammate)
        let snapshot = try await service.snapshot(of: repo.repo)
        return (try XCTUnwrap(snapshot.remoteBranches.first { $0.name == name }), teammate)
    }

    private func remoteHas(_ branch: String) async throws -> Bool {
        try await !repo.run("ls-remote", "origin", "refs/heads/\(branch)").isEmpty
    }

    func testDeleteRemoteBranch() async throws {
        let (remote, _) = try await remoteWithTeammate(branch: "feat/x")
        try await repo.run("branch", "--track", "x", "origin/feat/x")

        try await service.deleteRemoteBranch(remote, in: repo.repo)

        let remoteStillHasIt = try await remoteHas("feat/x")
        XCTAssertFalse(remoteStillHasIt)
        let snapshot = try await service.snapshot(of: repo.repo)
        XCTAssertFalse(snapshot.remoteBranches.contains { $0.name == "feat/x" })
        XCTAssertEqual(snapshot.branches.first { $0.name == "x" }?.upstreamGone, true)
    }

    func testDeleteRefusesWhenTheRemoteBranchMoved() async throws {
        let (remote, teammate) = try await remoteWithTeammate(branch: "feat/x")
        try await repo.run("checkout", "-q", "-b", "feat/x", "origin/feat/x", in: teammate)
        try await repo.run("commit", "--allow-empty", "-m", "teammate's work", in: teammate)
        try await repo.run("push", "origin", "feat/x", in: teammate)

        do {
            try await service.deleteRemoteBranch(remote, in: repo.repo)
            XCTFail("deleted a branch with commits we haven't fetched")
        } catch let error as GitError {
            XCTAssertTrue(error.isStaleLease)
            XCTAssertTrue(error.localizedDescription.hasPrefix("The branch changed on the remote since your last fetch"))
        }
        let remoteStillHasIt = try await remoteHas("feat/x")
        XCTAssertTrue(remoteStillHasIt)
    }

    func testDeletingABranchAlreadyGoneOnTheRemoteSucceeds() async throws {
        let (remote, teammate) = try await remoteWithTeammate(branch: "feat/x")
        try await repo.run("push", "origin", "--delete", "feat/x", in: teammate)

        try await service.deleteRemoteBranch(remote, in: repo.repo)

        let snapshot = try await service.snapshot(of: repo.repo)
        XCTAssertFalse(snapshot.remoteBranches.contains { $0.name == "feat/x" }, "the stale remote-tracking ref is removed")
    }

    func testCreateTrackingBranch() async throws {
        let (remote, _) = try await remoteWithTeammate(branch: "feat/x")
        var snapshot = try await service.snapshot(of: repo.repo)
        XCTAssertTrue(snapshot.untrackedRemoteBranches.contains(remote))

        try await service.createTrackingBranch("mine", from: remote, in: repo.repo)

        snapshot = try await service.snapshot(of: repo.repo)
        let mine = try XCTUnwrap(snapshot.branches.first { $0.name == "mine" })
        XCTAssertEqual(snapshot.trackedRemote(of: mine), remote)
        XCTAssertFalse(snapshot.untrackedRemoteBranches.contains(remote))
        XCTAssertEqual(snapshot.mainWorktree?.branch, "main", "nothing is checked out")
    }

    @MainActor
    func testTrackingBranchNameIsValidatedAndClashesAreReported() async throws {
        let (remote, _) = try await remoteWithTeammate(branch: "feat/x")
        let model = ProjectModel(project: Project(path: repo.repo.path), service: service)

        do {
            try await model.createTrackingBranch("bad name", from: remote)
            XCTFail("accepted an invalid name")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn't a valid branch name"))
        }
        do {
            try await model.createTrackingBranch("main", from: remote)
            XCTFail("overwrote an existing branch")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }
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
