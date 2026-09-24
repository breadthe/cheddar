import XCTest
@testable import Cheddar

final class DiscoveryTests: XCTestCase {
    private var repo: TestRepo!
    private var service: GitService!

    override func setUp() async throws {
        repo = try await TestRepo()
        service = GitService(git: repo.git, codexHome: repo.path("codex-home"))
    }

    override func tearDown() {
        repo.remove()
    }

    private func snapshot() async throws -> RepoSnapshot {
        try await service.snapshot(of: repo.repo)
    }

    private func worktree(onBranch branch: String) async throws -> Worktree {
        let snapshot = try await snapshot()
        return try XCTUnwrap(snapshot.worktree(checkingOut: branch))
    }

    private func move(_ from: String, to: String) throws {
        try FileManager.default.createDirectory(
            atPath: (repo.path(to) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: repo.path(from), toPath: repo.path(to))
    }

    func testMovedFolderIsOrphanedUntilRepaired() async throws {
        try await repo.run("worktree", "add", "-b", "auth", repo.path("repo/.claude/worktrees/a"))
        try move("repo/.claude/worktrees/a", to: "repo/.claude/worktrees/b")

        let before = try await snapshot()
        let orphan = try XCTUnwrap(before.orphans.first)
        XCTAssertEqual(before.orphans.count, 1)
        XCTAssertEqual(orphan.displayName, "b")
        XCTAssertEqual(orphan.origin, .claude)
        XCTAssertTrue(orphan.isRepairable)
        XCTAssertEqual(before.worktree(checkingOut: "auth")?.isMissing, true, "git still lists the old path")

        try await service.repair(orphan, in: repo.repo)

        let after = try await snapshot()
        XCTAssertEqual(after.orphans, [])
        let repaired = try XCTUnwrap(after.worktree(checkingOut: "auth"))
        XCTAssertEqual(repaired.displayName, "b")
        XCTAssertFalse(repaired.isMissing)
    }

    func testFolderWithPrunedEntryIsNotRepairable() async throws {
        try await repo.run("worktree", "add", "-b", "old", repo.path("repo/.cheddar/worktrees/old"))
        try move("repo/.cheddar/worktrees/old", to: "repo/.cheddar/worktrees/old-moved")
        try await repo.run("worktree", "prune")

        let orphans = try await snapshot().orphans

        XCTAssertEqual(orphans.map(\.displayName), ["old-moved"])
        XCTAssertEqual(orphans.first?.isRepairable, false)
    }

    func testCodexRootMatchesByPointerNotName() async throws {
        // Another repo's Codex worktree, with the same folder name as ours.
        let other = repo.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await repo.run("init", "-b", "main", in: other)
        try await repo.run("-c", "user.name=t", "-c", "user.email=t@t.invalid", "commit", "--allow-empty", "-m", "x", in: other)
        try await repo.run("worktree", "add", "--detach", repo.path("codex-home/worktrees/aaaa/repo"), in: other)
        try move("codex-home/worktrees/aaaa/repo", to: "codex-home/worktrees/bbbb/repo")
        // Ours, moved so git no longer lists it at its path.
        try await repo.run("worktree", "add", "--detach", repo.path("codex-home/worktrees/cccc/repo"))
        try move("codex-home/worktrees/cccc/repo", to: "codex-home/worktrees/dddd/repo")

        let orphans = try await snapshot().orphans

        XCTAssertEqual(orphans.map(\.displayName), ["dddd/repo"])
        XCTAssertEqual(orphans.first?.origin, .codex)
    }

    func testRelativeGitdirPointer() async throws {
        try await repo.run("-c", "worktree.useRelativePaths=true", "worktree", "add", "-b", "rel", repo.path("repo/.cheddar/worktrees/rel"))
        let pointer = GitService.gitdirPointer(of: repo.path("repo/.cheddar/worktrees/rel"))
        XCTAssertEqual(pointer, Paths.canonical(repo.path("repo/.git/worktrees/rel")))

        let orphans = try await snapshot().orphans
        XCTAssertEqual(orphans, [], "a listed worktree isn't an orphan")
    }

    func testPruneDropsOnlyThatWorktree() async throws {
        for name in ["gone1", "gone2"] {
            try await repo.run("worktree", "add", "-b", name, repo.path("repo/.cheddar/worktrees/\(name)"))
            try FileManager.default.removeItem(atPath: repo.path("repo/.cheddar/worktrees/\(name)"))
        }
        let gone1 = try await worktree(onBranch: "gone1")

        try await service.prune(gone1, in: repo.repo)

        let after = try await snapshot()
        XCTAssertNil(after.worktree(checkingOut: "gone1"))
        XCTAssertEqual(after.worktree(checkingOut: "gone2")?.isMissing, true)
    }

    func testPruneRefusesPresentWorktree() async throws {
        try await repo.run("worktree", "add", "-b", "here", repo.path("repo/.cheddar/worktrees/here"))
        let here = try await worktree(onBranch: "here")
        do {
            try await service.prune(here, in: repo.repo)
            XCTFail("expected a refusal")
        } catch is OperationError {}
    }

    func testAdoptMovesWorktreeIntoCheddar() async throws {
        try await repo.run("worktree", "add", "-b", "worktree-auth", repo.path("repo/.claude/worktrees/auth"))
        let claude = try await worktree(onBranch: "worktree-auth")

        try await service.adopt(claude, as: "auth", in: repo.repo)

        let adopted = try await worktree(onBranch: "worktree-auth")
        XCTAssertEqual(adopted.origin, .cheddar)
        XCTAssertEqual(adopted.path, repo.path("repo/.cheddar/worktrees/auth"))
        let exclude = try String(contentsOfFile: repo.path("repo/.git/info/exclude"), encoding: .utf8)
        XCTAssertTrue(exclude.contains(".cheddar/"))
    }

    func testAdoptRefusesCheddarAndMainWorktrees() async throws {
        try await service.createWorktree(named: "mine", branch: .new(name: "mine", base: nil), in: repo.repo)
        let worktrees = try await snapshot().worktrees
        for worktree in worktrees {
            do {
                try await service.adopt(worktree, as: "x", in: repo.repo)
                XCTFail("expected a refusal for \(worktree.origin)")
            } catch is OperationError {}
        }
    }

    func testOffersToExcludeNestedClaudeWorktrees() async throws {
        try await repo.run("worktree", "add", "-b", "worktree-auth", repo.path("repo/.claude/worktrees/auth"))

        let before = try await snapshot()
        XCTAssertEqual(before.unexcludedRoots, [".claude/worktrees/"])

        try await service.ensureExcluded(".claude/worktrees/", in: repo.repo)

        let after = try await snapshot()
        XCTAssertEqual(after.unexcludedRoots, [])
        let status = try await repo.run("status", "--porcelain")
        XCTAssertEqual(status, "")
    }
}
