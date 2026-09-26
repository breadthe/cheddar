import SwiftUI

@main
struct CheddarApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var log: CommandLog
    @State private var dependencies: DependencyStore
    @State private var runs: RunManager
    @State private var appState = AppState()

    init() {
        let log = CommandLog()
        _log = State(initialValue: log)
        _dependencies = State(initialValue: DependencyStore(log: log))
        _runs = State(initialValue: RunManager(log: log))
    }

    var body: some Scene {
        Window("Cheddar", id: "main") {
            RootView()
                .environment(dependencies)
                .environment(appState)
                .environment(log)
                .environment(runs)
                .frame(minWidth: 720, minHeight: 420)
                .onAppear { appDelegate.runs = runs }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Project…") { appState.isAddingProject = true }
                    .keyboardShortcut("o")
                    .disabled(dependencies.git == nil)
            }
            CommandGroup(before: .toolbar) {
                Button("Go to Project or Worktree…") { appState.isShowingPalette = true }
                    .keyboardShortcut("k")
                    .disabled(dependencies.git == nil || appState.projects.isEmpty)
            }
            ProjectCommandMenus()
        }

        Settings {
            SettingsView()
                .environment(dependencies)
        }
    }
}

/// Stops every run before quitting, so no dev server or Herd site outlives Cheddar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var runs: RunManager?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runs, runs.hasActiveSessions else { return .terminateNow }
        Task {
            await runs.stopAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
