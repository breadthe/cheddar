import XCTest
@testable import Cheddar

final class GitMutationTests: XCTestCase {
    private var repo: TestRepo!
    private var service: GitService!

    override func setUp() async throws {
        repo = try await TestRepo()
        service = GitService(git: repo.git, codexHome: repo.path("codex-home"))
    }

    override func tearDown() {
        repo.remove()
    }

    private func worktree(onBranch branch: String) async throws -> Worktree {
        let worktrees = try await service.worktrees(in: repo.repo)
        return try XCTUnwrap(worktrees.first { $0.branch == branch })
    }

    private func branchNames() async throws -> Set<String> {
        Set(try await service.branches(in: repo.repo).map(\.name))
    }

    private func excludeFile() throws -> String {
        try String(contentsOf: repo.repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
    }

    // MARK: Create

    func testCreateWorktreeOnNewBranchExcludesCheddarFolder() async throws {
        let path = try await service.createWorktree(named: "feat-login", branch: .new(name: "feat/login", base: "main"), in: repo.repo)
        try await service.createWorktree(named: "second", branch: .new(name: "second", base: nil), in: repo.repo)

        XCTAssertEqual(path, repo.path("repo/.cheddar/worktrees/feat-login"))
        let created = try await worktree(onBranch: "feat/login")
        XCTAssertEqual(created.origin, .cheddar)
        XCTAssertEqual(try excludeFile().components(separatedBy: "\n").filter { $0 == ".cheddar/" }.count, 1)
        // The main checkout doesn't see the nested worktrees as untracked.
        let status = try await repo.run("status", "--porcelain")
        XCTAssertEqual(status, "")
    }

    func testExistingExcludeEntryIsNotDuplicated() async throws {
        let url = repo.repo.appendingPathComponent(".git/info/exclude")
        try "# mine\n/.cheddar".write(to: url, atomically: true, encoding: .utf8)

        try await service.ensureExcluded(".cheddar/", in: repo.repo)

        XCTAssertEqual(try excludeFile(), "# mine\n/.cheddar")
    }

    func testCreateWorktreeAddsSuffixWhenFolderExists() async throws {
        try FileManager.default.createDirectory(atPath: repo.path("repo/.cheddar/worktrees/fix"), withIntermediateDirectories: true)

        let path = try await service.createWorktree(named: "fix", branch: .new(name: "fix", base: nil), in: repo.repo)

        XCTAssertEqual(path, repo.path("repo/.cheddar/worktrees/fix-2"))
    }

    func testCreateWorktreeForExistingBranch() async throws {
        try await repo.run("branch", "fix/typo")

        try await service.createWorktree(named: "fix-typo", branch: .existing("fix/typo"), in: repo.repo)

        let created = try await worktree(onBranch: "fix/typo")
        XCTAssertEqual(created.displayName, "fix-typo")
    }

    func testBranchNameValidation() async throws {
        for name in ["feat/ok", "fix-1", "a.b"] {
            let valid = try await service.isValidBranchName(name, in: repo.repo)
            XCTAssertTrue(valid, name)
        }
        for name in ["", "-x", "bad..name", "has space", "trailing/", "x.lock", "@{-1}"] {
            let valid = try await service.isValidBranchName(name, in: repo.repo)
            XCTAssertFalse(valid, name)
        }
    }

    // MARK: Rename

    func testRenameCheddarWorktreeMovesFolder() async throws {
        try await service.createWorktree(named: "feat-a", branch: .new(name: "feat/a", base: nil), in: repo.repo)
        let original = try await worktree(onBranch: "feat/a")

        try await service.renameBranch("feat/a", to: "feat/b", movingWorktree: original, in: repo.repo)

        let renamed = try await worktree(onBranch: "feat/b")
        XCTAssertEqual(renamed.path, repo.path("repo/.cheddar/worktrees/feat-b"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let branches = try await branchNames()
        XCTAssertFalse(branches.contains("feat/a"))
    }

    func testRenameRollsBackBranchWhenMoveFails() async throws {
        try await service.createWorktree(named: "locked", branch: .new(name: "locked", base: nil), in: repo.repo)
        let original = try await worktree(onBranch: "locked")
        try await repo.run("worktree", "lock", original.path)

        do {
            try await service.renameBranch("locked", to: "unlocked", movingWorktree: original, in: repo.repo)
            XCTFail("expected the move to fail")
        } catch let error as GitError {
            XCTAssertTrue(error.stderr.contains("locked"), error.stderr)
        }

        let branches = try await branchNames()
        XCTAssertTrue(branches.contains("locked"))
        XCTAssertFalse(branches.contains("unlocked"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testOtherToolsWorktreesCannotBeMoved() async throws {
        try await repo.run("worktree", "add", "-b", "worktree-auth", repo.path("repo/.claude/worktrees/auth"))
        let claude = try await worktree(onBranch: "worktree-auth")

        do {
            try await service.renameBranch("worktree-auth", to: "auth", movingWorktree: claude, in: repo.repo)
            XCTFail("expected an ownership error")
        } catch is OperationError {}

        let branches = try await branchNames()
        XCTAssertTrue(branches.contains("worktree-auth"), "branch rename should be rolled back")

        // Renaming the branch alone is allowed and leaves the folder in place.
        try await service.renameBranch("worktree-auth", to: "auth", in: repo.repo)
        let renamed = try await worktree(onBranch: "auth")
        XCTAssertEqual(renamed.path, claude.path)
    }

    func testDetachedCheddarWorktreeMovesFolderOnly() async throws {
        let path = repo.path("repo/.cheddar/worktrees/scratch")
        try await repo.run("worktree", "add", "--detach", path)
        let before = try await service.worktrees(in: repo.repo)
        let detached = try XCTUnwrap(before.first { $0.isDetached })

        try await service.moveWorktree(detached, toName: "experiment", in: repo.repo)

        let after = try await service.worktrees(in: repo.repo)
        let moved = try XCTUnwrap(after.first { $0.isDetached })
        XCTAssertEqual(moved.displayName, "experiment")
    }

    // MARK: Delete

    func testRemoveWorktreeWithChangesNeedsForce() async throws {
        try await service.createWorktree(named: "dirty", branch: .new(name: "dirty", base: nil), in: repo.repo)
        let dirty = try await worktree(onBranch: "dirty")
        try "hi".write(toFile: (dirty.path as NSString).appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let changes = try await service.changes(at: dirty.path)
        XCTAssertEqual(changes, ["?? new.txt"])
        do {
            try await service.removeWorktree(dirty, force: false, in: repo.repo)
            XCTFail("expected git to refuse")
        } catch is GitError {}

        try await service.removeWorktree(dirty, force: true, in: repo.repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirty.path))
        let branches = try await branchNames()
        XCTAssertTrue(branches.contains("dirty"), "removing a worktree keeps its branch")
    }

    func testMainWorktreeCannotBeRemoved() async throws {
        let main = try await worktree(onBranch: "main")
        do {
            try await service.removeWorktree(main, force: true, in: repo.repo)
            XCTFail("expected an ownership error")
        } catch is OperationError {}
    }

    func testDeleteUnmergedBranchNeedsForce() async throws {
        try await service.createBranch("spike", base: "main", in: repo.repo)
        try await service.createWorktree(named: "spike", branch: .existing("spike"), in: repo.repo)
        let spike = try await worktree(onBranch: "spike")
        try await repo.run("commit", "--allow-empty", "-m", "only on spike", in: URL(fileURLWithPath: spike.path))
        try await service.removeWorktree(spike, force: false, in: repo.repo)

        do {
            try await service.deleteBranch("spike", force: false, in: repo.repo)
            XCTFail("expected -d to refuse")
        } catch let error as GitError {
            XCTAssertTrue(error.isNotFullyMerged, error.stderr)
        }

        try await service.deleteBranch("spike", force: true, in: repo.repo)
        let branches = try await branchNames()
        XCTAssertFalse(branches.contains("spike"))
    }

    func testDeleteMergedBranch() async throws {
        try await service.createBranch("merged", base: nil, in: repo.repo)
        try await service.deleteBranch("merged", force: false, in: repo.repo)
        let branches = try await branchNames()
        XCTAssertEqual(branches, ["main"])
    }
}
