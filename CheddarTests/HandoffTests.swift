import XCTest
@testable import Cheddar

final class HandoffTests: XCTestCase {
    private var repo: TestRepo!
    private var service: GitService!

    override func setUp() async throws {
        repo = try await TestRepo()
        service = GitService(git: repo.git, codexHome: repo.path("codex-home"))
        try "base\n".write(to: repo.repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await repo.run("add", "a.txt")
        try await repo.run("commit", "-m", "add a.txt")
    }

    override func tearDown() {
        repo.remove()
    }

    // MARK: Helpers

    private func worktree(at relative: String) async throws -> Worktree {
        let path = Paths.canonical(repo.path(relative))
        let worktrees = try await service.worktrees(in: repo.repo)
        return try XCTUnwrap(worktrees.first { Paths.canonical($0.path) == path }, "no worktree at \(relative)")
    }

    private func mainBranch() async throws -> String {
        try await repo.run("branch", "--show-current").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stashList() async throws -> String {
        try await repo.run("stash", "list")
    }

    private func write(_ text: String, to relative: String) throws {
        let url = URL(fileURLWithPath: repo.path(relative))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOfFile: repo.path(relative), encoding: .utf8)
    }

    // MARK: Tests

    func testCarriesChangesIntoMainCheckout() async throws {
        try await service.createWorktree(named: "feat", branch: .new(name: "feat", base: nil), in: repo.repo)
        let featURL = URL(fileURLWithPath: repo.path("repo/.cheddar/worktrees/feat"))
        try write("build/\n", to: "repo/.cheddar/worktrees/feat/.gitignore")
        try await repo.run("add", ".gitignore", in: featURL)
        try await repo.run("commit", "-m", "ignore build", in: featURL)
        try write("changed in worktree\n", to: "repo/.cheddar/worktrees/feat/a.txt")
        try write("new\n", to: "repo/.cheddar/worktrees/feat/new.txt")
        try write("ignored\n", to: "repo/.cheddar/worktrees/feat/build/out.o")
        let feat = try await worktree(at: "repo/.cheddar/worktrees/feat")

        let preflight = try await service.handoffPreflight(for: feat, in: repo.repo)
        XCTAssertEqual(preflight.mainChanges, [])
        XCTAssertEqual(Set(preflight.worktreeChanges), [" M a.txt", "?? new.txt"])
        XCTAssertEqual(preflight.ignoredPaths, ["build/"])
        XCTAssertEqual(preflight.mainBranch, "main")

        try await service.handOff(feat, newBranch: nil, stashMainChanges: false, in: repo.repo)

        let branch = try await mainBranch()
        XCTAssertEqual(branch, "feat")
        XCTAssertEqual(try read("repo/a.txt"), "changed in worktree\n")
        XCTAssertEqual(try read("repo/new.txt"), "new\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: feat.path))
        let stashes = try await stashList()
        XCTAssertEqual(stashes, "")
    }

    func testRemoveFailurePutsChangesBack() async throws {
        // Stashing an uncommitted .gitignore un-ignores build/, so the plain remove refuses.
        try await service.createWorktree(named: "feat", branch: .new(name: "feat", base: nil), in: repo.repo)
        try write("build/\n", to: "repo/.cheddar/worktrees/feat/.gitignore")
        try write("ignored\n", to: "repo/.cheddar/worktrees/feat/build/out.o")
        try write("changed\n", to: "repo/.cheddar/worktrees/feat/a.txt")
        let feat = try await worktree(at: "repo/.cheddar/worktrees/feat")

        do {
            try await service.handOff(feat, newBranch: nil, stashMainChanges: false, in: repo.repo)
            XCTFail("expected the remove to fail")
        } catch let error as HandoffError {
            XCTAssertTrue(error.localizedDescription.contains(".gitignore"), error.localizedDescription)
        }

        XCTAssertEqual(try read("repo/.cheddar/worktrees/feat/a.txt"), "changed\n")
        XCTAssertEqual(try read("repo/.cheddar/worktrees/feat/.gitignore"), "build/\n")
        let branch = try await mainBranch()
        XCTAssertEqual(branch, "main")
        let stashes = try await stashList()
        XCTAssertEqual(stashes, "")
    }

    func testRefusesDirtyMainCheckoutUnlessStashing() async throws {
        try await service.createWorktree(named: "feat", branch: .new(name: "feat", base: nil), in: repo.repo)
        let feat = try await worktree(at: "repo/.cheddar/worktrees/feat")
        try write("dirty main\n", to: "repo/a.txt")

        do {
            try await service.handOff(feat, newBranch: nil, stashMainChanges: false, in: repo.repo)
            XCTFail("expected a refusal")
        } catch is OperationError {}

        let branch = try await mainBranch()
        XCTAssertEqual(branch, "main")
        XCTAssertTrue(FileManager.default.fileExists(atPath: feat.path))
        XCTAssertEqual(try read("repo/a.txt"), "dirty main\n")
    }

    func testStashesMainChangesButNotNestedWorktrees() async throws {
        try await service.createWorktree(named: "feat", branch: .new(name: "feat", base: nil), in: repo.repo)
        // A Claude Code worktree nested in the main checkout, not excluded, so git lists it as untracked.
        try await repo.run("worktree", "add", "-b", "worktree-auth", repo.path("repo/.claude/worktrees/auth"))
        try write("draft\n", to: "repo/.claude/worktrees/auth/notes.txt")
        try write("dirty main\n", to: "repo/a.txt")
        let feat = try await worktree(at: "repo/.cheddar/worktrees/feat")

        let preflight = try await service.handoffPreflight(for: feat, in: repo.repo)
        XCTAssertEqual(preflight.mainChanges, [" M a.txt"])

        try await service.handOff(feat, newBranch: nil, stashMainChanges: true, in: repo.repo)

        let branch = try await mainBranch()
        XCTAssertEqual(branch, "feat")
        let stashes = try await stashList()
        XCTAssertTrue(stashes.contains(GitService.mainStashMessage(branch: "feat")), stashes)
        XCTAssertEqual(try read("repo/.claude/worktrees/auth/notes.txt"), "draft\n")
        let auth = try await worktree(at: "repo/.claude/worktrees/auth")
        XCTAssertEqual(auth.branch, "worktree-auth")
    }

    func testDetachedWorktreeGetsABranchFirst() async throws {
        try await repo.run("worktree", "add", "--detach", repo.path("codex-home/worktrees/ab12/repo"))
        try write("codex work\n", to: "codex-home/worktrees/ab12/repo/a.txt")
        let codex = try await worktree(at: "codex-home/worktrees/ab12/repo")
        XCTAssertTrue(codex.isDetached)

        do {
            try await service.handOff(codex, newBranch: nil, stashMainChanges: false, in: repo.repo)
            XCTFail("expected a refusal without a branch name")
        } catch is OperationError {}

        try await service.handOff(codex, newBranch: "codex/fix", stashMainChanges: false, in: repo.repo)

        let branch = try await mainBranch()
        XCTAssertEqual(branch, "codex/fix")
        XCTAssertEqual(try read("repo/a.txt"), "codex work\n")
    }

    func testRenamesTheBranchWhileHandingOff() async throws {
        try await repo.run("worktree", "add", "-b", "claude/zealous-hopper", repo.path("repo/.claude/worktrees/zealous-hopper"))
        try write("from claude\n", to: "repo/.claude/worktrees/zealous-hopper/a.txt")
        let agent = try await worktree(at: "repo/.claude/worktrees/zealous-hopper")

        let branch = try await service.handOff(agent, newBranch: "feat/login", stashMainChanges: false, in: repo.repo)

        XCTAssertEqual(branch, "feat/login")
        let current = try await mainBranch()
        XCTAssertEqual(current, "feat/login")
        XCTAssertEqual(try read("repo/a.txt"), "from claude\n")
        let branches = try await repo.run("branch", "--format=%(refname:short)")
        XCTAssertFalse(branches.contains("claude/zealous-hopper"), "renamed, not copied")
    }

    func testRenameToATakenNameChangesNothing() async throws {
        try await repo.run("branch", "taken")
        try await repo.run("worktree", "add", "-b", "claude/x", repo.path("repo/.claude/worktrees/x"))
        try write("wip\n", to: "repo/.claude/worktrees/x/a.txt")
        let agent = try await worktree(at: "repo/.claude/worktrees/x")

        do {
            try await service.handOff(agent, newBranch: "taken", stashMainChanges: false, in: repo.repo)
            XCTFail("expected git to refuse the rename")
        } catch {}

        let stillThere = try await worktree(at: "repo/.claude/worktrees/x")
        XCTAssertEqual(stillThere.branch, "claude/x")
        XCTAssertEqual(try read("repo/.claude/worktrees/x/a.txt"), "wip\n")
        let current = try await mainBranch()
        XCTAssertEqual(current, "main")
        let stashes = try await stashList()
        XCTAssertEqual(stashes, "")
    }

    func testRefusesLockedWorktree() async throws {
        try await service.createWorktree(named: "feat", branch: .new(name: "feat", base: nil), in: repo.repo)
        let path = repo.path("repo/.cheddar/worktrees/feat")
        try await repo.run("worktree", "lock", "--reason", "on usb", path)
        let feat = try await worktree(at: "repo/.cheddar/worktrees/feat")

        do {
            try await service.handOff(feat, newBranch: nil, stashMainChanges: false, in: repo.repo)
            XCTFail("expected a refusal")
        } catch let error as OperationError {
            XCTAssertTrue(error.localizedDescription.contains("on usb"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testRecreatesWorktreeWhenSwitchFails() async throws {
        try await service.createWorktree(named: "feat", branch: .new(name: "feat", base: nil), in: repo.repo)
        try write("keep me\n", to: "repo/.cheddar/worktrees/feat/a.txt")
        let feat = try await worktree(at: "repo/.cheddar/worktrees/feat")
        // A stale lock on the main checkout's index makes `git switch` fail there, after W is removed.
        let lock = repo.repo.appendingPathComponent(".git/index.lock")
        FileManager.default.createFile(atPath: lock.path, contents: nil)

        do {
            try await service.handOff(feat, newBranch: nil, stashMainChanges: false, in: repo.repo)
            XCTFail("expected the switch to fail")
        } catch let error as HandoffError {
            XCTAssertTrue(error.summary.contains("recreated"), error.summary)
        }
        try FileManager.default.removeItem(at: lock)

        let recreated = try await worktree(at: "repo/.cheddar/worktrees/feat")
        XCTAssertEqual(recreated.branch, "feat")
        XCTAssertEqual(try read("repo/.cheddar/worktrees/feat/a.txt"), "keep me\n")
        let branch = try await mainBranch()
        XCTAssertEqual(branch, "main")
        let stashes = try await stashList()
        XCTAssertEqual(stashes, "")
    }

    func testKeepsStashWhenPopFails() async throws {
        // `feat` branches off before main ignores notes.txt, so the worktree's notes.txt is untracked
        // but main's is ignored and survives the switch, which blocks the pop.
        try await service.createWorktree(named: "feat", branch: .new(name: "feat", base: nil), in: repo.repo)
        try write("notes.txt\n", to: "repo/.gitignore")
        try await repo.run("add", ".gitignore")
        try await repo.run("commit", "-m", "ignore notes")
        try write("main's notes\n", to: "repo/notes.txt")
        try write("worktree notes\n", to: "repo/.cheddar/worktrees/feat/notes.txt")
        let feat = try await worktree(at: "repo/.cheddar/worktrees/feat")

        do {
            try await service.handOff(feat, newBranch: nil, stashMainChanges: false, in: repo.repo)
            XCTFail("expected the pop to fail")
        } catch let error as HandoffError {
            XCTAssertTrue(error.localizedDescription.contains("stash@{0}"), error.localizedDescription)
        }

        let branch = try await mainBranch()
        XCTAssertEqual(branch, "feat")
        let stashes = try await stashList()
        XCTAssertTrue(stashes.contains(GitService.handoffStashMessage(branch: "feat")), stashes)
        XCTAssertEqual(try read("repo/notes.txt"), "main's notes\n")
    }
}
