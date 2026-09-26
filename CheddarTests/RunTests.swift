import Darwin
import XCTest
@testable import Cheddar

/// Run's pure pieces: what to clone and install, the dev command, reading URLs from output, Herd's config.
final class RunRecipeTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = Paths.canonical(FileManager.default.temporaryDirectory.appendingPathComponent("cheddar-run-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ relative: String, _ contents: String = "") throws {
        let path = (root as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func dir(_ relative: String) -> String { (root as NSString).appendingPathComponent(relative) }

    func testCloneCandidatesAreEnvFilesAndDependencyFolders() throws {
        for file in [".env", ".env.local", "composer.json", "vendor/autoload.php", "node_modules/x/index.js", "src/app.js"] {
            try write("main/\(file)")
        }
        try FileManager.default.createDirectory(atPath: dir("main/.env.d"), withIntermediateDirectories: true)

        XCTAssertEqual(RunRecipe.cloneCandidates(inMain: dir("main")), [".env", ".env.local", "node_modules", "vendor"])
    }

    func testInstallsWhenTheLockfileDiffersOrDependenciesAreMissing() throws {
        try write("main/composer.lock", "a")
        try write("main/package-lock.json", "a")
        try write("wt/composer.lock", "a")
        try write("wt/vendor/autoload.php")
        try write("wt/package-lock.json", "a")
        try write("wt/node_modules/x")
        XCTAssertEqual(RunRecipe.installs(worktree: dir("wt"), main: dir("main")), [])

        try write("wt/composer.lock", "b")
        XCTAssertEqual(RunRecipe.installs(worktree: dir("wt"), main: dir("main")), ["composer install"])

        try FileManager.default.removeItem(atPath: dir("wt/node_modules"))
        XCTAssertEqual(RunRecipe.installs(worktree: dir("wt"), main: dir("main")), ["composer install", "npm ci"])
    }

    func testDevCommandPrefersComposerThenThePackageManagersDevScript() throws {
        XCTAssertNil(RunRecipe.devCommand(in: root))
        try write("package.json", #"{"scripts": {"build": "vite build"}}"#)
        XCTAssertNil(RunRecipe.devCommand(in: root))

        try write("package.json", #"{"scripts": {"dev": "vite"}}"#)
        XCTAssertEqual(RunRecipe.devCommand(in: root), "npm run dev")
        try write("pnpm-lock.yaml")
        XCTAssertEqual(RunRecipe.devCommand(in: root), "pnpm run dev")

        try write("composer.json", #"{"scripts": {"dev": ["npx concurrently ..."]}}"#)
        XCTAssertEqual(RunRecipe.devCommand(in: root), "composer run dev")
    }

    func testReadsTheAppURLFromDevServerOutput() {
        let vite = "  \u{1B}[32m➜\u{1B}[39m  \u{1B}[1mLocal\u{1B}[22m:   \u{1B}[36mhttp://localhost:\u{1B}[1m5173\u{1B}[22m/\u{1B}[39m"
        let serve = "   INFO  Server running on [http://127.0.0.1:8001]."

        XCTAssertEqual(RunRecipe.url(inOutputLine: vite, laravel: false)?.absoluteString, "http://localhost:5173/")
        XCTAssertEqual(RunRecipe.url(inOutputLine: serve, laravel: false)?.absoluteString, "http://127.0.0.1:8001")
        XCTAssertEqual(RunRecipe.url(inOutputLine: "ready on http://0.0.0.0:3000", laravel: false)?.absoluteString, "http://localhost:3000")
        XCTAssertNil(RunRecipe.url(inOutputLine: "see https://laravel.com/docs", laravel: false))
        // In a Laravel app, Vite's URL is only its asset server.
        XCTAssertNil(RunRecipe.url(inOutputLine: vite, laravel: true))
        XCTAssertEqual(RunRecipe.url(inOutputLine: serve, laravel: true)?.absoluteString, "http://127.0.0.1:8001")
        XCTAssertTrue(RunRecipe.announcesServer(vite))
    }

    func testDatabasesAreSQLiteFilesNotTheirCompanions() {
        XCTAssertTrue(RunRecipe.isDatabase("database/1secret-v2.sqlite"))
        XCTAssertTrue(RunRecipe.isDatabase("db.sqlite3"))
        XCTAssertTrue(RunRecipe.isDatabase("prisma/dev.db"))
        XCTAssertFalse(RunRecipe.isDatabase("database/app.sqlite-wal"))
        XCTAssertFalse(RunRecipe.isDatabase("database/app.sqlite-journal"))
    }

    func testUploadFoldersDependOnTheStack() throws {
        XCTAssertEqual(RunRecipe.uploadRoots(in: root), [])
        try write("manage.py")
        XCTAssertEqual(RunRecipe.uploadRoots(in: root), ["media/"])
        try write("artisan")
        let laravel = RunRecipe.uploadRoots(in: root)
        XCTAssertEqual(laravel, ["storage/app/", "public/storage"])

        XCTAssertTrue(RunRecipe.isSharedData("storage/app/private/files/", uploadRoots: laravel))
        XCTAssertTrue(RunRecipe.isSharedData("storage/app/private/list.txt", uploadRoots: laravel))
        XCTAssertTrue(RunRecipe.isSharedData("public/storage", uploadRoots: laravel))
        XCTAssertTrue(RunRecipe.isSharedData("database/app.sqlite", uploadRoots: laravel))
        XCTAssertFalse(RunRecipe.isSharedData("storage/framework/views/abc.php", uploadRoots: laravel))
        XCTAssertFalse(RunRecipe.isSharedData("storage/logs/laravel.log", uploadRoots: laravel))
        XCTAssertFalse(RunRecipe.isSharedData("public/storage-old", uploadRoots: laravel))
        XCTAssertFalse(RunRecipe.isSharedData("node_modules/", uploadRoots: laravel))
    }

    func testScriptAnnouncesEachStepAndGroupsTheDevCommand() {
        XCTAssertEqual(RunRecipe.script(installs: ["npm ci"], devCommand: "npm run dev"),
                       "printf '%s\\n' '$ npm ci' && npm ci && printf '%s\\n' '$ npm run dev' && {\nnpm run dev\n}")
    }

    func testAFailedInstallStopsTheWholeDevCommand() async throws {
        let script = RunRecipe.script(installs: ["false"], devCommand: "echo a; echo b")
        let output = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script])
        XCTAssertEqual(output.stdoutString, "$ false\n")
        XCTAssertNotEqual(output.exitCode, 0)
    }

    // MARK: Herd

    private func herd() throws -> Herd {
        let config = dir("herd")
        try write("herd/config.json", #"{"tld": "test", "paths": ["\#(config)/Sites", "\#(dir("parked"))/"]}"#)
        try write("herd/Certificates/linked.test.crt")
        try write("herd/Nginx/linked.test", "fastcgi_pass $herd_sock_84;")
        try FileManager.default.createDirectory(atPath: dir("apps/linked-app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir("parked/blog"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir("herd/Sites"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir("herd/Sites/linked"), withDestinationPath: dir("apps/linked-app"))
        try FileManager.default.createSymbolicLink(atPath: dir("herd/Sites/linked-feat-login"), withDestinationPath: dir("apps/other"))
        return Herd(executable: "/usr/bin/false", searchPath: [], configDirectory: config)
    }

    func testFindsMainsHerdSiteByLinkOrParkedFolder() throws {
        let herd = try herd()

        XCTAssertEqual(herd.site(servingPath: dir("apps/linked-app")),
                       Herd.Site(name: "linked", tld: "test", isSecure: true, phpVersion: "8.4"))
        XCTAssertEqual(herd.site(servingPath: dir("parked/blog")),
                       Herd.Site(name: "blog", tld: "test", isSecure: false, phpVersion: nil))
        XCTAssertNil(herd.site(servingPath: dir("apps")))
    }

    func testWorktreeSiteNamesAvoidTakenNamesAndTheMainSitesWildcard() throws {
        let herd = try herd()
        let site = Herd.Site(name: "linked", tld: "test", isSecure: true)

        XCTAssertEqual(herd.siteName(for: "Feat/Login", of: site), "linked-feat-login-2")
        XCTAssertEqual(herd.siteName(for: "a1b2/linked-app", of: site), "linked-a1b2-linked-app")
        XCTAssertEqual(site.url.absoluteString, "https://linked.test")
    }
}

/// A real dev process and a real run against a throwaway repo.
@MainActor
final class RunManagerTests: XCTestCase {
    private var repo: TestRepo!
    private var suiteName: String!

    override func setUp() async throws {
        repo = try await TestRepo()
        suiteName = "cheddar-run-tests-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        repo.remove()
    }

    func testStopKillsTheWholeProcessGroup() async throws {
        let lines = LineCollector()
        let process = try DevProcess.start(
            "sleep 60 & echo \"child $!\"; wait", in: repo.root.path, environment: ["PATH": "/usr/bin:/bin"],
            onLine: { lines.add($0) }, onExit: { _ in })
        let childLine = try await lines.first { $0.hasPrefix("child ") }
        let child = try XCTUnwrap(pid_t(childLine.dropFirst("child ".count)))
        XCTAssertEqual(kill(child, 0), 0)

        process.terminate()
        await process.waitForExit()
        try await eventually { kill(child, 0) == -1 && errno == ESRCH }
    }

    func testRunClonesFromMainOpensTheAnnouncedURLAndStops() async throws {
        let main = repo.repo.path
        try ".env\nnode_modules/\n*.sqlite*\n".write(toFile: main + "/.gitignore", atomically: true, encoding: .utf8)
        try "APP_KEY=secret\nDB_DATABASE=database/app.sqlite\n".write(toFile: main + "/.env", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: main + "/database", withIntermediateDirectories: true)
        try "db".write(toFile: main + "/database/app.sqlite", atomically: true, encoding: .utf8)
        try "wal".write(toFile: main + "/database/app.sqlite-wal", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: main + "/node_modules/left-pad", withIntermediateDirectories: true)
        try await repo.run("add", ".gitignore")
        try await repo.run("commit", "-m", "ignore")
        let path = repo.path("repo/.claude/worktrees/feat")
        try await repo.run("worktree", "add", "-b", "feat", path)
        let service = GitService(git: repo.git)
        let snapshot = try await service.snapshot(of: repo.repo)
        let worktree = try XCTUnwrap(snapshot.worktrees.first { $0.path == path })

        var opened: [URL] = []
        let runs = RunManager(log: nil, defaults: UserDefaults(suiteName: suiteName)!, openURL: { opened.append($0) })
        await runs.run(worktree, projectPath: main, devCommand: "echo 'Local: http://localhost:4321/'; sleep 60",
                       service: service, searchPath: SearchPath.system)
        let session = try XCTUnwrap(runs.sessions[path])
        try await eventually { session.phase == .running }

        XCTAssertEqual(opened.map(\.absoluteString), ["http://localhost:4321/"])
        XCTAssertEqual(try String(contentsOfFile: path + "/.env", encoding: .utf8), "APP_KEY=secret\nDB_DATABASE=database/app.sqlite\n")
        // main's database, shared through a link at the same relative path; its WAL isn't linked.
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path + "/database/app.sqlite"), main + "/database/app.sqlite")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/database/app.sqlite-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/node_modules/left-pad"))
        let status = try await repo.run("status", "--porcelain", in: URL(fileURLWithPath: path))
        XCTAssertEqual(status, "", "clones are ignored, so the worktree stays clean")

        // Removing the worktree (as an agent might) stops its run on the next refresh.
        try await repo.run("worktree", "remove", "--force", path)
        await runs.reconcile(projectPath: main, presentWorktrees: [main])
        XCTAssertEqual(session.phase, .stopped)
    }

    /// Laid out like a Laravel app: `storage/app/private/` is tracked (for its `.gitignore`), its contents aren't.
    func testRunSharesLaravelUploadsButNotLogsOrCaches() async throws {
        let main = repo.repo.path
        let files: [String: String] = [
            "artisan": "",
            "storage/app/private/.gitignore": "*\n!.gitignore\n",
            "storage/app/private/files/upload.pdf": "pdf",
            "storage/app/private/list.txt": "list",
            "storage/logs/.gitignore": "*\n!.gitignore\n",
            "storage/logs/laravel.log": "main's log",
            "storage/framework/.gitignore": "*\n!.gitignore\n",
            "storage/framework/views/compiled.php": "main's path",
        ]
        for (relative, contents) in files {
            let path = main + "/" + relative
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
        }
        try "/public/storage\n".write(toFile: main + "/.gitignore", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: main + "/public", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: main + "/public/storage", withDestinationPath: main + "/storage/app/public")
        try await repo.run("add", ".")
        try await repo.run("commit", "-m", "laravel")
        let path = repo.path("repo/.claude/worktrees/feat")
        try await repo.run("worktree", "add", "-b", "feat", path)
        let service = GitService(git: repo.git)
        let snapshot = try await service.snapshot(of: repo.repo)
        let worktree = try XCTUnwrap(snapshot.worktrees.first { $0.path == path })
        let runs = RunManager(log: nil, defaults: UserDefaults(suiteName: suiteName)!, openURL: { _ in })

        await runs.run(worktree, projectPath: main, devCommand: "sleep 60", service: service, searchPath: SearchPath.system)
        let session = try XCTUnwrap(runs.sessions[path])
        try await eventually { session.lines.contains { $0.text == "$ sleep 60" } }

        let fm = FileManager.default
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: path + "/storage/app/private/files"), main + "/storage/app/private/files")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: path + "/storage/app/private/list.txt"), main + "/storage/app/private/list.txt")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: path + "/public/storage"), main + "/public/storage")
        XCTAssertEqual(try String(contentsOfFile: path + "/storage/app/private/files/upload.pdf", encoding: .utf8), "pdf")
        XCTAssertFalse(fm.fileExists(atPath: path + "/storage/logs/laravel.log"))
        XCTAssertFalse(fm.fileExists(atPath: path + "/storage/framework/views/compiled.php"))
        let status = try await repo.run("status", "--porcelain", in: URL(fileURLWithPath: path))
        XCTAssertEqual(status, "")

        await runs.stop(path)
        try await repo.run("worktree", "remove", path)
        XCTAssertEqual(try String(contentsOfFile: main + "/storage/app/private/files/upload.pdf", encoding: .utf8), "pdf",
                       "removing the worktree removes the links, not main's files")
    }

    func testADevCommandThatExitsIsReported() async throws {
        let main = repo.repo.path
        let path = repo.path("repo/.cheddar/worktrees/x")
        try await repo.run("worktree", "add", "-b", "x", path)
        let service = GitService(git: repo.git)
        let snapshot = try await service.snapshot(of: repo.repo)
        let worktree = try XCTUnwrap(snapshot.worktrees.first { $0.path == path })
        let runs = RunManager(log: nil, defaults: UserDefaults(suiteName: suiteName)!, openURL: { _ in XCTFail("nothing to open") })

        await runs.run(worktree, projectPath: main, devCommand: "echo boom; exit 3", service: service, searchPath: SearchPath.system)
        let session = try XCTUnwrap(runs.sessions[path])
        try await eventually { session.phase == .exited(3) }
        XCTAssertTrue(session.hasFailed)
        XCTAssertTrue(session.lines.map(\.text).contains("boom"))

        runs.close(path)
        XCTAssertNil(runs.sessions[path])
    }

    private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw OperationError(errorDescription: "condition not met in time") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Collects output lines from `DevProcess`'s queue.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    func first(where match: (String) -> Bool) async throws -> String {
        for _ in 0..<100 {
            if let line = lock.withLock({ lines.first(where: match) }) { return line }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw OperationError(errorDescription: "no matching line")
    }
}
