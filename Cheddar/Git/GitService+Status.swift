import Foundation

extension GitParsers {
    /// Counts from `git status --porcelain=v2`. Untracked entries inside `nested` (repo-relative paths of
    /// linked worktrees under this one) aren't counted.
    static func worktreeStatus(_ output: String, excludingNested nested: [String] = []) -> WorktreeStatus {
        var status = WorktreeStatus()
        for line in output.split(separator: "\n") {
            switch line.first {
            case "1", "2":
                let xy = Array(line.dropFirst(2).prefix(2))
                guard xy.count == 2 else { continue }
                if xy[0] != "." { status.staged += 1 }
                if xy[1] != "." { status.unstaged += 1 }
            case "u":
                status.conflicts += 1
            case "?":
                var path = String(line.dropFirst(2))
                if path.hasSuffix("/") { path.removeLast() }
                if !nested.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { status.untracked += 1 }
            default:
                break
            }
        }
        return status
    }

    /// `name<US>ahead behind` lines from `for-each-ref --format=%(refname)%1f%(ahead-behind:<trunk>)`.
    static func aheadBehind(_ output: String) -> [String: (ahead: Int, behind: Int)] {
        var result: [String: (ahead: Int, behind: Int)] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\u{1f}")
            guard fields.count == 2 else { continue }
            let counts = fields[1].split(separator: " ").compactMap { Int($0) }
            guard counts.count == 2 else { continue }
            result[shortBranchName(String(fields[0]))] = (counts[0], counts[1])
        }
        return result
    }
}

extension GitService {
    /// How many worktrees' status is read at once.
    static let statusConcurrency = 4

    /// Fills in status at a glance: each worktree's changes (and HEAD summary when detached), and each
    /// branch's ahead/behind and merged state against trunk. One unreadable worktree doesn't fail the rest.
    func addStatus(to worktrees: inout [Worktree], branches: inout [Branch], trunk: String?, in repo: URL) async throws {
        let mainPath = worktrees.first { $0.origin == .main }?.path
        let linked = worktrees.filter { $0.origin != .main }.map(\.path)
        let targets = worktrees.filter { !$0.isMissing }
        let results = await targets.concurrentMap(limit: Self.statusConcurrency) { worktree in
            let nested = worktree.path == mainPath ? linked : []
            return (worktree.path, await self.statusSummary(of: worktree, nested: nested))
        }
        let byPath = Dictionary(results, uniquingKeysWith: { first, _ in first })
        for index in worktrees.indices {
            guard let summary = byPath[worktrees[index].path] else { continue }
            worktrees[index].status = summary.status
            worktrees[index].headSubject = summary.subject
            worktrees[index].headDate = summary.date
        }

        guard let trunk, branches.contains(where: { $0.name == trunk }) else { return }
        async let counts = trunkComparison(of: branches.map(\.name), against: trunk, in: repo)
        async let merged = mergedBranches(into: trunk, in: repo)
        let (comparison, mergedSet) = try await (counts, merged)
        for index in branches.indices where branches[index].name != trunk {
            let name = branches[index].name
            branches[index].trunkAhead = comparison[name]?.ahead
            branches[index].trunkBehind = comparison[name]?.behind
            branches[index].isMerged = mergedSet.contains(name)
        }
    }

    /// Re-reads one worktree's changes (for a file change inside it).
    func statusSummary(of worktree: Worktree, nested: [String]) async -> (status: WorktreeStatus?, subject: String?, date: Date?) {
        let url = URL(fileURLWithPath: worktree.path)
        let relativeNested = nested.compactMap { Paths.relative($0, under: worktree.path) }
        let status = (try? await git.output(["status", "--porcelain=v2", "-uall"], in: url))
            .map { GitParsers.worktreeStatus($0, excludingNested: relativeNested) }
        guard worktree.isDetached,
              let log = try? await git.output(["log", "-1", "--format=%s%x1f%ct", "HEAD"], in: url) else {
            return (status, nil, nil)
        }
        let fields = log.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false)
        return (status, fields.first.map(String.init), fields.count > 1 ? TimeInterval(fields[1]).map(Date.init(timeIntervalSince1970:)) : nil)
    }

    /// Ahead/behind trunk for each branch. Uses `%(ahead-behind:)` (git 2.41+) in one call, else falls
    /// back to `git rev-list --left-right --count` per branch.
    func trunkComparison(of branches: [String], against trunk: String, in repo: URL) async throws -> [String: (ahead: Int, behind: Int)] {
        let batch = try await git.run(["for-each-ref", "refs/heads", "--format=%(refname)%1f%(ahead-behind:\(trunk))"], in: repo)
        if batch.exitCode == 0 { return GitParsers.aheadBehind(batch.stdoutString) }
        return await revListComparison(of: branches, against: trunk, in: repo)
    }

    /// The pre-2.41 path: one `git rev-list --left-right --count trunk...branch` per branch.
    func revListComparison(of branches: [String], against trunk: String, in repo: URL) async -> [String: (ahead: Int, behind: Int)] {
        let pairs = await branches.filter { $0 != trunk }.concurrentMap(limit: Self.statusConcurrency) { branch in
            let output = try? await self.git.output(["rev-list", "--left-right", "--count", "\(trunk)...\(branch)"], in: repo)
            let counts = output?.split(whereSeparator: \.isWhitespace).compactMap { Int($0) } ?? []
            // Left side is trunk-only (behind), right side is branch-only (ahead).
            return (branch, counts.count == 2 ? (ahead: counts[1], behind: counts[0]) : nil)
        }
        return pairs.reduce(into: [:]) { result, pair in
            if let counts = pair.1 { result[pair.0] = counts }
        }
    }

    func mergedBranches(into trunk: String, in repo: URL) async throws -> Set<String> {
        let output = try await git.output(["branch", "--merged", trunk, "--format=%(refname)"], in: repo)
        return Set(output.split(separator: "\n").map { GitParsers.shortBranchName(String($0)) })
    }
}

extension Collection where Element: Sendable {
    /// Maps concurrently with at most `limit` tasks in flight, keeping the input order.
    func concurrentMap<T: Sendable>(limit: Int, _ transform: @escaping @Sendable (Element) async -> T) async -> [T] {
        await withTaskGroup(of: (Int, T).self) { group in
            var results = [T?](repeating: nil, count: count)
            var iterator = enumerated().makeIterator()
            for _ in 0..<limit {
                guard let (index, element) = iterator.next() else { break }
                group.addTask { (index, await transform(element)) }
            }
            for await (index, value) in group {
                results[index] = value
                if let (next, element) = iterator.next() {
                    group.addTask { (next, await transform(element)) }
                }
            }
            return results.compactMap { $0 }
        }
    }
}
