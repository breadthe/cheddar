import XCTest
@testable import Cheddar

final class CommandLogTests: XCTestCase {
    private func roles(_ arguments: [String]) -> [String] {
        CommandLog.tokens(for: arguments).map { "\($0.text):\($0.role)" }
    }

    func testClassifiesSubcommandFlagsAndArguments() {
        XCTAssertEqual(roles(["worktree", "add", "-b", "feat/x", ".cheddar/worktrees/feat-x", "main"]), [
            "git:program", "worktree:subcommand", "add:argument", "-b:flag", "feat/x:argument",
            ".cheddar/worktrees/feat-x:argument", "main:argument",
        ])
        XCTAssertEqual(roles(["status", "--porcelain=v2", "-uall"]), [
            "git:program", "status:subcommand", "--porcelain=v2:flag", "-uall:flag",
        ])
    }

    func testEverythingAfterSeparatorIsAnArgument() {
        XCTAssertEqual(roles(["stash", "push", "-m", "a b", "--", ".", "-weird"]), [
            "git:program", "stash:subcommand", "push:argument", "-m:flag", "'a b':argument",
            "--:flag", ".:argument", "-weird:argument",
        ])
    }

    @MainActor
    func testLoggedCommandKeepsTokens() {
        let log = CommandLog()
        log.record(arguments: ["branch", "-d", "x"], directory: URL(fileURLWithPath: "/tmp"),
                   result: .failure(CancellationError()))
        XCTAssertEqual(log.entries.last?.command, "git branch -d x")
        XCTAssertEqual(log.entries.last?.tokens.map(\.role), [.program, .subcommand, .flag, .argument])
    }
}
