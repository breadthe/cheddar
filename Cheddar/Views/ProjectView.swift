import SwiftUI

struct ProjectView: View {
    /// Swapped by RootView when the project changes. This view (and its toolbar) is kept, not rebuilt:
    /// rebuilding it on every switch made NSToolbar crash inserting an item it still had.
    let model: ProjectModel
    @Environment(DependencyStore.self) private var dependencies
    @Environment(AppState.self) private var appState
    @AppStorage("showCommandLog") private var showLog = false
    @AppStorage(PreferenceKey.editorApp) private var editorID = OpenIn.defaultEditorID
    @AppStorage(PreferenceKey.terminalApp) private var terminalID = OpenIn.terminal.bundleID
    /// `w:<path>`, `o:<path>` (orphan), `b:<branch>`, `rt:<branch>:<remote ref>` (the remote branch a local
    /// branch tracks, shown under it), `r:<remote ref>` (in Remote Branches) or `g:<tag>`. `:` can't occur
    /// in ref names.
    @State private var selection: String?
    /// Hovering a branch highlights its worktree and vice versa.
    @State private var hoveredBranch: String?
    @State private var hoveredRow: String?
    /// nil shows every origin.
    @State private var originFilter: WorktreeOrigin?
    @State private var searchText = ""
    /// A missing app or tool picked from an Open menu; shown as a popover on that row.
    @State private var installHelp: InstallHelpRequest?
    @AppStorage("showTags") private var showTags = true


    private var editor: ExternalApp { OpenIn.editor(for: editorID) }

    var body: some View {
        @Bindable var model = model
        content
            .navigationTitle(model.project.name)
            .navigationSubtitle((model.project.path as NSString).abbreviatingWithTildeInPath)
            .toolbar { toolbar }
            .searchable(text: $searchText, placement: .toolbar, prompt: "Filter worktrees and branches")
            .task(id: ObjectIdentifier(model)) {
                resetViewState()
                await model.load()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.load() }
            }
            .sheet(item: $model.sheet) { sheet in
                if let snapshot = model.snapshot { sheetContent(sheet, snapshot: snapshot) }
            }
            .alert(item: $model.alert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message))
            }
            .modifier(Confirmations(model: model))
            .onChange(of: model.toolMissing) { _, missing in
                if missing { Task { await dependencies.check() } }
            }
            .focusedSceneValue(\.projectCommands, commands)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let snapshot = model.snapshot {
            List(selection: $selection) {
                if !model.excludeOffers.isEmpty {
                    Section {
                        ForEach(model.excludeOffers, id: \.self) { pattern in
                            ExcludeOfferRow(pattern: pattern) {
                                Task { await model.exclude(pattern) }
                            } dismiss: {
                                model.dismissedExcludes.insert(pattern)
                            }
                            .disabled(model.isBusy)
                        }
                    }
                }
                Section("Worktrees") {
                    ForEach(snapshot.worktrees.filter { matches($0.origin) && matches($0.displayName, $0.branch) }) { worktree in
                        worktreeRow(worktree, snapshot: snapshot)
                    }
                    ForEach(snapshot.orphans.filter { matches($0.origin) && matches($0.displayName) }) { orphan in
                        orphanRow(orphan)
                    }
                }
                Section {
                    ForEach(snapshot.branches.filter { matches($0.name, $0.upstream) }) { branch in
                        let remote = snapshot.trackedRemote(of: branch)
                        branchRow(branch, trackedRemote: remote, snapshot: snapshot)
                        if let remote {
                            trackedRemoteRow(remote, of: branch)
                        }
                    }
                } header: {
                    HStack {
                        Text("Branches")
                        Spacer()
                        bulkDeleteControls
                        Button {
                            model.sheet = .newBranch(base: nil)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isBusy)
                        .help("New Branch")
                        .accessibilityLabel("New Branch")
                    }
                }
                if !snapshot.remotes.isEmpty {
                    remoteBranchesSection(snapshot)
                }
                tagsSection(snapshot)
            }
            .contextMenu(forSelectionType: String.self) { tags in
                if tags.count == 1, let tag = tags.first { actions(for: tag, snapshot: snapshot) }
            } primaryAction: { tags in
                // Double-click or Return opens a worktree in the preferred editor.
                guard tags.count == 1, let worktree = worktree(for: tags.first!), !worktree.isMissing else { return }
                open(worktree, in: editor, tag: tags.first!)
            }
        } else if let error = model.loadError {
            ContentUnavailableView {
                Label("Couldn't Read Repository", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).monospaced()
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func worktreeRow(_ worktree: Worktree, snapshot: RepoSnapshot) -> some View {
        let tag = "w:\(worktree.path)"
        let branch = worktree.branch.flatMap { name in snapshot.branches.first { $0.name == name } }
        return HStack {
            WorktreeRow(worktree: worktree, branch: branch, trunk: snapshot.trunk)
            if worktree.isMissing {
                hoverButton("Prune", tag: tag, help: "Remove git's entry for this missing worktree") {
                    Task { await model.prune(worktree) }
                }
            } else {
                Menu {
                    openItems(worktree, tag: tag)
                } label: {
                    Text("Open")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .opacity(hoveredRow == tag ? 1 : 0)
                .help("Open in Finder, Terminal, an editor or Claude Code")
                if worktree.origin != .main {
                    hoverButton("Hand Off", tag: tag, help: "Continue on this branch in the main checkout") {
                        Task { await model.requestHandoff(worktree) }
                    }
                }
            }
            rowMenu(tag) { worktreeActions(worktree, tag: tag) }
        }
        .tag(tag)
        .onHover { hover(tag, branch: worktree.branch, $0) }
        .listRowBackground(highlight(worktree.branch))
        .popover(isPresented: installHelpBinding(for: tag), arrowEdge: .trailing) { installHelpPopover }
    }

    private func orphanRow(_ orphan: OrphanFolder) -> some View {
        let tag = "o:\(orphan.path)"
        return HStack {
            OrphanRow(orphan: orphan)
            if orphan.isRepairable {
                hoverButton("Repair", tag: tag, help: "git worktree repair") {
                    Task { await model.repair(orphan) }
                }
            }
            rowMenu(tag) { orphanActions(orphan) }
        }
        .tag(tag)
        .onHover { hover(tag, branch: nil, $0) }
    }

    private func branchRow(_ branch: Branch, trackedRemote: RemoteBranch?, snapshot: RepoSnapshot) -> some View {
        let tag = "b:\(branch.name)"
        let checkout = snapshot.worktree(checkingOut: branch.name)
        return HStack {
            Toggle("Select \(branch.name)", isOn: checkedBinding(for: branch.name, deletable: checkout == nil))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(checkout != nil || model.isBusy)
                .help(checkout.map { "Checked out in \($0.displayName)" } ?? "Select for Delete Selected…")
            BranchRow(branch: branch, checkedOutIn: checkout, trunk: snapshot.trunk, trackedRemote: trackedRemote)
            if checkout == nil {
                hoverButton("+ Worktree", tag: tag, help: "New worktree on this branch") {
                    model.sheet = .newWorktree(existingBranch: branch.name)
                }
            }
            rowMenu(tag) { branchActions(branch, checkout: checkout) }
        }
        .tag(tag)
        .onHover { hover(tag, branch: branch.name, $0) }
        .listRowBackground(highlight(branch.name))
    }

    /// A branch checked out in a worktree can't be deleted, so it never shows as checked.
    private func checkedBinding(for name: String, deletable: Bool) -> Binding<Bool> {
        Binding(
            get: { deletable && model.checkedBranches.contains(name) },
            set: { checked in
                if checked { model.checkedBranches.insert(name) } else { model.checkedBranches.remove(name) }
            }
        )
    }

    /// "3 selected · Clear · Delete Selected…" in the Branches header, while any branch is checked.
    @ViewBuilder
    private var bulkDeleteControls: some View {
        let branches = model.branchesToDelete
        if !branches.isEmpty {
            Text("\(branches.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Clear") { model.checkedBranches = [] }
                .buttonStyle(.borderless)
                .help("Uncheck every branch")
            Button("Delete Selected…", role: .destructive) { model.sheet = .deleteBranches(branches) }
                .buttonStyle(.borderless)
                .disabled(model.isBusy)
                .help("Delete the checked branches with git branch -d")
        }
    }

    /// The remote branch `branch` tracks, as its own row under it. Hovering either highlights both.
    private func trackedRemoteRow(_ remote: RemoteBranch, of branch: Branch) -> some View {
        let tag = "rt:\(branch.name):\(remote.ref)"
        return HStack {
            // Keeps it indented under its branch row, which starts with a checkbox.
            Toggle("", isOn: .constant(false))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .hidden()
                .accessibilityHidden(true)
            RemoteBranchRow(remote: remote, trackingBranch: branch)
            rowMenu(tag) { remoteActions(remote, tracked: true) }
        }
            .tag(tag)
            .onHover { hover(tag, branch: branch.name, $0) }
            .listRowBackground(highlight(branch.name))
    }

    /// Remote branches no local branch tracks, so each remote branch shows up exactly once.
    private func remoteBranchesSection(_ snapshot: RepoSnapshot) -> some View {
        let untracked = snapshot.untrackedRemoteBranches
        return Section {
            ForEach(untracked.filter { matches($0.shortName) }) { remote in
                let tag = "r:\(remote.ref)"
                HStack {
                    RemoteBranchRow(remote: remote)
                    hoverButton("+ Branch", tag: tag, help: "New local branch tracking \(remote.shortName)") {
                        model.sheet = .trackRemote(remote)
                    }
                    rowMenu(tag) { remoteActions(remote, tracked: false) }
                }
                    .tag(tag)
                    .onHover { hover(tag, branch: nil, $0) }
            }
            if untracked.isEmpty {
                Text("Every remote branch is tracked by a local branch.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Remote Branches")
                Spacer()
                Text(fetchedDescription(snapshot.lastFetch))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await model.fetch() }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .disabled(model.isBusy)
                .help("Fetch All Remotes")
                .accessibilityLabel("Fetch All Remotes")
            }
        }
    }

    /// Collapsible, since repos can have hundreds of tags; a search shows matches either way.
    private func tagsSection(_ snapshot: RepoSnapshot) -> some View {
        let entries = model.tagEntries
        return Section {
            if showTags || !searchText.isEmpty {
                ForEach(entries.filter { matches($0.name) }) { entry in
                    tagRow(entry, remotes: snapshot.remotes)
                }
                if entries.isEmpty {
                    Text("No tags.")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Button {
                    showTags.toggle()
                } label: {
                    Label("Tags", systemImage: showTags ? "chevron.down" : "chevron.right")
                        .labelStyle(TrailingChevronLabelStyle())
                }
                .buttonStyle(.plain)
                .help(showTags ? "Hide tags" : "Show tags")
                .accessibilityLabel(showTags ? "Hide Tags" : "Show Tags")
                Spacer()
                if !snapshot.remotes.isEmpty {
                    Text(model.remoteTags == nil
                         ? "fetch to compare with \(snapshot.remotes.joined(separator: ", "))"
                         : "compared with \(snapshot.remotes.joined(separator: ", ")) at the last fetch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tagRow(_ entry: TagEntry, remotes: [String]) -> some View {
        let tag = "g:\(entry.name)"
        return HStack {
            TagRow(entry: entry)
            if let local = entry.local, let status = entry.status, status.on.isEmpty, status.differsOn.isEmpty,
               status.missingFrom.count == 1, let remote = status.missingFrom.first {
                hoverButton("Push", tag: tag, help: "Push \(entry.name) to \(remote)") {
                    Task { await model.pushTag(local, to: remote) }
                }
            } else if entry.local == nil, let remote = entry.status?.on.first {
                hoverButton("Fetch", tag: tag, help: "Fetch \(entry.name) from \(remote)") {
                    Task { await model.fetchTag(entry.name, from: remote) }
                }
            }
            rowMenu(tag) { tagActions(entry, remotes: remotes) }
        }
        .tag(tag)
        .onHover { hover(tag, branch: nil, $0) }
    }

    @ViewBuilder
    private func tagActions(_ entry: TagEntry, remotes: [String]) -> some View {
        let status = entry.status
        Group {
            if let local = entry.local {
                ForEach(status?.missingFrom ?? [], id: \.self) { remote in
                    Button("Push to \(remote)") { Task { await model.pushTag(local, to: remote) } }
                }
                Button("Rename…") {
                    model.sheet = .renameTag(local, onRemotes: status.map { $0.on + $0.differsOn })
                }
                Divider()
                Button("Delete…", role: .destructive) { model.tagToDelete = local }
            } else {
                ForEach(status?.on ?? [], id: \.self) { remote in
                    Button("Fetch from \(remote)") { Task { await model.fetchTag(entry.name, from: remote) } }
                }
                Divider()
            }
            ForEach((status?.on ?? []) + (status?.differsOn ?? []), id: \.self) { remote in
                if let sha = status?.remoteObjects[remote] {
                    Button("Delete on \(remote)…", role: .destructive) {
                        model.remoteTagToDelete = RemoteTagRef(name: entry.name, remote: remote, sha: sha)
                    }
                }
            }
        }
        .disabled(model.isBusy)
    }

    private func fetchedDescription(_ date: Date?) -> String {
        date.map { "fetched \($0.formatted(.relative(presentation: .named)))" } ?? "never fetched"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Always present, only hidden: toolbar items that come and go can crash NSToolbar
        // ("duplicate item"). Its own item, so it can drop the glass background macOS 26 gives items;
        // otherwise an empty capsule shows while idle.
        if #available(macOS 26, *) {
            ToolbarItem { loadingIndicator }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem { loadingIndicator }
        }
        ToolbarItemGroup {
            trunkMenu
            Picker("Origin", selection: $originFilter) {
                Text("All").tag(WorktreeOrigin?.none)
                Divider()
                ForEach(filterOrigins, id: \.self) { origin in
                    Text(origin.label).tag(WorktreeOrigin?.some(origin))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Show worktrees from one origin")
            Button {
                model.sheet = .newWorktree(existingBranch: nil)
            } label: {
                Label("New Worktree", systemImage: "plus")
            }
            .help("New Worktree (⌘N)")
            .disabled(model.snapshot == nil || model.isBusy)
            Button {
                Task { await model.fetch() }
            } label: {
                Label("Fetch", systemImage: "arrow.down.circle")
            }
            .help("Fetch all remotes (\(fetchedDescription(model.snapshot?.lastFetch)))")
            .disabled(model.snapshot?.remotes.isEmpty != false || model.isBusy)
            Button {
                Task { await model.load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh (⌘R)")
            .disabled(model.isBusy || model.isLoading)
            Toggle(isOn: $showLog) {
                Label("Command Log", systemImage: "terminal")
            }
            .help("Command Log (⇧⌘L)")
        }
    }

    private var loadingIndicator: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(model.isBusy || model.isLoading ? 1 : 0)
            .accessibilityHidden(!(model.isBusy || model.isLoading))
    }

    /// "trunk: main ▾": Automatic, or a per-project override.
    private var trunkMenu: some View {
        Menu {
            Picker("Trunk", selection: Binding(
                get: { model.project.trunk },
                set: { trunk in setTrunk(trunk) }
            )) {
                Text("Automatic (origin/HEAD, main, master)").tag(String?.none)
                Divider()
                ForEach(model.snapshot?.branches ?? []) { branch in
                    Text(branch.name).tag(String?.some(branch.name))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text("trunk: \(model.snapshot?.trunk ?? "none")")
                .monospaced()
        }
        .fixedSize()
        .help("The branch used for ahead/behind and “merged”")
    }

    private func setTrunk(_ trunk: String?) {
        do {
            try appState.setTrunk(trunk, for: model.project)
        } catch {
            model.report(error, title: "Couldn't save the trunk branch")
        }
    }

    /// Built-in origins plus any custom discovery labels present.
    private var filterOrigins: [WorktreeOrigin] {
        let present = (model.snapshot?.worktrees.map(\.origin) ?? []) + (model.snapshot?.orphans.map(\.origin) ?? [])
        var customs: [WorktreeOrigin] = []
        for origin in present where origin.sortRank == WorktreeOrigin.custom("").sortRank && !customs.contains(origin) {
            customs.append(origin)
        }
        return WorktreeOrigin.builtIn.filter { $0 != .external } + customs + [.external]
    }

    // MARK: Row actions (context menu and hover menus)

    @ViewBuilder
    private func actions(for tag: String, snapshot: RepoSnapshot) -> some View {
        if let worktree = worktree(for: tag) {
            worktreeActions(worktree, tag: tag)
        } else if tag.hasPrefix("o:"), let orphan = snapshot.orphans.first(where: { "o:\($0.path)" == tag }) {
            orphanActions(orphan)
        } else if tag.hasPrefix("b:"), let branch = snapshot.branches.first(where: { "b:\($0.name)" == tag }) {
            branchActions(branch, checkout: snapshot.worktree(checkingOut: branch.name))
        } else if let remote = remoteBranch(for: tag) {
            remoteActions(remote, tracked: tag.hasPrefix("rt:"))
        } else if tag.hasPrefix("g:"), let entry = model.tagEntries.first(where: { "g:\($0.name)" == tag }) {
            tagActions(entry, remotes: snapshot.remotes)
        }
    }

    /// `tracked`: shown under the local branch that tracks it, rather than in Remote Branches.
    @ViewBuilder
    private func remoteActions(_ remote: RemoteBranch, tracked: Bool) -> some View {
        Group {
            if !tracked {
                Button("New Tracking Branch…") { model.sheet = .trackRemote(remote) }
                Divider()
            }
            Button("Delete on \(remote.remote)…", role: .destructive) { model.remoteBranchToDelete = remote }
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder
    private func worktreeActions(_ worktree: Worktree, tag: String) -> some View {
        if !worktree.isMissing {
            Menu("Open In") { openItems(worktree, tag: tag) }
            Divider()
        }
        Group {
            if worktree.isMissing {
                Button("Prune") { Task { await model.prune(worktree) } }
            } else if let branch = worktree.branch {
                // Renaming a Cheddar worktree renames its branch and moves its folder; others rename the branch only.
                Button(worktree.origin == .cheddar ? "Rename…" : "Rename Branch…") {
                    model.sheet = .rename(.branch(branch, checkedOutIn: worktree, askToMove: false))
                }
            } else if worktree.origin == .cheddar {
                Button("Rename Folder…") { model.sheet = .rename(.folder(worktree)) }
            }
            if worktree.origin != .main && !worktree.isMissing {
                Button("Hand Off…") { Task { await model.requestHandoff(worktree) } }
                if worktree.origin.isForeign {
                    Button("Adopt into Cheddar…") { model.sheet = .adopt(worktree) }
                }
                Divider()
                Button("Delete…", role: .destructive) {
                    Task { await model.requestDelete(worktree) }
                }
            }
        }
        .disabled(model.isBusy)
    }

    /// Finder, the preferred terminal, every listed editor, and Claude Code. Missing apps stay listed as
    /// "Not Installed" and open install help.
    @ViewBuilder
    private func openItems(_ worktree: Worktree, tag: String) -> some View {
        let terminal = OpenIn.terminal(for: terminalID)
        Button("Finder") { OpenIn.revealInFinder(worktree.path) }
        Button(terminal.name) { open(worktree, in: terminal, tag: tag) }
        Divider()
        ForEach(OpenIn.listedEditors) { app in
            Button(app.isInstalled ? app.name : "\(app.name) (Not Installed)") { open(worktree, in: app, tag: tag) }
        }
        Divider()
        let claudeInstalled = dependencies.statuses[Dependencies.claude.id]?.isAvailable ?? false
        Button(claudeInstalled ? "Claude Code Here" : "Claude Code Here (Not Installed)") {
            if claudeInstalled {
                Task { await model.openClaudeCode(in: worktree.path) }
            } else {
                installHelp = InstallHelpRequest(dependency: Dependencies.claude, tag: tag)
            }
        }
    }

    private func open(_ worktree: Worktree, in app: ExternalApp, tag: String) {
        if !app.isInstalled, let dependency = app.dependency {
            installHelp = InstallHelpRequest(dependency: dependency, tag: tag)
        } else {
            Task { await model.open(worktree.path, in: app) }
        }
    }

    @ViewBuilder
    private func orphanActions(_ orphan: OrphanFolder) -> some View {
        Group {
            Button("Reveal in Finder") { OpenIn.revealInFinder(orphan.path) }
            Divider()
            if orphan.isRepairable {
                Button("Repair") { Task { await model.repair(orphan) } }
                Divider()
            }
            Button("Move to Trash…", role: .destructive) { model.orphanToTrash = orphan }
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder
    private func branchActions(_ branch: Branch, checkout: Worktree?) -> some View {
        Group {
            if checkout == nil {
                Button("New Worktree…") { model.sheet = .newWorktree(existingBranch: branch.name) }
            }
            Button("New Branch from Here…") { model.sheet = .newBranch(base: branch.name) }
            Button("Rename…") {
                model.sheet = .rename(.branch(branch.name, checkedOutIn: checkout, askToMove: true))
            }
            Divider()
            Button("Delete…", role: .destructive) { model.branchToDelete = branch }
                .disabled(checkout != nil)
                .help(checkout.map { "Checked out in \($0.displayName)" } ?? "")
        }
        .disabled(model.isBusy)
    }

    /// A borderless button revealed when hovering its row.
    private func hoverButton(_ title: String, tag: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
            .disabled(model.isBusy)
            .opacity(hoveredRow == tag ? 1 : 0)
            .help(help)
    }

    private func rowMenu(_ tag: String, @ViewBuilder content: () -> some View) -> some View {
        Menu(content: content) {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(hoveredRow == tag ? 1 : 0)
        .accessibilityLabel("Actions")
    }

    // MARK: Install help popover

    private func installHelpBinding(for tag: String) -> Binding<Bool> {
        Binding(get: { installHelp?.tag == tag }, set: { if !$0 { installHelp = nil } })
    }

    @ViewBuilder
    private var installHelpPopover: some View {
        if let request = installHelp {
            VStack(alignment: .leading, spacing: 16) {
                DependencyHelp(
                    dependency: request.dependency,
                    status: dependencies.statuses[request.dependency.id] ?? .missing,
                    hasHomebrew: dependencies.hasHomebrew
                )
                HStack {
                    Button("Check Again") { Task { await dependencies.check() } }
                        .disabled(dependencies.isChecking)
                    if dependencies.isChecking { ProgressView().controlSize(.small) }
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ProjectSheet, snapshot: RepoSnapshot) -> some View {
        switch sheet {
        case .newWorktree(let existingBranch):
            NewWorktreeSheet(model: model, snapshot: snapshot, existingBranch: existingBranch)
        case .newBranch(let base):
            NewBranchSheet(model: model, snapshot: snapshot, base: base)
        case .deleteBranches(let branches):
            DeleteBranchesSheet(model: model, branches: branches, trunk: snapshot.trunk)
        case .rename(let request):
            RenameSheet(model: model, request: request)
        case .deleteWorktree(let worktree, let changes):
            DeleteWorktreeSheet(model: model, worktree: worktree, changes: changes)
        case .handoff(let preflight):
            HandoffSheet(model: model, preflight: preflight)
        case .adopt(let worktree):
            AdoptSheet(model: model, worktree: worktree)
        case .trackRemote(let remote):
            TrackingBranchSheet(model: model, remote: remote)
        case .renameTag(let tag, let onRemotes):
            RenameTagSheet(model: model, tag: tag, onRemotes: onRemotes, hasRemotes: !snapshot.remotes.isEmpty)
        }
    }

    // MARK: Commands (Worktree and View menus)

    private var commands: ProjectCommands {
        ProjectCommands(
            isEnabled: model.snapshot != nil && !model.isBusy,
            refresh: { Task { await model.load() } },
            fetch: model.snapshot?.remotes.isEmpty == false ? { Task { await model.fetch() } } : nil,
            newWorktree: { model.sheet = .newWorktree(existingBranch: nil) },
            editorName: editor.name,
            openInEditor: selectedWorktree.map { worktree in { open(worktree, in: editor, tag: "w:\(worktree.path)") } },
            handOffSelection: selectedLinkedWorktree.map { worktree in { Task { await model.requestHandoff(worktree) } } },
            // Off while a sheet is up, so ⌘⌫ in a text field can't reach the menu.
            deleteSelection: model.sheet == nil ? deleteSelectionAction : nil
        )
    }

    /// For `rt:<branch>:<ref>` and `r:<ref>` tags; `:` can't occur in ref names, so the ref is the tail.
    private func remoteBranch(for tag: String) -> RemoteBranch? {
        guard tag.hasPrefix("r:") || tag.hasPrefix("rt:") else { return nil }
        return model.snapshot?.remoteBranches.first { tag.hasSuffix(":\($0.ref)") }
    }

    private func worktree(for tag: String) -> Worktree? {
        guard tag.hasPrefix("w:") else { return nil }
        return model.snapshot?.worktrees.first { "w:\($0.path)" == tag }
    }

    /// The selected worktree, if its folder is present.
    private var selectedWorktree: Worktree? {
        selection.flatMap(worktree(for:)).flatMap { $0.isMissing ? nil : $0 }
    }

    /// The selected worktree, if it can be handed off or deleted (not main, folder present).
    private var selectedLinkedWorktree: Worktree? {
        selectedWorktree.flatMap { $0.origin == .main ? nil : $0 }
    }

    private var deleteSelectionAction: (() -> Void)? {
        if let worktree = selectedLinkedWorktree {
            return { Task { await model.requestDelete(worktree) } }
        }
        if let remote = selection.flatMap(remoteBranch(for:)) {
            return { model.remoteBranchToDelete = remote }
        }
        if let selection, selection.hasPrefix("g:"),
           let tag = model.snapshot?.tags.first(where: { "g:\($0.name)" == selection }) {
            return { model.tagToDelete = tag }
        }
        guard let selection, selection.hasPrefix("b:"), let snapshot = model.snapshot,
              let branch = snapshot.branches.first(where: { "b:\($0.name)" == selection }),
              snapshot.worktree(checkingOut: branch.name) == nil else { return nil }
        return { model.branchToDelete = branch }
    }

    // MARK: Filtering

    private func matches(_ origin: WorktreeOrigin) -> Bool {
        originFilter == nil || origin == originFilter
    }

    private func matches(_ names: String?...) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return names.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }

    /// Per-project view state that shouldn't carry over to another project.
    private func resetViewState() {
        selection = nil
        hoveredRow = nil
        hoveredBranch = nil
        installHelp = nil
        originFilter = nil
        searchText = ""
    }

    // MARK: Hover

    private func hover(_ tag: String, branch: String?, _ hovering: Bool) {
        if hovering {
            hoveredRow = tag
            hoveredBranch = branch
        } else if hoveredRow == tag {
            hoveredRow = nil
            hoveredBranch = nil
        }
    }

    private func highlight(_ branch: String?) -> Color? {
        branch != nil && branch == hoveredBranch ? Color.accentColor.opacity(0.12) : nil
    }

}

/// Install help for a missing app or tool, shown as a popover on the row it was picked from.
struct InstallHelpRequest: Equatable {
    let dependency: Dependency
    let tag: String

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.dependency.id == rhs.dependency.id && lhs.tag == rhs.tag }
}

/// ProjectView's delete and trash confirmations. Kept out of its `body`, whose modifier chain got too long
/// to type-check.
private struct Confirmations: ViewModifier {
    @Bindable var model: ProjectModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Delete branch \(model.branchToDelete?.name ?? "")?",
                isPresented: isPresented($model.branchToDelete),
                presenting: model.branchToDelete
            ) { branch in
                Button("Delete", role: .destructive) {
                    Task { await model.deleteBranch(branch.name, force: false) }
                }
            }
            .unmergedBranchConfirmation($model.unmergedBranch) { branch in
                await model.deleteBranch(branch, force: true)
            }
            .confirmationDialog(
                "Delete \(model.remoteBranchToDelete?.shortName ?? "") on \(model.remoteBranchToDelete?.remote ?? "the remote")?",
                isPresented: isPresented($model.remoteBranchToDelete),
                presenting: model.remoteBranchToDelete
            ) { remote in
                Button("Delete on \(remote.remote)", role: .destructive) {
                    Task { await model.deleteRemoteBranch(remote) }
                }
            } message: { remote in
                Text(deleteRemoteMessage(remote))
            }
            .confirmationDialog(
                "Delete tag \(model.tagToDelete?.name ?? "")?",
                isPresented: isPresented($model.tagToDelete),
                presenting: model.tagToDelete
            ) { tag in
                Button("Delete", role: .destructive) {
                    Task { await model.deleteTag(tag) }
                }
            } message: { tag in
                Text(deleteTagMessage(tag))
            }
            .confirmationDialog(
                "Delete tag \(model.remoteTagToDelete?.name ?? "") on \(model.remoteTagToDelete?.remote ?? "the remote")?",
                isPresented: isPresented($model.remoteTagToDelete),
                presenting: model.remoteTagToDelete
            ) { ref in
                Button("Delete on \(ref.remote)", role: .destructive) {
                    Task { await model.deleteRemoteTag(ref) }
                }
            } message: { ref in
                Text("This deletes the tag on \(ref.remote) for everyone. Clones that already fetched it keep it.\n\nCheddar only deletes it if it still points at \(ref.sha.prefix(7)), as of your last fetch.")
            }
            .confirmationDialog(
                "Move \(model.orphanToTrash?.displayName ?? "") to the Trash?",
                isPresented: isPresented($model.orphanToTrash),
                presenting: model.orphanToTrash
            ) { orphan in
                Button("Move to Trash", role: .destructive) {
                    Task { await model.moveToTrash(orphan) }
                }
            } message: { orphan in
                Text("\(orphan.path)\n\nYou can put it back from the Trash in Finder.")
            }
    }

    private func deleteRemoteMessage(_ remote: RemoteBranch) -> String {
        let trackers = (model.snapshot?.branches ?? []).filter { $0.upstreamRef == remote.ref }.map(\.name)
        var lines = ["This deletes the branch on \(remote.remote) for everyone. On GitHub, open pull requests from it are closed."]
        if trackers.count == 1 {
            lines.append("Your local branch \(trackers[0]) keeps its commits; its upstream will show as gone.")
        } else if trackers.count > 1 {
            lines.append("Your local branches \(trackers.joined(separator: ", ")) keep their commits; their upstreams will show as gone.")
        }
        lines.append("Cheddar only deletes it if it still points at \(remote.sha.prefix(7)), as of your last fetch.")
        return lines.joined(separator: "\n\n")
    }

    private func deleteTagMessage(_ tag: Tag) -> String {
        let entry = model.tagEntries.first { $0.name == tag.name }
        let remotes = entry?.status.map { $0.on + $0.differsOn } ?? []
        guard !remotes.isEmpty else { return "Only the tag is deleted; the commit it points at isn't affected." }
        return "Only your local tag is deleted. It's still on \(remotes.joined(separator: ", ")), and a later fetch can bring it back; use Delete on \(remotes[0]) to remove it there."
    }

    private func isPresented<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

extension View {
    /// “x isn't fully merged”: `git branch -d` refused `branch`; offers `-D` with a warning.
    func unmergedBranchConfirmation(_ branch: Binding<String?>, deleteAnyway: @escaping (String) async -> Void) -> some View {
        confirmationDialog(
            "“\(branch.wrappedValue ?? "")” isn't fully merged",
            isPresented: Binding(get: { branch.wrappedValue != nil }, set: { if !$0 { branch.wrappedValue = nil } }),
            presenting: branch.wrappedValue
        ) { name in
            Button("Delete Anyway", role: .destructive) {
                Task { await deleteAnyway(name) }
            }
            Button("Keep Branch", role: .cancel) {}
        } message: { _ in
            Text("It has commits that aren't in HEAD or its upstream. Deleting it with -D drops them; they stay recoverable from the reflog for a while.")
        }
    }
}

/// "Tags ⌄": the title, then the chevron.
private struct TrailingChevronLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.imageScale(.small).foregroundStyle(.secondary)
        }
    }
}
