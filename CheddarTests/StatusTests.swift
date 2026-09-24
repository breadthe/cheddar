import XCTest
@testable import Cheddar

final class StatusParsingTests: XCTestCase {
    func testParsesPorcelainV2Counts() {
        let output = """
        # branch.oid abc
        1 M. N... 100644 100644 100644 a a a.txt
        1 .M N... 100644 100644 100644 b b b.txt
        1 MM N... 100644 100644 100644 c c c.txt
        2 R. N... 100644 100644 100644 d d R100 new.txt\told.txt
        u UU N... 100644 100644 100644 100644 e e e conflict.txt
        ? new-file.txt
        ? .claude/worktrees/auth/
        """
        let status = GitParsers.worktreeStatus(output, excludingNested: [".claude/worktrees/auth"])
        XCTAssertEqual(status, WorktreeStatus(staged: 3, unstaged: 2, untracked: 1, conflicts: 1))
        XCTAssertFalse(status.isClean)
        XCTAssertTrue(GitParsers.worktreeStatus("# branch.oid abc\n").isClean)
    }

    func testParsesAheadBehind() {
        let output = "refs/heads/main\u{1f}0 0\nrefs/heads/feat/x\u{1f}3 1\n"
        let counts = GitParsers.aheadBehind(output)
        XCTAssertEqual(counts["feat/x"]?.ahead, 3)
        XCTAssertEqual(counts["feat/x"]?.behind, 1)
        XCTAssertEqual(counts["main"]?.ahead, 0)
    }

    func testParsesUpstreamTrack() {
        var branch = Branch(name: "x", sha: "a", upstream: "origin/x", upstreamTrack: "[ahead 2, behind 13]", subject: "")
        XCTAssertEqual(branch.upstreamAhead, 2)
        XCTAssertEqual(branch.upstreamBehind, 13)
        branch.upstreamTrack = "[behind 1]"
        XCTAssertEqual(branch.upstreamAhead, 0)
        XCTAssertEqual(branch.upstreamBehind, 1)
        branch.upstreamTrack = "[gone]"
        XCTAssertTrue(branch.upstreamGone)
    }
}

final class StatusTests: XCTestCase {
    private var repo: TestRepo!
    private var service: GitService!

    override func setUp() async throws {
        repo = try await TestRepo()
        service = GitService(git: repo.git, codexHome: repo.path("codex-home"))
        try write("a\n", to: "repo/a.txt")
        try await repo.run("add", "a.txt")
        try await repo.run("commit", "-m", "add a")
    }

    override func tearDown() {
        repo.remove()
    }

    private func write(_ text: String, to relative: String) throws {
        let url = URL(fileURLWithPath: repo.path(relative))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testAheadBehindAndMerged() async throws {
        try await repo.run("branch", "merged")
        try await repo.run("branch", "feat")
        let featURL = URL(fileURLWithPath: repo.path("repo/.cheddar/worktrees/feat"))
        try await repo.run("worktree", "add", featURL.path, "feat")
        try await repo.run("commit", "--allow-empty", "-m", "feat 1", in: featURL)
        try await repo.run("commit", "--allow-empty", "-m", "feat 2", in: featURL)
        try await repo.run("commit", "--allow-empty", "-m", "main moves on")

        let snapshot = try await service.snapshot(of: repo.repo)

        let feat = try XCTUnwrap(snapshot.branches.first { $0.name == "feat" })
        XCTAssertEqual(feat.trunkAhead, 2)
        XCTAssertEqual(feat.trunkBehind, 1)
        XCTAssertFalse(feat.isMerged)
        let merged = try XCTUnwrap(snapshot.branches.first { $0.name == "merged" })
        XCTAssertTrue(merged.isMerged)
        XCTAssertEqual(merged.trunkAhead, 0)
        let main = try XCTUnwrap(snapshot.branches.first { $0.name == "main" })
        XCTAssertNil(main.trunkAhead, "trunk isn't compared with itself")
        XCTAssertFalse(main.isMerged)

        let fallback = await service.revListComparison(of: ["feat", "merged", "main"], against: "main", in: repo.repo)
        XCTAssertEqual(fallback["feat"]?.ahead, 2)
        XCTAssertEqual(fallback["feat"]?.behind, 1)
        XCTAssertNil(fallback["main"])
    }

    func testWorktreeChangeCountsIgnoreNestedWorktrees() async throws {
        try await repo.run("worktree", "add", "-b", "worktree-auth", repo.path("repo/.claude/worktrees/auth"))
        try write("a changed\n", to: "repo/a.txt")
        try write("staged\n", to: "repo/b.txt")
        try await repo.run("add", "b.txt")
        try write("new\n", to: "repo/c.txt")
        try write("draft\n", to: "repo/.claude/worktrees/auth/notes.txt")

        let snapshot = try await service.snapshot(of: repo.repo)

        let main = try XCTUnwrap(snapshot.mainWorktree)
        XCTAssertEqual(main.status, WorktreeStatus(staged: 1, unstaged: 1, untracked: 1, conflicts: 0))
        let auth = try XCTUnwrap(snapshot.worktree(checkingOut: "worktree-auth"))
        XCTAssertEqual(auth.status, WorktreeStatus(staged: 0, unstaged: 0, untracked: 1, conflicts: 0))
    }

    func testDetachedWorktreeGetsHeadSummary() async throws {
        try await repo.run("worktree", "add", "--detach", repo.path("codex-home/worktrees/ab12/repo"))

        let snapshot = try await service.snapshot(of: repo.repo)

        let codex = try XCTUnwrap(snapshot.worktrees.first { $0.isDetached })
        XCTAssertEqual(codex.headSubject, "add a")
        XCTAssertNotNil(codex.headDate)
        XCTAssertEqual(codex.status?.isClean, true)
    }

    func testTrunkOverride() async throws {
        try await repo.run("branch", "develop")
        var overridden = service!
        overridden.trunkOverride = "develop"

        let trunk = try await overridden.trunk(in: repo.repo)

        XCTAssertEqual(trunk, "develop")
    }

    func testCustomDiscoveryLocations() async throws {
        var custom = service!
        custom.extraLocations = [
            DiscoveryLocation(path: repo.path("conductor"), label: "conductor"),
            DiscoveryLocation(path: ".agents", label: "agents"),
            DiscoveryLocation(path: "", label: "ignored when empty"),
        ]
        try await repo.run("worktree", "add", "-b", "c1", repo.path("conductor/ws/c1"))
        try await repo.run("worktree", "add", "-b", "a1", repo.path("repo/.agents/a1"))

        let worktrees = try await custom.worktrees(in: repo.repo)

        let c1 = try XCTUnwrap(worktrees.first { $0.branch == "c1" })
        XCTAssertEqual(c1.origin, .custom("conductor"))
        XCTAssertEqual(c1.displayName, "ws/c1")
        let a1 = try XCTUnwrap(worktrees.first { $0.branch == "a1" })
        XCTAssertEqual(a1.origin, .custom("agents"))
        XCTAssertEqual(worktrees.map(\.origin.sortRank), worktrees.map(\.origin.sortRank).sorted())

        // Treated like other tools' worktrees: no folder moves, but adoptable.
        do {
            try await custom.moveWorktree(c1, toName: "x", in: repo.repo)
            XCTFail("expected a refusal")
        } catch is OperationError {}
        try await custom.adopt(c1, as: "c1", in: repo.repo)
        let adopted = try await custom.worktrees(in: repo.repo).first { $0.branch == "c1" }
        XCTAssertEqual(adopted?.origin, .cheddar)
    }
}

final class WatcherRoutingTests: XCTestCase {
    private let common = "/r/.git"
    private let worktrees = ["/r", "/r/.cheddar/worktrees/feat", "/codex/worktrees/ab12/r"]
    private let roots = ["/r/.cheddar/worktrees", "/r/.claude/worktrees", "/codex/worktrees"]

    private func route(_ paths: String...) -> RefreshScope {
        RepoWatcher.route(paths, commonDir: common, worktrees: worktrees, discoveryRoots: roots)
    }

    func testGitDirChangesRefreshEverythingExceptObjectsAndLogs() {
        XCTAssertEqual(route("/r/.git/refs/heads/"), .full)
        XCTAssertEqual(route("/r/.git"), .full)
        XCTAssertEqual(route("/r/.git/worktrees/feat/"), .full)
        XCTAssertEqual(route("/r/.git/objects/ab/"), .none)
        XCTAssertEqual(route("/r/.git/logs/refs/heads/"), .none)
    }

    func testFileChangesGoToTheLongestMatchingWorktree() {
        XCTAssertEqual(route("/r/src/"), .worktrees(["/r"]))
        XCTAssertEqual(route("/r/.cheddar/worktrees/feat/src/"), .worktrees(["/r/.cheddar/worktrees/feat"]))
        XCTAssertEqual(route("/r/src", "/codex/worktrees/ab12/r/lib"), .worktrees(["/r", "/codex/worktrees/ab12/r"]))
    }

    func testDiscoveryRootStructureRefreshesEverything() {
        // A new or removed folder in a root (e.g. another tool made or deleted a worktree).
        XCTAssertEqual(route("/r/.claude/worktrees"), .full)
        XCTAssertEqual(route("/r/.claude/worktrees/new"), .full)
        XCTAssertEqual(route("/codex/worktrees"), .full)
        XCTAssertEqual(route("/codex/worktrees/cd34"), .full)
    }

    func testOtherReposCodexWorktreesAreIgnored() {
        XCTAssertEqual(route("/codex/worktrees/cd34/other/src"), .none)
        XCTAssertEqual(route("/elsewhere/file"), .none)
    }
}

/// End to end: FSEvents → routing → debounce → reload, through a real ProjectModel.
@MainActor
final class AutoRefreshTests: XCTestCase {
    private var repo: TestRepo!
    private var model: ProjectModel!

    override func setUp() async throws {
        repo = try await TestRepo()
        model = ProjectModel(project: Project(path: repo.repo.path), service: GitService(git: repo.git, codexHome: repo.path("codex-home")))
        await model.load()
        // FSEvents only reports changes after the stream starts; give it a moment.
        try await Task.sleep(for: .milliseconds(500))
    }

    override func tearDown() async throws {
        model = nil
        repo.remove()
    }

    /// Polls until `condition` holds or `timeout` passes.
    private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func testNewBranchMadeOutsideShowsUp() async throws {
        try await repo.run("branch", "made-elsewhere")
        let appeared = try await eventually { model.snapshot?.branches.contains { $0.name == "made-elsewhere" } == true }
        XCTAssertTrue(appeared)
    }

    func testWorktreeMadeByAnotherToolShowsUp() async throws {
        try await repo.run("worktree", "add", "-b", "agent", repo.path("repo/.claude/worktrees/agent"))
        let appeared = try await eventually { model.snapshot?.worktree(checkingOut: "agent")?.origin == .claude }
        XCTAssertTrue(appeared)
    }

    func testFileEditUpdatesThatWorktreesStatus() async throws {
        XCTAssertEqual(model.snapshot?.mainWorktree?.status?.isClean, true)
        try "x".write(toFile: repo.path("repo/new.txt"), atomically: true, encoding: .utf8)
        let dirty = try await eventually { model.snapshot?.mainWorktree?.status?.untracked == 1 }
        XCTAssertTrue(dirty)
    }
}
