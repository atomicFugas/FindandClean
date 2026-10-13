import SwiftUI
import AppKit

struct RelatedFilesView: View {
    var groups: [RelatedFileGroup]
    var onToggle: (RelatedFileItem.ID, Bool) -> Void
    var onToggleCategory: (RelatedFileCategory, Bool) -> Void

    var body: some View {
        Group {
            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No leftovers listed")
                        .font(.headline)
                    Text("Drop an app above to scan Library folders.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                RelatedFileRow(item: item) { selected in
                                    onToggle(item.id, selected)
                                }
                            }
                        } header: {
                            HStack {
                                Text(group.category.rawValue)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: group.totalBytes, countStyle: .file))
                                    .foregroundStyle(.secondary)
                                Button(group.selectedCount == group.items.count ? "None" : "All") {
                                    let selectAll = group.selectedCount != group.items.count
                                    onToggleCategory(group.category, selectAll)
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct RelatedFileRow: View {
    let item: RelatedFileItem
    var onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { item.isSelected },
                set: onToggle
            ))
            .labelsHidden()
            .disabled(item.isProtected)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                Text(item.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.formattedSize)
                    .font(.caption.monospacedDigit())
                if item.isProtected {
                    Text("Protected")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if item.category.isUserDataSensitive {
                    Text("User data")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Reveal in Finder") {
                FinderReveal.reveal([item.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
        }
    }
}
