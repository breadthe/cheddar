import XCTest
@testable import Cheddar

@MainActor
final class AppStateTests: XCTestCase {
    private var repo: TestRepo!
    private var service: GitService!
    private var storeURL: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        repo = try await TestRepo()
        service = GitService(git: repo.git)
        storeURL = repo.root.appendingPathComponent("support/projects.json")
        suiteName = "cheddar-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        repo.remove()
    }

    private func makeState() -> AppState {
        AppState(storeURL: storeURL, defaults: defaults)
    }

    func testAddsRepoAndPersistsIt() async throws {
        let state = makeState()
        try await state.addProject(at: repo.repo, using: service)

        XCTAssertEqual(state.projects.map(\.path), [repo.repo.path])
        XCTAssertEqual(state.selection, repo.repo.path)
        XCTAssertEqual(makeState().projects.map(\.path), [repo.repo.path])
        XCTAssertEqual(makeState().selection, repo.repo.path)
    }

    func testLinkedWorktreeAndSubfolderResolveToMainRepoWithoutDuplicates() async throws {
        let linked = repo.path("repo/.claude/worktrees/wt")
        try await repo.run("worktree", "add", "-b", "wt", linked)
        let subfolder = repo.repo.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let state = makeState()

        try await state.addProject(at: URL(fileURLWithPath: linked), using: service)
        try await state.addProject(at: subfolder, using: service)
        try await state.addProject(at: repo.repo, using: service)

        XCTAssertEqual(state.projects.map(\.path), [repo.repo.path])
    }

    func testProjectsAreSortedByName() async throws {
        let other = repo.root.appendingPathComponent("aardvark")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await repo.run("init", "-b", "main", in: other)
        let state = makeState()

        try await state.addProject(at: repo.repo, using: service)
        try await state.addProject(at: other, using: service)

        XCTAssertEqual(state.projects.map(\.name), ["aardvark", "repo"])
        XCTAssertEqual(state.selection, other.path)
    }

    func testRejectsFolderThatIsNotARepo() async throws {
        let plain = repo.root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let state = makeState()

        do {
            try await state.addProject(at: plain, using: service)
            XCTFail("expected an error")
        } catch let error as GitError {
            XCTAssertTrue(error.localizedDescription.contains("not a git repository"), error.localizedDescription)
        }
        XCTAssertTrue(state.projects.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }

    func testRejectsBareRepo() async throws {
        let bare = repo.root.appendingPathComponent("bare.git")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try await repo.run("init", "--bare", in: bare)

        do {
            try await makeState().addProject(at: bare, using: service)
            XCTFail("expected an error")
        } catch is BareRepositoryError {}
    }

    func testRemoveNeverTouchesDiskAndMovesSelection() async throws {
        let other = repo.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await repo.run("init", "-b", "main", in: other)
        let state = makeState()
        try await state.addProject(at: repo.repo, using: service)
        try await state.addProject(at: other, using: service)

        try state.removeProject(try XCTUnwrap(state.selectedProject))

        XCTAssertEqual(state.projects.map(\.name), ["repo"])
        XCTAssertEqual(state.selection, repo.repo.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent(".git").path))
        XCTAssertEqual(makeState().projects.map(\.name), ["repo"])
    }

    func testTrunkOverrideIsSavedPerProject() async throws {
        let state = makeState()
        try await state.addProject(at: repo.repo, using: service)
        let project = try XCTUnwrap(state.selectedProject)

        try state.setTrunk("develop", for: project)
        XCTAssertEqual(makeState().projects.first?.trunk, "develop")

        try state.setTrunk(nil, for: try XCTUnwrap(state.selectedProject))
        XCTAssertNil(makeState().projects.first?.trunk)
        XCTAssertEqual(state.selection, repo.repo.path)
    }

    func testUnreadableStoreIsMovedAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: storeURL)

        XCTAssertTrue(makeState().projects.isEmpty)

        let files = try FileManager.default.contentsOfDirectory(atPath: storeURL.deletingLastPathComponent().path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasPrefix("projects.unreadable-"), files[0])
    }
}
