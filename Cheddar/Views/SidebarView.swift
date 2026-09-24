import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        List(selection: $appState.selection) {
            Section("Projects") {
                ForEach(appState.projects) { project in
                    Label(project.name, systemImage: "folder")
                        .help(project.path)
                        .tag(project.id)
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([project.url])
                            }
                            Divider()
                            Button("Remove from Cheddar", role: .destructive) { remove(project) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    appState.isAddingProject = true
                } label: {
                    Label("Add Project", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add Project (⌘O)")
                Spacer()
            }
            .padding(8)
        }
    }

    private func remove(_ project: Project) {
        do {
            try appState.removeProject(project)
        } catch {
            appState.alert = AppAlert(title: "Couldn't remove \(project.name)", message: error.localizedDescription)
        }
    }
}
