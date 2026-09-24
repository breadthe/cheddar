import XCTest
@testable import Cheddar

final class DependencyTests: XCTestCase {
    private var bin: URL!

    override func setUpWithError() throws {
        bin = FileManager.default.temporaryDirectory.appendingPathComponent("cheddar-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: bin)
    }

    func testVersionParsingAndComparison() throws {
        XCTAssertEqual(Version("git version 2.39.5 (Apple Git-154)")?.description, "2.39.5")
        XCTAssertEqual(Version("2.0.14 (Claude Code)")?.description, "2.0.14")
        XCTAssertNil(Version("no digits"))
        XCTAssertEqual(Version("2.36"), Version("2.36.0"))
        XCTAssertLessThan(try XCTUnwrap(Version("2.35.9")), try XCTUnwrap(Version("2.36")))
        XCTAssertLessThan(try XCTUnwrap(Version("2.9")), try XCTUnwrap(Version("2.36")))
    }

    func testFindsGitOnSearchPath() async throws {
        try fakeTool("git", printing: "git version 2.49.0")
        let status = await DependencyChecker(searchPath: [bin.path]).status(of: Dependencies.git)
        XCTAssertEqual(status, .found(path: bin.appendingPathComponent("git").path, version: Version("2.49.0")))
    }

    func testFlagsTooOldGit() async throws {
        try fakeTool("git", printing: "git version 2.30.1")
        let status = await DependencyChecker(searchPath: [bin.path]).status(of: Dependencies.git)
        XCTAssertEqual(status, .tooOld(path: bin.appendingPathComponent("git").path, version: Version("2.30.1")!))
    }

    func testReportsGitThatFailsToRun() async throws {
        try fakeTool("git", script: "echo 'You have not agreed to the Xcode license' >&2; exit 69")
        let status = await DependencyChecker(searchPath: [bin.path]).status(of: Dependencies.git)
        guard case .failed(_, let message) = status else { return XCTFail("expected .failed, got \(status)") }
        XCTAssertTrue(message.contains("Xcode license"))
    }

    func testGitOverrideWinsOverSearchPath() async throws {
        try fakeTool("git", printing: "git version 2.40.0")
        let override = bin.appendingPathComponent("custom-git")
        try fakeTool("custom-git", printing: "git version 2.45.0")
        let status = await DependencyChecker(searchPath: [bin.path], gitOverride: override.path).status(of: Dependencies.git)
        XCTAssertEqual(status.path, override.path)
    }

    func testMissingBinary() async {
        let status = await DependencyChecker(searchPath: [bin.path]).status(of: Dependencies.claude)
        XCTAssertEqual(status, .missing)
    }

    private func fakeTool(_ name: String, printing output: String) throws {
        try fakeTool(name, script: "echo '\(output)'")
    }

    private func fakeTool(_ name: String, script: String) throws {
        let url = bin.appendingPathComponent(name)
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
