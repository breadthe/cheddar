import SwiftUI

@main
struct CheddarApp: App {
    @State private var log: CommandLog
    @State private var dependencies: DependencyStore
    @State private var appState = AppState()

    init() {
        let log = CommandLog()
        _log = State(initialValue: log)
        _dependencies = State(initialValue: DependencyStore(log: log))
    }

    var body: some Scene {
        Window("Cheddar", id: "main") {
            RootView()
                .environment(dependencies)
                .environment(appState)
                .environment(log)
                .frame(minWidth: 720, minHeight: 420)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Project…") { appState.isAddingProject = true }
                    .keyboardShortcut("o")
                    .disabled(dependencies.git == nil)
            }
            ProjectCommandMenus()
        }

        Settings {
            SettingsView()
                .environment(dependencies)
        }
    }
}
