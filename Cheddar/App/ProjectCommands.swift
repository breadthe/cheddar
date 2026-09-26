import SwiftUI

/// What the focused project exposes to the menu bar.
struct ProjectCommands {
    var isEnabled: Bool
    var refresh: () -> Void
    /// nil when the project has no remotes.
    var fetch: (() -> Void)?
    var newWorktree: () -> Void
    var cleanUp: () -> Void
    var measureDiskUsage: () -> Void
    /// The preferred editor (Settings → General).
    var editorName: String
    var openInEditor: (() -> Void)?
    /// nil when the selection can't be handed off / deleted.
    var handOffSelection: (() -> Void)?
    var deleteSelection: (() -> Void)?
}

extension FocusedValues {
    @Entry var projectCommands: ProjectCommands?
}

/// View → Refresh / Command Log, and the Worktree menu.
struct ProjectCommandMenus: Commands {
    @FocusedValue(\.projectCommands) private var project
    @AppStorage("showCommandLog") private var showLog = false
    @AppStorage("showInspector") private var showInspector = false

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Refresh") { project?.refresh() }
                .keyboardShortcut("r")
                .disabled(project?.isEnabled != true)
            Button("Fetch All Remotes") { project?.fetch?() }
                .disabled(project?.isEnabled != true || project?.fetch == nil)
            Button(showLog ? "Hide Command Log" : "Show Command Log") { showLog.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button(showInspector ? "Hide Inspector" : "Show Inspector") { showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Worktree") {
            Button("New Worktree…") { project?.newWorktree() }
                .keyboardShortcut("n")
                .disabled(project?.isEnabled != true)
            Button("Open in \(project?.editorName ?? "Editor")") { project?.openInEditor?() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(project?.openInEditor == nil)
            Button("Hand Off…") { project?.handOffSelection?() }
                .disabled(project?.isEnabled != true || project?.handOffSelection == nil)
            Divider()
            Button("Clean Up…") { project?.cleanUp() }
                .disabled(project?.isEnabled != true)
            Button("Calculate Disk Usage") { project?.measureDiskUsage() }
                .disabled(project?.isEnabled != true)
            Divider()
            Button("Delete…") { project?.deleteSelection?() }
                .keyboardShortcut(.delete)
                .disabled(project?.isEnabled != true || project?.deleteSelection == nil)
        }
    }
}
