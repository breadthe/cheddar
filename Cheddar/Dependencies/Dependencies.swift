import Foundation

struct InstallOption: Hashable {
    var label: String
    var command: String

    var needsHomebrew: Bool { command.hasPrefix("brew ") }
}

struct Dependency: Identifiable {
    enum Detection {
        /// A binary found on the resolved PATH; its version comes from `<binary> --version`.
        case binary(String)
        /// A GUI app, found by bundle ID.
        case app(bundleID: String)
        /// `xcode-select -p` exits 0.
        case commandLineTools
    }

    var id: String
    var name: String
    var isRequired: Bool
    /// What the dependency enables, shown when it's missing.
    var enables: String
    var detection: Detection
    var minimumVersion: Version?
    var installOptions: [InstallOption]
    var docs: URL
}

/// The dependency registry. Adding a dependency is a one-entry change.
enum Dependencies {
    static let git = Dependency(
        id: "git",
        name: "git",
        isRequired: true,
        enables: "Everything. Cheddar runs git for every operation.",
        detection: .binary("git"),
        // `worktree list --porcelain -z` needs 2.36.
        minimumVersion: Version("2.36"),
        installOptions: [
            InstallOption(label: "Xcode Command Line Tools", command: "xcode-select --install"),
            InstallOption(label: "Homebrew", command: "brew install git"),
        ],
        docs: URL(string: "https://git-scm.com/install/mac")!
    )

    static let commandLineTools = Dependency(
        id: "clt",
        name: "Xcode Command Line Tools",
        isRequired: false,
        enables: "Apple's git at /usr/bin/git.",
        detection: .commandLineTools,
        installOptions: [InstallOption(label: "Install", command: "xcode-select --install")],
        docs: URL(string: "https://git-scm.com/install/mac")!
    )

    static let homebrew = Dependency(
        id: "homebrew",
        name: "Homebrew",
        isRequired: false,
        enables: "Only needed for the `brew` install commands.",
        detection: .binary("brew"),
        installOptions: [InstallOption(
            label: "Install script",
            command: #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
        )],
        docs: URL(string: "https://brew.sh")!
    )

    static let claude = Dependency(
        id: "claude",
        name: "Claude Code",
        isRequired: false,
        enables: "Open in → Claude Code here.",
        detection: .binary("claude"),
        installOptions: [
            InstallOption(label: "Install script", command: "curl -fsSL https://claude.ai/install.sh | bash"),
            InstallOption(label: "Homebrew", command: "brew install --cask claude-code"),
        ],
        docs: URL(string: "https://code.claude.com/docs/en/setup")!
    )

    static let vscode = Dependency(
        id: "vscode",
        name: "VS Code",
        isRequired: false,
        enables: "Open in → VS Code.",
        detection: .app(bundleID: "com.microsoft.VSCode"),
        installOptions: [InstallOption(label: "Homebrew", command: "brew install --cask visual-studio-code")],
        docs: URL(string: "https://code.visualstudio.com/docs/setup/mac")!
    )

    static let cursor = Dependency(
        id: "cursor",
        name: "Cursor",
        isRequired: false,
        enables: "Open in → Cursor.",
        detection: .app(bundleID: "com.todesktop.230313mzl4w4u92"),
        installOptions: [InstallOption(label: "Homebrew", command: "brew install --cask cursor")],
        docs: URL(string: "https://cursor.com/downloads")!
    )

    static let all = [git, commandLineTools, homebrew, claude, vscode, cursor]
}

/// A dotted version, compared numerically (`2.36` == `2.36.0` < `2.39.5`).
struct Version: Comparable, CustomStringConvertible {
    var components: [Int]

    /// Takes the first dotted number in the string, e.g. `git version 2.39.5 (Apple Git-154)` → 2.39.5.
    init?(_ string: String) {
        guard let match = string.firstMatch(of: #/\d+(\.\d+)*/#) else { return nil }
        components = match.output.0.split(separator: ".").compactMap { Int($0) }
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        let pad = { (v: Version) in v.components + Array(repeating: 0, count: count - v.components.count) }
        return pad(lhs).lexicographicallyPrecedes(pad(rhs))
    }

    static func == (lhs: Version, rhs: Version) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}
