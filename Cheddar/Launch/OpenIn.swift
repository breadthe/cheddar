import AppKit

/// A GUI app Cheddar can open a worktree in.
struct ExternalApp: Identifiable, Hashable {
    var id: String { bundleID }
    let name: String
    let bundleID: String
    /// Registry entry with install help, for apps Cheddar lists even when missing.
    var dependencyID: String?

    var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    var isInstalled: Bool { url != nil }
    var dependency: Dependency? { Dependencies.all.first { $0.id == dependencyID } }
}

/// Finder, Terminal, editors and Claude Code (see specs.md → Open in).
enum OpenIn {
    static let terminal = ExternalApp(name: "Terminal", bundleID: "com.apple.Terminal")

    /// Choices for Settings → General → Terminal; only installed ones are offered.
    static let terminals = [
        terminal,
        ExternalApp(name: "iTerm", bundleID: "com.googlecode.iterm2"),
        ExternalApp(name: "Ghostty", bundleID: "com.mitchellh.ghostty"),
        ExternalApp(name: "Warp", bundleID: "dev.warp.Warp-Stable"),
        ExternalApp(name: "WezTerm", bundleID: "com.github.wez.wezterm"),
        ExternalApp(name: "kitty", bundleID: "net.kovidgoyal.kitty"),
    ]

    /// In menu order. VS Code and Cursor are always listed (with install help when missing); the rest only
    /// when installed.
    static let editors = [
        ExternalApp(name: "Zed", bundleID: "dev.zed.Zed"),
        ExternalApp(name: "Sublime Text", bundleID: "com.sublimetext.4"),
        ExternalApp(name: "PhpStorm", bundleID: "com.jetbrains.PhpStorm"),
        ExternalApp(name: "WebStorm", bundleID: "com.jetbrains.WebStorm"),
        ExternalApp(name: "VS Code", bundleID: "com.microsoft.VSCode", dependencyID: Dependencies.vscode.id),
        ExternalApp(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", dependencyID: Dependencies.cursor.id),
        ExternalApp(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
    ]

    /// The preferred editor until one is chosen in Settings: the first installed one, else VS Code.
    static var defaultEditorID: String {
        (editors.first(where: \.isInstalled) ?? vscode).bundleID
    }

    private static var vscode: ExternalApp { editors.first { $0.dependencyID == Dependencies.vscode.id }! }

    static func terminal(for bundleID: String) -> ExternalApp {
        terminals.first { $0.bundleID == bundleID && $0.isInstalled } ?? terminal
    }

    static func editor(for bundleID: String) -> ExternalApp {
        editors.first { $0.bundleID == bundleID } ?? vscode
    }

    /// Editors to list in the Open menu.
    static var listedEditors: [ExternalApp] {
        editors.filter { $0.dependencyID != nil || $0.isInstalled }
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Opens the folder in an app, like `open -a <app> <path>`.
    static func open(_ path: String, in app: ExternalApp) async throws {
        guard let appURL = app.url else {
            throw OperationError(errorDescription: "\(app.name) isn't installed.")
        }
        try await NSWorkspace.shared.open(
            [URL(fileURLWithPath: path, isDirectory: true)],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// Opens a Terminal window at the folder and runs `claude` there (AppleScript into Terminal.app).
    @MainActor
    static func claudeCode(in path: String) throws {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "cd " & quoted form of "\(escaped)" & " && claude"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return }
        let code = error[NSAppleScript.errorNumber] as? Int
        if code == -1743 {
            throw OperationError(errorDescription: "Cheddar isn't allowed to control Terminal. Turn it on in System Settings → Privacy & Security → Automation → Cheddar → Terminal.")
        }
        throw OperationError(errorDescription: (error[NSAppleScript.errorMessage] as? String) ?? "Couldn't run the script in Terminal.")
    }
}
