import XCTest
@testable import Cheddar

/// Clean Up (merged branches, missing worktrees), disk usage and build artifacts.
@MainActor
final class HygieneTests: XCTestCase {
    private var repo: TestRepo!
    private var service: GitService!

    override func setUp() async throws {
        repo = try await TestRepo()
        service = GitService(git: repo.git)
    }

    override func tearDown() async throws {
        repo.remove()
    }

    private func loadedModel() async throws -> ProjectModel {
        let model = ProjectModel(project: Project(path: repo.repo.path), service: service)
        await model.load()
        _ = try XCTUnwrap(model.snapshot, model.loadError ?? "no snapshot")
        return model
    }

    func testCleanUpPrunesMissingWorktreesThenDeletesMergedBranches() async throws {
        for branch in ["done", "gone", "busy", "wip"] {
            try await service.createBranch(branch, base: nil, in: repo.repo)
        }
        let wip = repo.path("repo/.cheddar/worktrees/wip")
        try await repo.run("worktree", "add", wip, "wip")
        try await repo.run("commit", "--allow-empty", "-m", "only on wip", in: URL(fileURLWithPath: wip))
        let gone = repo.path("repo/.cheddar/worktrees/gone")
        try await repo.run("worktree", "add", gone, "gone")
        try FileManager.default.removeItem(atPath: gone)
        try await repo.run("worktree", "add", repo.path("repo/.cheddar/worktrees/busy"), "busy")
        let model = try await loadedModel()

        // `busy` and `wip` are checked out in present worktrees (and `wip` isn't merged); `gone`'s only
        // checkout is missing, so pruning it frees the branch.
        let candidates = model.cleanUpCandidates
        XCTAssertEqual(Set(candidates.branches.map(\.name)), ["done", "gone"])
        XCTAssertEqual(candidates.worktrees.map(\.path), [gone])

        let result = try await model.cleanUp(pruning: candidates.worktrees, deletingBranches: candidates.branches.map(\.name))

        XCTAssertEqual(result.pruned, ["gone"])
        XCTAssertEqual(Set(result.deleted), ["done", "gone"])
        XCTAssertEqual(result.skipped, [])
        XCTAssertEqual(Set(model.snapshot?.branches.map(\.name) ?? []), ["main", "busy", "wip"])
        XCTAssertFalse(model.snapshot?.worktrees.contains { $0.isMissing } ?? true)
    }

    func testNothingToCleanUpSaysSo() async throws {
        let model = try await loadedModel()
        model.requestCleanUp()
        XCTAssertNil(model.sheet)
        XCTAssertEqual(model.alert?.title, "Nothing to Clean Up")
    }

    func testDiskUsageSkipsLinksAndNestedWorktrees() throws {
        let root = repo.path("sizes")
        try FileManager.default.createDirectory(atPath: root + "/nested", withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: URL(fileURLWithPath: root + "/file"))
        try Data(count: 50_000).write(to: URL(fileURLWithPath: root + "/nested/big"))
        try Data(count: 80_000).write(to: URL(fileURLWithPath: repo.path("outside")))
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: repo.path("outside"))

        let all = DiskUsage.size(of: root)
        let withoutNested = DiskUsage.size(of: root, excluding: [root + "/nested"])

        XCTAssertGreaterThanOrEqual(withoutNested, 10_000)
        XCTAssertLessThan(withoutNested, 50_000, "the linked 80 KB file and the nested folder don't count")
        XCTAssertGreaterThanOrEqual(all - withoutNested, 50_000)
    }

    func testBuildArtifactsAreIgnoredRealFolders() async throws {
        try "node_modules/\nvendor\ndist/\n".write(toFile: repo.repo.path + "/.gitignore", atomically: true, encoding: .utf8)
        try await repo.run("add", ".gitignore")
        try await repo.run("commit", "-m", "ignore")
        let path = repo.path("repo/.claude/worktrees/feat")
        try await repo.run("worktree", "add", "-b", "feat", path)
        try FileManager.default.createDirectory(atPath: path + "/node_modules/pkg", withIntermediateDirectories: true)
        try Data(count: 20_000).write(to: URL(fileURLWithPath: path + "/node_modules/pkg/index.js"))
        // Run's link to main's folder isn't an artifact of this worktree; `build/` isn't ignored.
        try FileManager.default.createDirectory(atPath: repo.repo.path + "/vendor", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path + "/vendor", withDestinationPath: repo.repo.path + "/vendor")
        try FileManager.default.createDirectory(atPath: path + "/build", withIntermediateDirectories: true)
        let model = try await loadedModel()
        let worktree = try XCTUnwrap(model.snapshot?.worktrees.first { $0.path == path })

        await model.requestCleanArtifacts(worktree)

        guard case .cleanArtifacts(let target, let artifacts) = model.sheet else {
            return XCTFail("expected the Clean Build Artifacts sheet, got \(String(describing: model.sheet?.id)) / \(String(describing: model.alert?.message))")
        }
        XCTAssertEqual(target.path, path)
        XCTAssertEqual(artifacts.map(\.path), ["node_modules"])
        XCTAssertGreaterThanOrEqual(artifacts[0].size, 20_000)
    }
}
