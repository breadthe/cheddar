import SwiftUI

/// Bottom panel listing every git command the app ran, with its output.
struct CommandLogView: View {
    @Environment(CommandLog.self) private var log

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Command Log")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { log.clear() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(log.entries.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(log.entries) { entry in
                            EntryView(entry: entry).id(entry.id)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .onChange(of: log.entries.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private struct EntryView: View {
        let entry: CommandLog.Entry

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .foregroundStyle(.tertiary)
                    Text(entry.exitCode == nil && !entry.failed ? "#" : "$")
                        .foregroundStyle(.secondary)
                    command
                    if let code = entry.exitCode, code != 0 {
                        Text("exit \(code)").foregroundStyle(.red)
                    } else if entry.failed {
                        Text("failed").foregroundStyle(.red)
                    }
                }
                if let directory = entry.directory {
                    Text(directory).foregroundStyle(.tertiary)
                }
                if !entry.output.isEmpty {
                    Text(entry.output)
                        .foregroundStyle(entry.failed ? .red : .secondary)
                }
            }
            .font(.caption.monospaced())
        }

        /// git commands colored by word role; notes as plain text.
        private var command: Text {
            guard !entry.tokens.isEmpty else { return Text(entry.command) }
            var text = AttributedString()
            for (index, token) in entry.tokens.enumerated() {
                if index > 0 { text += AttributedString(" ") }
                var word = AttributedString(token.text)
                word.foregroundColor = GitColors.command(token.role)
                text += word
            }
            return Text(text)
        }
    }
}
