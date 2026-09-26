import SwiftUI

/// A run's output, as plain text (colors are turned off and ANSI codes stripped).
struct RunOutputView: View {
    let session: RunSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(session.lines) { line in
                        Text(line.text)
                            .foregroundStyle(line.text.hasPrefix("$ ") ? .primary : .secondary)
                            .id(line.id)
                    }
                }
                .font(.caption.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .onChange(of: session.lines.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onAppear {
                if let id = session.lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    /// The panel header's buttons for a run: its URL, Stop, or Close once it has ended.
    struct Actions: View {
        let session: RunSession
        @Environment(RunManager.self) private var runs

        var body: some View {
            HStack(spacing: 12) {
                RunStatusLabel(session: session)
                if let url = session.url, session.isActive {
                    Button(url.host ?? url.absoluteString) { NSWorkspace.shared.open(url) }
                        .help("Open \(url.absoluteString)")
                }
                if session.isActive {
                    Button("Stop") { Task { await runs.stop(session.id) } }
                } else {
                    Button("Close") { runs.close(session.id) }
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}

/// "Starting…", "● running", "✗ exited 1" and so on, never by color alone.
struct RunStatusLabel: View {
    let session: RunSession

    var body: some View {
        switch session.phase {
        case .starting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Starting…")
            }
            .foregroundStyle(.secondary)
        case .running:
            Label("running", systemImage: "circle.fill")
                .foregroundStyle(.green)
                .labelStyle(StatusLabelStyle())
        case .stopped:
            Text("stopped").foregroundStyle(.secondary)
        case .exited(let status):
            if status == 0 {
                Text("exited").foregroundStyle(.secondary)
            } else {
                Label("exited \(status)", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
                    .labelStyle(StatusLabelStyle())
            }
        case .failed(let message):
            Label("couldn't start", systemImage: "xmark.circle")
                .foregroundStyle(.red)
                .labelStyle(StatusLabelStyle())
                .help(message)
        }
    }

    private struct StatusLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 3) {
                configuration.icon.imageScale(.small)
                configuration.title
            }
        }
    }
}
