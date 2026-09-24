import SwiftUI

/// Full-window screen shown instead of the project view while a required dependency is missing or too old.
struct SetupView: View {
    @Environment(DependencyStore.self) private var dependencies
    @AppStorage(DependencyStore.gitOverrideKey) private var gitOverride = ""
    @State private var isChoosingGit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("Cheddar needs a few things first", systemImage: "wrench.and.screwdriver")
                    .font(.title2)
                ForEach(dependencies.missingRequired) { dependency in
                    DependencyHelp(
                        dependency: dependency,
                        status: dependencies.statuses[dependency.id] ?? .missing,
                        hasHomebrew: dependencies.hasHomebrew
                    )
                }
                HStack {
                    Button("Check Again") {
                        Task { await dependencies.check() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(dependencies.isChecking)
                    Button("Choose git Binary…") { isChoosingGit = true }
                    if dependencies.isChecking {
                        ProgressView().controlSize(.small)
                    }
                }
                if !gitOverride.isEmpty {
                    Text("Using git from Settings: \(gitOverride)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(isPresented: $isChoosingGit, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            gitOverride = url.path
            Task { await dependencies.check() }
        }
    }
}

/// What's missing, what it affects, and how to install it. Cheddar never installs anything itself.
struct DependencyHelp: View {
    let dependency: Dependency
    let status: DependencyStatus
    let hasHomebrew: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(dependency.name).font(.headline)
            Text(problem)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Needed for: \(dependency.enables)")
            ForEach(installOptions, id: \.self) { option in
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.label).font(.subheadline)
                    HStack {
                        Text(option.command)
                            .monospaced()
                            .textSelection(.enabled)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(option.command, forType: .string)
                        }
                        .accessibilityLabel("Copy \(option.label) command")
                    }
                    if option.needsHomebrew && !hasHomebrew {
                        Text("Needs [Homebrew](https://brew.sh), which isn't installed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Link("Install docs ↗", destination: dependency.docs)
        }
    }

    private var problem: String {
        switch status {
        case .missing:
            "Not found."
        case .tooOld(let path, let version):
            "Found \(version) at \(path), but Cheddar needs \(dependency.minimumVersion?.description ?? "a newer version") or later."
        case .failed(let path, let message):
            "Found at \(path), but it failed to run:\n\(message)"
        case .found(let path, _):
            "Found at \(path)."
        }
    }

    /// Without Homebrew, the non-brew options come first.
    private var installOptions: [InstallOption] {
        hasHomebrew ? dependency.installOptions
            : dependency.installOptions.filter { !$0.needsHomebrew } + dependency.installOptions.filter(\.needsHomebrew)
    }
}
