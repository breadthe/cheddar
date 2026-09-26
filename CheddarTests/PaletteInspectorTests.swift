import XCTest
@testable import Cheddar

final class PaletteMatcherTests: XCTestCase {
    private let projects = [Project(path: "/code/api"), Project(path: "/code/storefront")]

    func testMatchesSubsequencesAndPrefersWordStartsAndRuns() {
        XCTAssertNotNil(PaletteMatcher.score("sfl", in: "storefront feat-login"))
        XCTAssertNil(PaletteMatcher.score("xyz", in: "storefront feat-login"))
        XCTAssertNil(PaletteMatcher.score("nigol", in: "storefront feat-login"), "order matters")
        XCTAssertGreaterThan(PaletteMatcher.score("login", in: "feat-login")!, PaletteMatcher.score("login", in: "flog-in")!)
        XCTAssertEqual(PaletteMatcher.score("  ", in: "anything"), 0)
    }

    func testWorktreesThenBranchesThenProjectsWithTheSelectedProjectFirst() {
        let contents: [Project.ID: PaletteContents] = [
            "/code/api": PaletteContents(worktrees: [Worktree(path: "/code/api", displayName: "api")],
                                         branches: [Branch(name: "main", sha: "a", subject: "")]),
            "/code/storefront": PaletteContents(worktrees: [Worktree(path: "/code/storefront", displayName: "storefront")],
                                                branches: [Branch(name: "feat/login", sha: "b", subject: "")]),
        ]
        let items = PaletteMatcher.items(projects: projects, contents: contents, selected: "/code/storefront")

        XCTAssertEqual(items.map(\.id), [
            "w:/code/storefront:/code/storefront", "w:/code/api:/code/api",
            "b:/code/storefront:feat/login", "b:/code/api:main",
            "p:/code/storefront", "p:/code/api",
        ])
        XCTAssertEqual(items.map(\.rowTag), ["w:/code/storefront", "w:/code/api", "b:feat/login", "b:main", nil, nil])
    }

    func testFilterRanksBestMatchFirst() {
        let items: [PaletteItem] = [
            .project(Project(path: "/code/flogin")),
            .worktree(Worktree(path: "/x", branch: "feat/login", displayName: "feat-login"), in: projects[1]),
        ]
        XCTAssertEqual(PaletteMatcher.filter(items, query: "feat login").map(\.id), ["w:/code/storefront:/x"])
        XCTAssertEqual(PaletteMatcher.filter(items, query: "login").first?.id, "w:/code/storefront:/x")
        XCTAssertEqual(PaletteMatcher.filter(items, query: "").count, 2)
    }
}

final class DiffParsingTests: XCTestCase {
    func testParsesPorcelainZWithRenamesAndSpaces() {
        let output = " M src/app.js\0R  new name.txt\0old name.txt\0?? notes/todo list.md\0"
        let files = ChangedFile.parse(porcelainZ: output)
        XCTAssertEqual(files.map(\.path), ["src/app.js", "new name.txt", "notes/todo list.md"])
        XCTAssertEqual(files.map(\.status), [" M", "R ", "??"])
        XCTAssertEqual(files[1].originalPath, "old name.txt")
        XCTAssertTrue(files[2].isUntracked)
    }

    func testParsesLog() {
        let output = "abc123\u{1F}abc\u{1F}Fix: a | b\u{1F}Ada\u{1F}1700000000\u{1E}\ndef456\u{1F}def\u{1F}Second\u{1F}Bob\u{1F}1700000100\u{1E}\n"
        let commits = Commit.parse(log: output)
        XCTAssertEqual(commits.map(\.shortSHA), ["abc", "def"])
        XCTAssertEqual(commits[0].subject, "Fix: a | b")
        XCTAssertEqual(commits[1].date, Date(timeIntervalSince1970: 1_700_000_100))
    }

    func testClassifiesDiffLinesAndTruncates() {
        let diff = "commit abc\nAuthor: Ada\ndiff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n same\n"
        let (lines, truncated) = DiffLine.parse(diff)
        XCTAssertEqual(lines.map(\.kind), [.commit, .meta, .meta, .meta, .meta, .hunk, .removed, .added, .context])
        XCTAssertFalse(truncated)

        let long = Array(repeating: "+x", count: DiffLine.limit + 10).joined(separator: "\n")
        let (capped, isTruncated) = DiffLine.parse(long)
        XCTAssertEqual(capped.count, DiffLine.limit)
        XCTAssertTrue(isTruncated)
    }
}

@MainActor
final class InspectorModelTests: XCTestCase {
    private var repo: TestRepo!
    private var service: GitService!

    override func setUp() async throws {
        repo = try await TestRepo()
        service = GitService(git: repo.git)
    }

    override func tearDown() async throws {
        repo.remove()
    }

    func testWorktreeShowsItsChangesCommitsAheadAndDiffs() async throws {
        let path = repo.path("repo/.claude/worktrees/feat")
        try await repo.run("worktree", "add", "-b", "feat", path)
        let directory = URL(fileURLWithPath: path)
        try "one\n".write(toFile: path + "/tracked.txt", atomically: true, encoding: .utf8)
        try await repo.run("add", "tracked.txt", in: directory)
        try await repo.run("commit", "-m", "Add tracked", in: directory)
        try "one\ntwo\n".write(toFile: path + "/tracked.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: path + "/fresh.txt", atomically: true, encoding: .utf8)
        let worktrees = try await service.worktrees(in: repo.repo)
        let worktree = try XCTUnwrap(worktrees.first { $0.path == path })
        let inspector = InspectorModel(service: service)

        await inspector.load(.worktree(worktree, nested: []), trunk: "main", repo: repo.repo.path)

        XCTAssertEqual(inspector.files?.map(\.path).sorted(), ["fresh.txt", "tracked.txt"])
        XCTAssertEqual(inspector.commitsTitle, "Not on main")
        XCTAssertEqual(inspector.commits.map(\.subject), ["Add tracked"])
        XCTAssertNotNil(inspector.selected, "the first changed file is selected")

        let tracked = try XCTUnwrap(inspector.files?.first { $0.path == "tracked.txt" })
        await inspector.select(.file(tracked))
        XCTAssertTrue(inspector.diff.contains { $0.kind == .added && $0.text == "+two" })
        let fresh = try XCTUnwrap(inspector.files?.first { $0.isUntracked })
        await inspector.select(.file(fresh))
        XCTAssertTrue(inspector.diff.contains { $0.kind == .added && $0.text == "+new" })
        await inspector.select(.commit(inspector.commits[0]))
        XCTAssertTrue(inspector.diff.contains { $0.kind == .commit })
        XCTAssertTrue(inspector.diff.contains { $0.text == "    Add tracked" })
    }

    func testMainLeavesOutNestedWorktreesAndShowsRecentCommitsOnTrunk() async throws {
        let nested = repo.path("repo/.claude/worktrees/feat")
        try await repo.run("worktree", "add", "-b", "feat", nested)
        let worktrees = try await service.worktrees(in: repo.repo)
        let main = try XCTUnwrap(worktrees.first { $0.origin == .main })
        let inspector = InspectorModel(service: service)

        await inspector.load(.worktree(main, nested: [nested]), trunk: "main", repo: repo.repo.path)

        XCTAssertEqual(inspector.files, [], "the nested worktree folder isn't a change of main's")
        XCTAssertEqual(inspector.commitsTitle, "Recent commits")
        XCTAssertEqual(inspector.commits.map(\.subject), ["initial"])
    }

    func testBranchShowsCommitsNotOnTrunk() async throws {
        try await repo.run("switch", "-c", "topic")
        try await repo.run("commit", "--allow-empty", "-m", "On topic")
        try await repo.run("switch", "main")
        let branches = try await service.branches(in: repo.repo)
        let branch = try XCTUnwrap(branches.first { $0.name == "topic" })
        let inspector = InspectorModel(service: service)

        await inspector.load(.branch(branch), trunk: "main", repo: repo.repo.path)

        XCTAssertNil(inspector.files)
        XCTAssertEqual(inspector.commits.map(\.subject), ["On topic"])
        XCTAssertNil(inspector.selected)
    }
}
