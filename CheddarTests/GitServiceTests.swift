import XCTest
@testable import Cheddar

final class GitServiceTests: XCTestCase {
    private var repo: TestRepo!
    private var service: GitService!

    override func setUp() async throws {
        repo = try await TestRepo()
        service = GitService(git: repo.git, codexHome: repo.path("codex-home"))
    }

    override func tearDown() {
        repo.remove()
    }

    func testClassifiesWorktreesByOrigin() async throws {
        try await repo.run("worktree", "add", "-b", "feat/login", repo.path("repo/.cheddar/worktrees/feat-login"))
        try await repo.run("worktree", "add", "-b", "worktree-auth", repo.path("repo/.claude/worktrees/auth"))
        try await repo.run("worktree", "add", "--detach", repo.path("codex-home/worktrees/ab12/repo"))
        try await repo.run("worktree", "add", "-b", "codex-local", repo.path("repo/.codex/local"))
        try await repo.run("worktree", "add", "-b", "elsewhere", repo.path("elsewhere/ext"))

        let worktrees = try await service.worktrees(in: repo.repo)

        XCTAssertEqual(worktrees.map(\.origin), [.main, .cheddar, .claude, .codex, .codex, .external])
        XCTAssertEqual(worktrees.map(\.displayName), ["repo", "feat-login", "auth", "ab12/repo", "local", "ext"])
        XCTAssertEqual(worktrees.first?.branch, "main")

        let codex = try XCTUnwrap(worktrees.first { $0.displayName == "ab12/repo" })
        XCTAssertTrue(codex.isDetached)
        XCTAssertNil(codex.branch)
        XCTAssertEqual(codex.shortHead?.count, 7)
        XCTAssertFalse(worktrees.contains { $0.isMissing })
    }

    func testOtherReposInCodexRootAreNotListed() async throws {
        let other = repo.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await repo.run("init", "-b", "main", in: other)
        try await repo.run("-c", "user.name=t", "-c", "user.email=t@t.invalid", "commit", "--allow-empty", "-m", "x", in: other)
        try await repo.run("worktree", "add", "--detach", repo.path("codex-home/worktrees/cd34/other"), in: other)

        let worktrees = try await service.worktrees(in: repo.repo)

        XCTAssertEqual(worktrees.map(\.origin), [.main])
    }

    func testMissingWorktreeFolder() async throws {
        let path = repo.path("repo/.cheddar/worktrees/gone")
        try await repo.run("worktree", "add", "-b", "gone", path)
        try FileManager.default.removeItem(atPath: path)

        let worktrees = try await service.worktrees(in: repo.repo)

        let gone = try XCTUnwrap(worktrees.first { $0.branch == "gone" })
        XCTAssertTrue(gone.isMissing)
        XCTAssertTrue(gone.isPrunable)
        XCTAssertEqual(gone.origin, .cheddar)
    }

    func testSnapshotLinksBranchesToWorktrees() async throws {
        try await repo.run("worktree", "add", "-b", "feat/login", repo.path("repo/.cheddar/worktrees/feat-login"))
        try await repo.run("branch", "fix/typo")

        let snapshot = try await service.snapshot(of: repo.repo)

        XCTAssertEqual(snapshot.trunk, "main")
        XCTAssertEqual(Set(snapshot.branches.map(\.name)), ["main", "feat/login", "fix/typo"])
        XCTAssertEqual(snapshot.worktree(checkingOut: "main")?.origin, .main)
        XCTAssertEqual(snapshot.worktree(checkingOut: "feat/login")?.displayName, "feat-login")
        XCTAssertNil(snapshot.worktree(checkingOut: "fix/typo"))
        XCTAssertEqual(snapshot.branches.first { $0.name == "main" }?.subject, "initial")
    }

    func testTrunkFallsBackToMaster() async throws {
        try await repo.run("branch", "-m", "main", "master")
        let trunk = try await service.trunk(in: repo.repo)
        XCTAssertEqual(trunk, "master")
    }
}
