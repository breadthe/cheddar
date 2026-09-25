import SwiftUI

/// A tag, with how it compares with the remotes once a Fetch has checked. A tag that matches every remote
/// gets no badge; the section header says what it was compared with.
struct TagRow: View {
    let entry: TagEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag")
                .foregroundStyle(.secondary)
            Text(entry.name)
                .monospaced()
                .foregroundStyle(GitColors.tag)
                .lineLimit(1)
            if let status = entry.status {
                badges(status)
            }
            Spacer()
            if let tag = entry.local {
                Text(tag.subject)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let date = tag.date {
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
    }

    @ViewBuilder
    private func badges(_ status: TagEntry.Status) -> some View {
        if entry.local == nil {
            TagBadge(text: "only on \(status.on.joined(separator: ", "))")
                .help("Not fetched yet")
        } else if status.on.isEmpty && status.differsOn.isEmpty {
            TagBadge(text: "local only")
                .help("Not pushed")
        } else if !status.missingFrom.isEmpty {
            TagBadge(text: "not on \(status.missingFrom.joined(separator: ", "))")
        }
        ForEach(status.differsOn, id: \.self) { remote in
            Label("differs on \(remote)", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("\(remote) has a different \(entry.name) (\(status.remoteObjects[remote]?.prefix(7) ?? "")). Push and fetch won't replace either one.")
        }
    }
}
