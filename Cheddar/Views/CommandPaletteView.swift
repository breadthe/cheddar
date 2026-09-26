import SwiftUI

/// ⌘K: find any project, worktree or branch across all projects. Return (or a double-click) switches to
/// that project and selects the row.
struct CommandPaletteView: View {
    /// A project's worktrees and branches, read when the palette opens.
    let loadContents: @Sendable (Project) async -> PaletteContents

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var contents: [Project.ID: PaletteContents] = [:]
    @State private var highlighted = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        let items = PaletteMatcher.filter(
            PaletteMatcher.items(projects: appState.projects, contents: contents, selected: appState.selection),
            query: query)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("", text: $query, prompt: Text("Go to a project, worktree or branch"))
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                    .onKeyPress(.upArrow) { move(-1, count: items.count) }
                    .onKeyPress(.downArrow) { move(1, count: items.count) }
                    .onSubmit { go(to: items) }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, isHighlighted: index == highlighted)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { reveal(item) }
                                .onTapGesture { highlighted = index }
                        }
                        if items.isEmpty {
                            Text("No matches").foregroundStyle(.secondary).padding(20)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: highlighted) { _, index in
                    if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
                }
            }
            Divider()
            HStack(spacing: 16) {
                Text("↩ Show in Cheddar")
                Text("esc Close")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 580, height: 420)
        .onAppear { isFocused = true }
        .onExitCommand { dismiss() }
        .onChange(of: query) { highlighted = 0 }
        .task { await loadAllContents() }
    }

    private func row(_ item: PaletteItem, isHighlighted: Bool) -> some View {
        let (title, subtitle, symbol, badge): (String, String, String, String) = switch item {
        case .worktree(let worktree, let project):
            (worktree.displayName,
             ([project.name, worktree.branch ?? worktree.shortHead.map { "detached \($0)" }].compactMap { $0 }
                + (worktree.isMissing ? ["missing"] : [])).joined(separator: " · "),
             worktree.isMissing ? "exclamationmark.triangle" : "folder",
             worktree.origin.label)
        case .branch(let branch, let project):
            (branch.name,
             ([project.name] + [checkout(of: branch, in: project).map { "checked out in \($0)" } ?? branch.upstream]
                .compactMap { $0 }).joined(separator: " · "),
             "arrow.triangle.branch",
             "branch")
        case .project(let project):
            (project.name, (project.path as NSString).abbreviatingWithTildeInPath, "rectangle.stack", "project")
        }
        return HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(isHighlighted ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isHighlighted ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(badge).font(.caption).foregroundStyle(isHighlighted ? .white.opacity(0.8) : .secondary)
        }
        .foregroundStyle(isHighlighted ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isHighlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func checkout(of branch: Branch, in project: Project) -> String? {
        contents[project.id]?.worktrees.first { $0.branch == branch.name }?.displayName
    }

    private func move(_ delta: Int, count: Int) -> KeyPress.Result {
        if count > 0 { highlighted = min(max(highlighted + delta, 0), count - 1) }
        return .handled
    }

    private func go(to items: [PaletteItem]) {
        if items.indices.contains(highlighted) { reveal(items[highlighted]) }
    }

    /// Switches to the project; its view then selects the row and scrolls to it.
    private func reveal(_ item: PaletteItem) {
        appState.selection = item.project.id
        appState.reveal = RevealRequest(projectID: item.project.id, rowTag: item.rowTag)
        dismiss()
    }

    private func loadAllContents() async {
        await withTaskGroup(of: (Project.ID, PaletteContents).self) { group in
            for project in appState.projects {
                group.addTask { await (project.id, loadContents(project)) }
            }
            for await (id, loaded) in group {
                contents[id] = loaded
            }
        }
    }
}
