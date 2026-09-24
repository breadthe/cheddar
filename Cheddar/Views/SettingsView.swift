import SwiftUI

/// The ⌘, window: General, Appearance, Dependencies, Discovery.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
            DependencySettings()
                .tabItem { Label("Dependencies", systemImage: "shippingbox") }
            DiscoverySettings()
                .tabItem { Label("Discovery", systemImage: "binoculars") }
        }
        .frame(width: 560)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(DependencyStore.self) private var dependencies
    @AppStorage(PreferenceKey.terminalApp) private var terminalID = OpenIn.terminal.bundleID
    @AppStorage(PreferenceKey.editorApp) private var editorID = OpenIn.defaultEditorID
    @AppStorage(DependencyStore.gitOverrideKey) private var gitOverride = ""
    @State private var isChoosingGit = false

    var body: some View {
        Form {
            Section("Open In") {
                Picker("Terminal", selection: $terminalID) {
                    ForEach(OpenIn.terminals.filter(\.isInstalled)) { app in
                        Text(app.name).tag(app.bundleID)
                    }
                }
                Picker("Editor", selection: $editorID) {
                    ForEach(OpenIn.editors.filter { $0.isInstalled || $0.bundleID == editorID }) { app in
                        Text(app.isInstalled ? app.name : "\(app.name) (Not Installed)").tag(app.bundleID)
                    }
                }
                Text("The preferred editor opens on double-click or ⇧⌘E. Claude Code always opens in Terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Git") {
                LabeledContent("In use") {
                    Text(gitInUse).monospaced().textSelection(.enabled)
                }
                HStack {
                    TextField("Git binary", text: $gitOverride, prompt: Text("Automatic"))
                        .monospaced()
                        .onSubmit { Task { await dependencies.check() } }
                    Button("Choose…") { isChoosingGit = true }
                    Button("Automatic") {
                        gitOverride = ""
                        Task { await dependencies.check() }
                    }
                    .disabled(gitOverride.isEmpty)
                }
                Text("Automatic uses the first git on your login shell's PATH, then /usr/bin/git.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isChoosingGit, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            gitOverride = url.path
            Task { await dependencies.check() }
        }
    }

    private var gitInUse: String {
        switch dependencies.statuses[Dependencies.git.id] {
        case .found(let path, let version): "\(path) (\(version?.description ?? "unknown version"))"
        case .tooOld(let path, let version): "\(path) (\(version), too old)"
        case .failed(let path, _): "\(path) (fails to run)"
        case .missing, nil: "Not found"
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(PreferenceKey.appearance) private var appearance = Appearance.system.rawValue

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dependencies

private struct DependencySettings: View {
    @Environment(DependencyStore.self) private var dependencies

    var body: some View {
        Form {
            Section {
                ForEach(Dependencies.all) { dependency in
                    let status = dependencies.statuses[dependency.id] ?? .missing
                    if status.isAvailable {
                        row(dependency, status: status)
                    } else {
                        DisclosureGroup {
                            DependencyHelp(dependency: dependency, status: status, hasHomebrew: dependencies.hasHomebrew)
                                .padding(.vertical, 8)
                        } label: {
                            row(dependency, status: status)
                        }
                    }
                }
            } footer: {
                HStack {
                    Button("Check Again") { Task { await dependencies.check() } }
                        .disabled(dependencies.isChecking)
                    if dependencies.isChecking { ProgressView().controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ dependency: Dependency, status: DependencyStatus) -> some View {
        HStack {
            symbol(for: status)
            VStack(alignment: .leading) {
                Text(dependency.name)
                Text(detail(for: status, required: dependency.isRequired))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func symbol(for status: DependencyStatus) -> some View {
        switch status {
        case .found:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Found")
        case .tooOld, .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).accessibilityLabel("Problem")
        case .missing:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary).accessibilityLabel("Missing")
        }
    }

    private func detail(for status: DependencyStatus, required: Bool) -> String {
        switch status {
        case .found(let path, let version): [version?.description, path].compactMap { $0 }.joined(separator: " · ")
        case .tooOld(let path, let version): "\(version) at \(path) is too old"
        case .failed(let path, _): "\(path) fails to run"
        case .missing: required ? "Missing (required)" : "Not installed"
        }
    }
}

// MARK: - Discovery

private struct DiscoverySettings: View {
    @AppStorage(PreferenceKey.codexHome) private var codexHome = ""
    @AppStorage(PreferenceKey.extraDiscoveryLocations) private var locationsData = Data()
    @State private var locations: [DiscoveryLocation] = []
    @State private var isChoosingCodexHome = false

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Codex home", text: $codexHome, prompt: Text(OriginClassifier.defaultCodexHome))
                        .monospaced()
                    Button("Choose…") { isChoosingCodexHome = true }
                }
            } header: {
                Text("Codex")
            } footer: {
                Text("Codex keeps its worktrees in <Codex home>/worktrees. GUI apps don't see $CODEX_HOME, so set it here if you've moved it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach($locations) { $location in
                    HStack {
                        TextField("Path", text: $location.path, prompt: Text("~/conductor/workspaces or .conductor"))
                            .monospaced()
                        TextField("Label", text: $location.label, prompt: Text("conductor"))
                            .frame(width: 120)
                        Button {
                            locations.removeAll { $0.id == location.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove location")
                    }
                    .labelsHidden()
                }
                Button("Add Location") {
                    locations.append(DiscoveryLocation(path: "", label: ""))
                }
            } header: {
                Text("Extra locations")
            } footer: {
                Text("Worktrees under these paths get the label as their badge and are treated like other tools' worktrees. Paths are absolute (/…, ~/…) or relative to the repo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { locations = DiscoveryPreferences.decode(locationsData) }
        .onChange(of: locations) { _, new in locationsData = DiscoveryPreferences.encode(new) }
        .fileImporter(isPresented: $isChoosingCodexHome, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { codexHome = url.path }
        }
    }
}
