import AppKit

/// UserDefaults keys for Settings. Read with `@AppStorage` in views.
enum PreferenceKey {
    static let appearance = "appearance"
    static let terminalApp = "terminalApp"
    static let editorApp = "editorApp"
    static let codexHome = "codexHome"
    static let extraDiscoveryLocations = "extraDiscoveryLocations"
}

/// Settings → Appearance. Applied through `NSApp.appearance` rather than `.preferredColorScheme`,
/// so sheets, alerts, menus and the Settings window follow it too.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func apply(_ rawValue: String) {
        NSApp.appearance = (Appearance(rawValue: rawValue) ?? .system).nsAppearance
    }
}

/// Settings → Discovery, stored as JSON in UserDefaults.
enum DiscoveryPreferences {
    static func decode(_ data: Data) -> [DiscoveryLocation] {
        (try? JSONDecoder().decode([DiscoveryLocation].self, from: data)) ?? []
    }

    static func encode(_ locations: [DiscoveryLocation]) -> Data {
        (try? JSONEncoder().encode(locations)) ?? Data()
    }

    /// The Codex home in effect: the Settings value, else `$CODEX_HOME`, else `~/.codex`.
    static func codexHome(_ setting: String) -> String {
        let trimmed = setting.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? OriginClassifier.defaultCodexHome : (trimmed as NSString).expandingTildeInPath
    }
}
