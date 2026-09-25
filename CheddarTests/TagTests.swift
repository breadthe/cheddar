import XCTest
@testable import Cheddar

final class TagParsingTests: XCTestCase {
    func testParsesTags() {
        let output = [
            ["refs/tags/v2", "aaa", "tag", "1700000100", "Release 2"],
            ["refs/tags/v1", "bbb", "commit", "1700000000", "initial"],
        ].map { $0.joined(separator: "\u{1f}") + "\u{1e}\n" }.joined()

        let tags = GitParsers.tags(output)

        XCTAssertEqual(tags.map(\.name), ["v2", "v1"])
        XCTAssertEqual(tags.map(\.isAnnotated), [true, false])
        XCTAssertEqual(tags[0].sha, "aaa")
        XCTAssertEqual(tags[0].subject, "Release 2")
        XCTAssertEqual(tags[1].date, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testParsesLsRemoteTagsSkippingPeeledLines() {
        let output = "111\trefs/tags/v1\n222\trefs/tags/v1^{}\n333\trefs/tags/release/2\n"

        XCTAssertEqual(GitParsers.lsRemoteTags(output), ["v1": "111", "release/2": "333"])
    }

    func testEntriesCompareEachTagWithEachRemote() {
        let local = ["synced", "unpushed", "differs", "half"].map {
            Tag(name: $0, sha: "sha-\($0)", isAnnotated: false, subject: "")
        }
        let remoteTags: RemoteTags = [
            "origin": ["synced": "sha-synced", "differs": "other", "half": "sha-half", "v0.9": "old"],
            "fork": ["synced": "sha-synced", "differs": "sha-differs"],
        ]

        let entries = TagEntry.entries(local: local, remoteTags: remoteTags, remotes: ["origin", "fork", "added-later"])

        XCTAssertEqual(entries.map(\.name), ["synced", "unpushed", "differs", "half", "v0.9"])
        let status = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.status!) })
        XCTAssertEqual(status["synced"]?.on, ["origin", "fork"])
        XCTAssertEqual(status["synced"]?.missingFrom, [], "a remote added since the fetch isn't compared")
        XCTAssertEqual(status["unpushed"]?.missingFrom, ["origin", "fork"])
        XCTAssertEqual(status["differs"]?.on, ["fork"])
        XCTAssertEqual(status["differs"]?.differsOn, ["origin"])
        XCTAssertEqual(status["differs"]?.remoteObjects["origin"], "other")
        XCTAssertEqual(status["half"]?.missingFrom, ["fork"])
        XCTAssertNil(entries.last?.local)
        XCTAssertEqual(status["v0.9"]?.on, ["origin"])
    }

    func testEntriesBeforeAnyFetchHaveNoStatus() {
        let local = [Tag(name: "v1", sha: "a", isAnnotated: false, subject: "")]

        let entries = TagEntry.entries(local: local, remoteTags: nil, remotes: ["origin"])

        XCTAssertEqual(entries.map(\.name), ["v1"])
        XCTAssertNil(entries[0].status)
    }
}

@MainActor
final class TagTests: XCTestCase {
    private var repo: TestRepo!
    private var service: GitService!
    private var model: ProjectModel!

    override func setUp() async throws {
        repo = try await TestRepo()
        service = GitService(git: repo.git, codexHome: repo.path("codex-home"))
        model = ProjectModel(project: Project(path: repo.repo.path), service: service)
    }

    override func tearDown() async throws {
        model = nil
        repo.remove()
    }

    /// A bare `origin` with main pushed, and a second clone to act as a teammate.
    private func addOriginAndTeammate() async throws -> URL {
        let bare = repo.root.appendingPathComponent("origin.git")
        try await repo.run("init", "--bare", "-b", "main", bare.path)
        try await repo.run("remote", "add", "origin", bare.path)
        try await repo.run("push", "-u", "origin", "main")
        let teammate = repo.root.appendingPathComponent("teammate")
        try await repo.run("clone", bare.path, teammate.path)
        try await repo.run("config", "user.name", "Teammate", in: teammate)
        try await repo.run("config", "user.email", "teammate@cheddar.invalid", in: teammate)
        return teammate
    }

    private func entry(_ name: String) -> TagEntry? {
        model.tagEntries.first { $0.name == name }
    }

    private func originTags() async throws -> [String: String] {
        GitParsers.lsRemoteTags(try await repo.run("ls-remote", "--tags", "origin"))
    }

    func testReadsLightweightAndAnnotatedTags() async throws {
        try await repo.run("tag", "light")
        try await repo.run("tag", "-a", "ann", "-m", "Release 1")

        let tags = try await service.snapshot(of: repo.repo).tags

        let light = try XCTUnwrap(tags.first { $0.name == "light" })
        XCTAssertFalse(light.isAnnotated)
        XCTAssertEqual(light.subject, "initial")
        let head = try await repo.run("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(light.sha, head)
        let ann = try XCTUnwrap(tags.first { $0.name == "ann" })
        XCTAssertTrue(ann.isAnnotated)
        XCTAssertEqual(ann.subject, "Release 1")
    }

    func testFetchComparesTagsWithTheRemote() async throws {
        let teammate = try await addOriginAndTeammate()
        try await repo.run("tag", "-a", "synced", "-m", "Synced")
        try await repo.run("push", "origin", "synced")
        try await repo.run("tag", "unpushed")
        // The teammate's v1 is on another commit than ours; fetch keeps ours and skips theirs.
        try await repo.run("commit", "--allow-empty", "-m", "theirs", in: teammate)
        try await repo.run("tag", "v1", in: teammate)
        try await repo.run("push", "origin", "main", "v1", in: teammate)
        try await repo.run("tag", "v1")
        // A tag on a commit no fetched branch reaches, so fetch doesn't bring it along.
        try await repo.run("checkout", "-q", "--detach", in: teammate)
        try await repo.run("commit", "--allow-empty", "-m", "experiment", in: teammate)
        try await repo.run("tag", "experiment", in: teammate)
        try await repo.run("push", "origin", "refs/tags/experiment", in: teammate)

        await model.load()
        XCTAssertNil(entry("synced")?.status, "no remote state before a Fetch")
        XCTAssertNil(entry("experiment"))

        await model.fetch()

        XCTAssertNil(model.alert)
        XCTAssertEqual(entry("synced")?.status?.on, ["origin"])
        XCTAssertEqual(entry("unpushed")?.status?.missingFrom, ["origin"])
        XCTAssertEqual(entry("v1")?.status?.differsOn, ["origin"])
        XCTAssertNotNil(entry("v1")?.local)
        XCTAssertNil(entry("experiment")?.local)
        XCTAssertEqual(entry("experiment")?.status?.on, ["origin"])
    }

    func testRemoteTagStateSurvivesSwitchingProjects() async throws {
        _ = try await addOriginAndTeammate()
        try await repo.run("tag", "v1")
        let cache = RemoteTagCache()
        model = ProjectModel(project: Project(path: repo.repo.path), service: service, remoteTagCache: cache)
        await model.load()
        await model.fetch()

        let reopened = ProjectModel(project: Project(path: repo.repo.path), service: service, remoteTagCache: cache)
        await reopened.load()

        XCTAssertEqual(reopened.tagEntries.first { $0.name == "v1" }?.status?.missingFrom, ["origin"])
    }

    func testPushTagUpdatesStateWithoutAnotherFetch() async throws {
        _ = try await addOriginAndTeammate()
        try await repo.run("tag", "v1")
        await model.load()
        await model.fetch()
        let tag = try XCTUnwrap(entry("v1")?.local)

        await model.pushTag(tag, to: "origin")

        XCTAssertNil(model.alert)
        XCTAssertEqual(entry("v1")?.status?.on, ["origin"])
        let remote = try await originTags()
        XCTAssertEqual(remote["v1"], tag.sha)
    }

    func testFetchTagThatIsOnlyOnTheRemote() async throws {
        let teammate = try await addOriginAndTeammate()
        try await repo.run("checkout", "-q", "--detach", in: teammate)
        try await repo.run("commit", "--allow-empty", "-m", "experiment", in: teammate)
        try await repo.run("tag", "experiment", in: teammate)
        try await repo.run("push", "origin", "refs/tags/experiment", in: teammate)
        await model.load()
        await model.fetch()
        XCTAssertNil(entry("experiment")?.local)

        await model.fetchTag("experiment", from: "origin")

        XCTAssertNil(model.alert)
        XCTAssertEqual(entry("experiment")?.local?.subject, "experiment")
        XCTAssertEqual(entry("experiment")?.status?.on, ["origin"])
    }

    func testDeleteRemoteTag() async throws {
        _ = try await addOriginAndTeammate()
        try await repo.run("tag", "v1")
        try await repo.run("push", "origin", "v1")
        await model.load()
        await model.fetch()
        let sha = try XCTUnwrap(entry("v1")?.status?.remoteObjects["origin"])

        await model.deleteRemoteTag(RemoteTagRef(name: "v1", remote: "origin", sha: sha))

        XCTAssertNil(model.alert)
        let remote = try await originTags()
        XCTAssertNil(remote["v1"])
        XCTAssertEqual(entry("v1")?.status?.missingFrom, ["origin"], "the local tag stays")
    }

    func testDeleteRemoteTagRefusesWhenItMoved() async throws {
        let teammate = try await addOriginAndTeammate()
        try await repo.run("tag", "v1")
        try await repo.run("push", "origin", "v1")
        await model.load()
        await model.fetch()
        let sha = try XCTUnwrap(entry("v1")?.status?.remoteObjects["origin"])
        try await repo.run("fetch", "origin", "--tags", in: teammate)
        try await repo.run("commit", "--allow-empty", "-m", "moved", in: teammate)
        try await repo.run("tag", "-f", "v1", in: teammate)
        try await repo.run("push", "-f", "origin", "v1", in: teammate)

        await model.deleteRemoteTag(RemoteTagRef(name: "v1", remote: "origin", sha: sha))

        XCTAssertTrue(model.alert?.message.hasPrefix("It changed on the remote since your last fetch") == true)
        let remote = try await originTags()
        XCTAssertNotNil(remote["v1"])
    }

    func testDeleteLocalTag() async throws {
        try await repo.run("tag", "v1")
        await model.load()
        let tag = try XCTUnwrap(entry("v1")?.local)

        await model.deleteTag(tag)

        XCTAssertNil(entry("v1"))
    }

    func testRenameLightweightTag() async throws {
        try await repo.run("tag", "v1")
        await model.load()
        let tag = try XCTUnwrap(entry("v1")?.local)

        try await model.renameTag(tag, to: "release/1")

        XCTAssertNil(entry("v1"))
        let renamed = try XCTUnwrap(entry("release/1")?.local)
        XCTAssertFalse(renamed.isAnnotated)
        XCTAssertEqual(renamed.sha, tag.sha)
    }

    func testRenameAnnotatedTagKeepsMessageAndTarget() async throws {
        try await repo.run("tag", "-a", "v1", "--cleanup=verbatim", "-m", "Release 1\n\nNotes\n# not a comment\n")
        await model.load()
        let tag = try XCTUnwrap(entry("v1")?.local)

        try await model.renameTag(tag, to: "v1.0")

        XCTAssertNil(entry("v1"))
        let renamed = try XCTUnwrap(entry("v1.0")?.local)
        XCTAssertTrue(renamed.isAnnotated)
        let object = try await repo.run("cat-file", "-p", "v1.0")
        XCTAssertTrue(object.contains("type commit"), "points at the commit, not at the old tag")
        XCTAssertTrue(object.hasSuffix("Release 1\n\nNotes\n# not a comment\n"))
        let targets = try await repo.run("rev-parse", "v1.0^{}", "HEAD").split(separator: "\n")
        XCTAssertEqual(targets[0], targets[1])
    }

    func testRenameRejectsInvalidAndTakenNames() async throws {
        try await repo.run("tag", "v1")
        try await repo.run("tag", "v2")
        await model.load()
        let tag = try XCTUnwrap(entry("v1")?.local)

        do {
            try await model.renameTag(tag, to: "bad name")
            XCTFail("accepted an invalid name")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn't a valid tag name"))
        }
        do {
            try await model.renameTag(tag, to: "v2")
            XCTFail("overwrote an existing tag")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }
        XCTAssertNotNil(entry("v1"), "a failed rename keeps the old tag")
    }
}
