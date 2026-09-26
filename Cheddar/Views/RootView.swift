import SwiftUI

/// Shows the Setup screen until a usable git is found, then the normal UI (no restart needed).
struct RootView: View {
    @Environment(DependencyStore.self) private var dependencies
    @Environment(AppState.self) private var appState
    @Environment(RunManager.self) private var runs
    @AppStorage("showCommandLog") private var showLog = false
    @AppStorage(PreferenceKey.appearance) private var appearance = Appearance.system.rawValue
    @AppStorage(PreferenceKey.codexHome) private var codexHome = ""
    @AppStorage(PreferenceKey.extraDiscoveryLocations) private var extraLocations = Data()
    /// The selected project's model; replaced when the project or anything its service depends on changes.
    @State private var model: ProjectModel?
    @State private var remoteTagCache = RemoteTagCache()

    var body: some View {
        @Bindable var appState = appState
        Group {
            if !dependencies.hasChecked {
                ProgressView("Checking for git…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let git = dependencies.git {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 160, ideal: 200)
                } detail: {
                    VSplitView {
                        detail(git: git)
                            .frame(minHeight: 240)
                        if showLog {
                            BottomPanel()
                                .frame(minHeight: 80, idealHeight: 180)
                        }
                    }
                }
                .fileImporter(isPresented: $appState.isAddingProject, allowedContentTypes: [.folder]) { result in
                    guard case .success(let folder) = result else { return }
                    Task { await addProject(at: folder, git: git) }
                }
            } else {
                SetupView()
            }
        }
        .alert(item: $appState.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .task {
            await dependencies.check()
            await runs.removeLeftoverHerdLinks(searchPath: dependencies.searchPath)
        }
        .onAppear { Appearance.apply(appearance) }
        .onChange(of: appearance) { _, new in Appearance.apply(new) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await dependencies.check(force: false) }
        }
    }

    @ViewBuilder
    private func detail(git: GitRunner) -> some View {
        if appState.selectedProject != nil {
            Group {
                if let model {
                    ProjectView(model: model)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: modelKey(git: git), initial: true) { updateModel(git: git) }
        } else if appState.projects.isEmpty {
            ContentUnavailableView {
                Label("No Projects", systemImage: "folder.badge.plus")
            } description: {
                Text("Add a local git repository to see its worktrees and branches.")
            } actions: {
                Button("Add Project…") { appState.isAddingProject = true }
            }
        } else {
            ContentUnavailableView("No Project Selected", systemImage: "folder")
        }
    }

    private func modelKey(git: GitRunner) -> String {
        guard let project = appState.selectedProject else { return "" }
        return "\(project.id)|\(project.trunk ?? "")|\(codexHome)|\(extraLocations.hashValue)|\(git.executable.path)"
    }

    private func updateModel(git: GitRunner) {
        guard let project = appState.selectedProject else {
            model = nil
            return
        }
        model = ProjectModel(project: project, service: service(for: project, git: git), remoteTagCache: remoteTagCache, runs: runs)
    }

    private func service(for project: Project, git: GitRunner) -> GitService {
        GitService(
            git: git,
            codexHome: DiscoveryPreferences.codexHome(codexHome),
            extraLocations: DiscoveryPreferences.decode(extraLocations),
            trunkOverride: project.trunk
        )
    }

    private func addProject(at folder: URL, git: GitRunner) async {
        do {
            try await appState.addProject(at: folder, using: GitService(git: git))
        } catch {
            appState.alert = AppAlert(
                title: "Couldn't add \(folder.lastPathComponent)",
                message: error.localizedDescription
            )
        }
    }
}
