import SwiftUI

/// Common sheet chrome: a grouped form, an inline error, and Cancel / primary buttons.
/// The primary action throws; on error the sheet stays open and shows why.
struct SheetScaffold<Fields: View>: View {
    let title: String
    let actionTitle: String
    var destructive = false
    var canSubmit = true
    let action: () async throws -> Void
    @ViewBuilder let fields: () -> Fields

    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                fields()
                if let error {
                    Section {
                        Label {
                            Text(error).textSelection(.enabled)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, role: destructive ? .destructive : nil) {
                    Task { await submit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || isWorking)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
        .navigationTitle(title)
    }

    private func submit() async {
        isWorking = true
        error = nil
        do {
            try await action()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isWorking = false
    }
}

/// A picker over local branches, marking trunk and the main checkout's branch.
struct BranchPicker: View {
    let title: String
    let branches: [String]
    let snapshot: RepoSnapshot
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(branches, id: \.self) { name in
                Text(label(name)).tag(name)
            }
        }
    }

    private func label(_ name: String) -> String {
        var notes: [String] = []
        if name == snapshot.trunk { notes.append("trunk") }
        if name == snapshot.mainWorktree?.branch { notes.append("current") }
        return notes.isEmpty ? name : "\(name) (\(notes.joined(separator: ", ")))"
    }
}

/// `git status --porcelain` lines, capped so a huge change set doesn't swamp the sheet.
struct ChangeList: View {
    let lines: [String]
    var limit = 12

    var body: some View {
        ForEach(lines.prefix(limit), id: \.self) { line in
            Text(line).monospaced().font(.caption)
        }
        if lines.count > limit {
            Text("and \(lines.count - limit) more").foregroundStyle(.secondary)
        }
    }
}

extension RepoSnapshot {
    /// Trunk if it exists locally, else the main checkout's branch.
    var defaultBase: String {
        if let trunk, branches.contains(where: { $0.name == trunk }) { return trunk }
        return mainWorktree?.branch ?? branches.first?.name ?? ""
    }

    var branchesWithoutWorktree: [String] {
        branches.map(\.name).filter { worktree(checkingOut: $0) == nil }
    }
}

// MARK: - New worktree

struct NewWorktreeSheet: View {
    enum Mode: Hashable { case newBranch, existingBranch }

    let model: ProjectModel
    let snapshot: RepoSnapshot

    @State private var mode: Mode
    @State private var branchName = ""
    @State private var base: String
    @State private var existing: String
    @State private var folderName: String
    @State private var folderEdited = false

    init(model: ProjectModel, snapshot: RepoSnapshot, existingBranch: String?) {
        self.model = model
        self.snapshot = snapshot
        let existing = existingBranch ?? snapshot.branchesWithoutWorktree.first ?? ""
        _mode = State(initialValue: existingBranch == nil ? .newBranch : .existingBranch)
        _base = State(initialValue: snapshot.defaultBase)
        _existing = State(initialValue: existing)
        _folderName = State(initialValue: existingBranch.map(GitService.folderName(forBranch:)) ?? "")
    }

    private var branch: String { mode == .newBranch ? branchName : existing }

    var body: some View {
        SheetScaffold(
            title: "New Worktree",
            actionTitle: "Create",
            canSubmit: !branch.isEmpty && GitService.isValidFolderName(folderName)
        ) {
            let target: WorktreeBranch = mode == .newBranch
                ? .new(name: branchName, base: base.isEmpty ? nil : base)
                : .existing(existing)
            try await model.createWorktree(named: folderName, branch: target)
        } fields: {
            Section {
                Picker("Branch", selection: $mode) {
                    Text("New branch").tag(Mode.newBranch)
                    Text("Existing branch").tag(Mode.existingBranch)
                }
                .pickerStyle(.segmented)
                if mode == .newBranch {
                    TextField("Name", text: $branchName, prompt: Text("feat/login"))
                        .monospaced()
                    BranchPicker(title: "Based on", branches: snapshot.branches.map(\.name), snapshot: snapshot, selection: $base)
                } else if snapshot.branchesWithoutWorktree.isEmpty {
                    Text("Every branch is already checked out in a worktree.")
                        .foregroundStyle(.secondary)
                } else {
                    BranchPicker(title: "Branch", branches: snapshot.branchesWithoutWorktree, snapshot: snapshot, selection: $existing)
                }
            }
            Section {
                TextField("Folder name", text: Binding(
                    get: { folderName },
                    set: { folderName = $0; folderEdited = true }
                ))
                .monospaced()
                LabeledContent("Location") {
                    Text(relativeLocation)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } footer: {
                Text("Cheddar adds .cheddar/ to .git/info/exclude, so no tracked file changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: branch) { _, branch in
            if !folderEdited { folderName = GitService.folderName(forBranch: branch) }
        }
    }

    private var relativeLocation: String {
        guard GitService.isValidFolderName(folderName) else { return "\(GitService.cheddarRoot)/…" }
        let path = model.service.availableWorktreePath(named: folderName, in: model.project.url)
        return String(path.dropFirst(model.project.path.count + 1))
    }
}

// MARK: - New branch

struct NewBranchSheet: View {
    let model: ProjectModel
    let snapshot: RepoSnapshot

    @State private var name = ""
    @State private var base: String

    init(model: ProjectModel, snapshot: RepoSnapshot, base: String?) {
        self.model = model
        self.snapshot = snapshot
        _base = State(initialValue: base ?? snapshot.defaultBase)
    }

    var body: some View {
        SheetScaffold(title: "New Branch", actionTitle: "Create", canSubmit: !name.isEmpty) {
            try await model.createBranch(name, base: base.isEmpty ? nil : base)
        } fields: {
            Section {
                TextField("Name", text: $name, prompt: Text("fix/typo"))
                    .monospaced()
                BranchPicker(title: "Based on", branches: snapshot.branches.map(\.name), snapshot: snapshot, selection: $base)
            }
        }
    }
}

// MARK: - Rename

struct RenameSheet: View {
    let model: ProjectModel
    let request: RenameRequest

    @State private var newName: String
    @State private var moveFolder = true

    init(model: ProjectModel, request: RenameRequest) {
        self.model = model
        self.request = request
        switch request {
        case .branch(let name, _, _): _newName = State(initialValue: name)
        case .folder(let worktree): _newName = State(initialValue: worktree.displayName)
        }
    }

    var body: some View {
        switch request {
        case .branch(let name, let checkout, let askToMove):
            let movable = checkout.flatMap { $0.origin == .cheddar && !$0.isMissing ? $0 : nil }
            SheetScaffold(title: "Rename Branch", actionTitle: "Rename", canSubmit: !newName.isEmpty && newName != name) {
                let moving = movable != nil && (moveFolder || !askToMove) ? movable : nil
                try await model.renameBranch(name, to: newName, movingWorktree: moving)
            } fields: {
                Section {
                    LabeledContent("Branch") { Text(name).monospaced() }
                    TextField("New name", text: $newName).monospaced()
                    if movable != nil, askToMove {
                        Toggle("Also move the worktree folder", isOn: $moveFolder)
                    }
                } footer: {
                    footer(checkout: checkout, movable: movable, askToMove: askToMove)
                }
            }
        case .folder(let worktree):
            SheetScaffold(
                title: "Rename Folder",
                actionTitle: "Rename",
                canSubmit: GitService.isValidFolderName(newName) && newName != worktree.displayName
            ) {
                try await model.moveFolder(of: worktree, to: newName)
            } fields: {
                Section {
                    LabeledContent("Folder") { Text(worktree.displayName).monospaced() }
                    TextField("New name", text: $newName).monospaced()
                } footer: {
                    Text("Moves the worktree to \(GitService.cheddarRoot)/\(newName). Its detached HEAD is unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func footer(checkout: Worktree?, movable: Worktree?, askToMove: Bool) -> some View {
        Group {
            if movable != nil, moveFolder || !askToMove {
                Text("The worktree folder moves to \(GitService.cheddarRoot)/\(GitService.folderName(forBranch: newName)). If the move fails, the branch rename is undone.")
            } else if let checkout, checkout.origin != .main, checkout.origin != .cheddar {
                Text("Only the branch is renamed. \(checkout.origin.toolName) tracks the folder's path, so the folder stays where it is.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Delete worktree

struct DeleteWorktreeSheet: View {
    let model: ProjectModel
    let worktree: Worktree
    let changes: [String]

    @State private var force = false
    @State private var alsoDeleteBranch = false

    var body: some View {
        SheetScaffold(
            title: "Delete Worktree",
            actionTitle: "Delete",
            destructive: true,
            canSubmit: changes.isEmpty || force
        ) {
            try await model.deleteWorktree(worktree, force: force, alsoDeleteBranch: alsoDeleteBranch)
        } fields: {
            Section {
                LabeledContent("Worktree") { Text(worktree.displayName).monospaced() }
                LabeledContent("Folder") {
                    Text(worktree.path).monospaced().font(.caption).textSelection(.enabled)
                }
                if worktree.origin != .cheddar {
                    Label(
                        "\(worktree.origin.toolName) made this worktree. Deleting it may make \(worktree.origin.toolName) lose track of that chat or session.",
                        systemImage: "exclamationmark.triangle"
                    )
                }
                if worktree.isLocked {
                    Label(
                        "Locked\(worktree.lockedReason.map { ": \($0)" } ?? ""). git won't remove it until it's unlocked.",
                        systemImage: "lock"
                    )
                }
            }
            if !changes.isEmpty {
                Section("Uncommitted changes (\(changes.count))") {
                    ChangeList(lines: changes)
                    Toggle("Force: delete and discard these changes", isOn: $force)
                }
            }
            if let branch = worktree.branch {
                Section {
                    Toggle(isOn: $alsoDeleteBranch) {
                        Text("Also delete branch ") + Text(branch).monospaced()
                    }
                } footer: {
                    Text("If the branch isn't fully merged, you'll be asked again before it's deleted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Hand off

/// Preflight results and confirmation for handing a worktree's branch to the main checkout.
struct HandoffSheet: View {
    let model: ProjectModel
    let preflight: HandoffPreflight

    @State private var newBranch = ""
    @State private var stashMain = false

    private var worktree: Worktree { preflight.worktree }
    /// The branch the main checkout ends up on.
    private var branch: String { worktree.branch ?? newBranch }

    private var canSubmit: Bool {
        !worktree.isLocked
            && (preflight.mainChanges.isEmpty || stashMain)
            && (worktree.branch != nil || !newBranch.isEmpty)
    }

    var body: some View {
        SheetScaffold(title: "Hand Off", actionTitle: "Hand Off", canSubmit: canSubmit) {
            try await model.handOff(
                worktree,
                newBranch: worktree.branch == nil ? newBranch : nil,
                stashMainChanges: stashMain
            )
        } fields: {
            Section {
                LabeledContent("Worktree") { Text(worktree.displayName).monospaced() }
                if let current = worktree.branch {
                    LabeledContent("Branch") { Text(current).monospaced() }
                } else {
                    TextField("New branch", text: $newBranch, prompt: Text("feat/from-\(worktree.shortHead ?? "worktree")"))
                        .monospaced()
                }
                LabeledContent("Main checkout") {
                    Text(preflight.mainBranch.map { "\($0) → \(branch.isEmpty ? "…" : branch)" } ?? "detached → \(branch)")
                        .monospaced()
                }
            } footer: {
                footerText(
                    worktree.branch == nil
                        ? "This worktree has a detached HEAD at \(worktree.shortHead ?? "?"). The main checkout needs a named branch, so Cheddar creates one there first. Then it removes the worktree and switches the main checkout to it. The branch isn't merged, rebased or deleted."
                        : "Cheddar removes the worktree and switches the main checkout to \(branch). The branch isn't merged, rebased or deleted."
                )
            }

            if worktree.isLocked {
                Section {
                    Label(
                        "Locked\(worktree.lockedReason.map { ": \($0)" } ?? ""). Unlock it with git worktree unlock before handing it off.",
                        systemImage: "lock"
                    )
                }
            }

            if worktree.origin != .cheddar {
                Section {
                    Label(
                        "\(worktree.origin.toolName) made this worktree. Once its folder is removed, \(worktree.origin.toolName) may lose track of that chat or session.",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }

            if !preflight.mainChanges.isEmpty {
                Section {
                    ChangeList(lines: preflight.mainChanges)
                    Toggle("Stash the main checkout's changes first", isOn: $stashMain)
                } header: {
                    Text("Main checkout has uncommitted changes (\(preflight.mainChanges.count))")
                } footer: {
                    footerText("They're saved as stash “\(GitService.mainStashMessage(branch: branch.isEmpty ? "…" : branch))” and stay in the stash list until you pop them.")
                }
            }

            if !preflight.worktreeChanges.isEmpty {
                Section {
                    ChangeList(lines: preflight.worktreeChanges)
                } header: {
                    Text("Changes carried over (\(preflight.worktreeChanges.count))")
                } footer: {
                    footerText("Stashed in the worktree, then popped in the main checkout. If they don't apply cleanly, they stay in the stash list.")
                }
            }

            if !preflight.ignoredPaths.isEmpty {
                Section {
                    ChangeList(lines: preflight.ignoredPaths)
                } header: {
                    Label("Ignored files that will be lost", systemImage: "exclamationmark.triangle")
                } footer: {
                    footerText("Ignored files (dependencies, build output, .env and similar) aren't stashed, so they're deleted with the worktree folder.")
                }
            }
        }
    }

    private func footerText(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Adopt

/// Moves another tool's worktree into `.cheddar/worktrees`, making it Cheddar-owned.
struct AdoptSheet: View {
    let model: ProjectModel
    let worktree: Worktree

    @State private var name: String

    init(model: ProjectModel, worktree: Worktree) {
        self.model = model
        self.worktree = worktree
        let suggested = worktree.branch.map(GitService.folderName(forBranch:))
            ?? URL(fileURLWithPath: worktree.path).lastPathComponent
        _name = State(initialValue: suggested)
    }

    var body: some View {
        SheetScaffold(title: "Adopt Worktree", actionTitle: "Adopt", canSubmit: GitService.isValidFolderName(name)) {
            try await model.adopt(worktree, as: name)
        } fields: {
            Section {
                LabeledContent("Worktree") { Text(worktree.displayName).monospaced() }
                LabeledContent("From") {
                    Text(worktree.path).monospaced().font(.caption).textSelection(.enabled)
                }
                TextField("Folder name", text: $name).monospaced()
            } footer: {
                Text("Moves it to \(GitService.cheddarRoot)/\(name) with git worktree move. Cheddar can then rename and move it like its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Label(
                    "\(worktree.origin.toolName) tracks this worktree by its path. After the move, \(worktree.origin.toolName) will lose track of that chat or session.",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }
}
