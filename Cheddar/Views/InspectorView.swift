import SwiftUI

/// The right-side inspector: the selected worktree's changes and commits, or the selected branch's
/// commits, with the diff of the file or commit picked in the list.
struct InspectorView: View {
    let target: InspectorModel.Target?
    let trunk: String?
    let repo: String
    @State private var inspector: InspectorModel

    init(target: InspectorModel.Target?, trunk: String?, repo: String, service: GitService) {
        self.target = target
        self.trunk = trunk
        self.repo = repo
        _inspector = State(initialValue: InspectorModel(service: service))
    }

    var body: some View {
        if let target {
            VSplitView {
                lists
                    .frame(minHeight: 120, idealHeight: 260)
                DiffView(lines: inspector.diff, isTruncated: inspector.isDiffTruncated)
                    .frame(minHeight: 120)
            }
            .task(id: target) { await inspector.load(target, trunk: trunk, repo: repo) }
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: "sidebar.right",
                                   description: Text("Select a worktree to see its changes and commits, or a branch to see its commits."))
        }
    }

    private var lists: some View {
        List(selection: Binding(get: { inspector.selected }, set: { item in Task { await inspector.select(item) } })) {
            if let error = inspector.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if let files = inspector.files {
                Section("Changes (\(files.count))") {
                    if files.isEmpty {
                        Text("No uncommitted changes").foregroundStyle(.secondary)
                    }
                    ForEach(files) { file in
                        HStack(spacing: 6) {
                            Text(file.status.replacingOccurrences(of: " ", with: "·"))
                                .monospaced()
                                .foregroundStyle(statusColor(file))
                                .help(statusHelp(file))
                            Text(file.path).monospaced().lineLimit(1).truncationMode(.head)
                        }
                        .tag(InspectorModel.Item.file(file))
                    }
                }
            }
            Section(inspector.commitsTitle) {
                if inspector.commits.isEmpty {
                    Text("No commits").foregroundStyle(.secondary)
                }
                ForEach(inspector.commits) { commit in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(commit.shortSHA).monospaced().foregroundStyle(GitColors.sha)
                            Text(commit.subject).lineLimit(1)
                        }
                        Text("\(commit.author) · \(commit.date.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(InspectorModel.Item.commit(commit))
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Git's status colors: staged green, unstaged and untracked red.
    private func statusColor(_ file: ChangedFile) -> Color {
        if file.status.contains("U") { return GitColors.conflict }
        if file.isUntracked { return GitColors.untracked }
        return file.status.first != " " ? GitColors.staged : GitColors.unstaged
    }

    private func statusHelp(_ file: ChangedFile) -> String {
        if file.isUntracked { return "Untracked" }
        let staged = file.status.first.map { $0 != " " } ?? false
        let unstaged = file.status.last.map { $0 != " " } ?? false
        let renamed = file.originalPath.map { " (from \($0))" } ?? ""
        return [staged ? "staged" : nil, unstaged ? "not staged" : nil].compactMap { $0 }.joined(separator: ", ").capitalized + renamed
    }
}

/// A diff or `git show`, one line per row in git's diff colors (never color alone: the +/- stay).
struct DiffView: View {
    let lines: [DiffLine]
    let isTruncated: Bool

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .foregroundStyle(GitColors.diff(line.kind))
                        .fontWeight(line.kind == .meta || line.kind == .commit ? .semibold : .regular)
                        .fixedSize()
                }
                if isTruncated {
                    Text("… (only the first \(DiffLine.limit) lines are shown)")
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
