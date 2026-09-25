import XCTest
@testable import Cheddar

final class GitParsersTests: XCTestCase {
    func testParsesWorktreePorcelain() {
        let output = [
            "worktree /r", "HEAD aaa", "branch refs/heads/main", "",
            "worktree /r/.cheddar/worktrees/x", "HEAD bbb", "detached", "locked moved\nto usb", "",
            "worktree /gone", "HEAD ccc", "branch refs/heads/feat/a", "prunable gitdir file points to non-existent location", "",
        ].joined(separator: "\0")

        let worktrees = GitParsers.worktrees(output)

        XCTAssertEqual(worktrees.count, 3)
        XCTAssertEqual(worktrees[0].path, "/r")
        XCTAssertEqual(worktrees[0].branch, "main")
        XCTAssertEqual(worktrees[1].head, "bbb")
        XCTAssertTrue(worktrees[1].isDetached)
        XCTAssertNil(worktrees[1].branch)
        XCTAssertTrue(worktrees[1].isLocked)
        XCTAssertEqual(worktrees[1].lockedReason, "moved\nto usb")
        XCTAssertEqual(worktrees[2].branch, "feat/a")
        XCTAssertTrue(worktrees[2].isPrunable)
    }

    func testParsesBareAndReasonlessLock() {
        let worktrees = GitParsers.worktrees("worktree /r.git\0bare\0\0worktree /w\0HEAD a\0detached\0locked\0\0")
        XCTAssertTrue(worktrees[0].isBare)
        XCTAssertTrue(worktrees[1].isLocked)
        XCTAssertNil(worktrees[1].lockedReason)
    }

    func testParsesBranches() {
        let output = [
            ["refs/heads/main", "abc", "origin/main", "[ahead 1, behind 2]", "1700000000", "Fix: a | b", "refs/remotes/origin/main"],
            ["refs/heads/feat/x", "def", "", "", "1700000100", "", ""],
        ].map { $0.joined(separator: "\u{1f}") + "\u{1e}\n" }.joined()

        let branches = GitParsers.branches(output)

        XCTAssertEqual(branches.count, 2)
        XCTAssertEqual(branches[0].name, "main")
        XCTAssertEqual(branches[0].upstream, "origin/main")
        XCTAssertEqual(branches[0].upstreamRef, "refs/remotes/origin/main")
        XCTAssertEqual(branches[0].upstreamTrack, "[ahead 1, behind 2]")
        XCTAssertEqual(branches[0].subject, "Fix: a | b")
        XCTAssertEqual(branches[0].lastCommitDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(branches[1].name, "feat/x")
        XCTAssertNil(branches[1].upstream)
        XCTAssertNil(branches[1].upstreamRef)
        XCTAssertEqual(branches[1].subject, "")
    }

    func testParsesRemoteBranches() {
        let output = [
            ["refs/remotes/origin/HEAD", "refs/remotes/origin/main", "abc", "1700000000", "initial"],
            ["refs/remotes/origin/feat/x", "", "def", "1700000100", "Add x"],
            ["refs/remotes/team/fork/main", "", "123", "1700000200", ""],
            ["refs/remotes/removed/old", "", "456", "1700000300", "stale"],
        ].map { $0.joined(separator: "\u{1f}") + "\u{1e}\n" }.joined()

        let remotes = GitParsers.remoteBranches(output, remotes: ["origin", "team", "team/fork"])

        XCTAssertEqual(remotes.map(\.shortName), ["origin/feat/x", "team/fork/main", "removed/old"])
        XCTAssertEqual(remotes.map(\.remote), ["origin", "team/fork", "removed"])
        XCTAssertEqual(remotes.map(\.name), ["feat/x", "main", "old"])
        XCTAssertEqual(remotes[0].ref, "refs/remotes/origin/feat/x")
        XCTAssertEqual(remotes[0].sha, "def")
        XCTAssertEqual(remotes[0].subject, "Add x")
        XCTAssertEqual(remotes[0].lastCommitDate, Date(timeIntervalSince1970: 1_700_000_100))
    }
}
