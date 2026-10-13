import SwiftUI
import AppKit

struct ResultsTableView: View {
    var roots: [ResultTreeNode]
    var resultCount: Int
    /// Show total in the toolbar center only after search finishes.
    var showResultCount: Bool
    var highlightQuery: String
    @Binding var selection: Set<ResultTreeNode.ID>
    @Binding var expanded: Set<ResultTreeNode.ID>
    var onReveal: () -> Void
    var onOpen: () -> Void
    var onTrash: () -> Void
    var onCopyPath: () -> Void
    var onExpandAll: () -> Void
    var onCollapseAll: () -> Void

    private var flatRows: [FlatRow] {
        flatten(roots, depth: 0)
    }

    private var stripeEven: Color { Color(nsColor: .textBackgroundColor) }
    private var stripeOdd: Color {
        let colors = NSColor.alternatingContentBackgroundColors
        if colors.count > 1 {
            return Color(nsColor: colors[1])
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.bottom, 6)

            if roots.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(Array(flatRows.enumerated()), id: \.element.id) { index, row in
                        let isSelected = selection.contains(row.node.id)
                        ResultFlatRowView(
                            row: row,
                            highlightQuery: highlightQuery,
                            isExpanded: expanded.contains(row.node.id),
                            isSelected: isSelected,
                            onToggle: { toggle(row.node) }
                        )
                        .tag(row.node.id)
                        .listRowBackground(rowBackground(index: index, isSelected: isSelected))
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 8))
                    }
                }
                .listStyle(.plain)
                .background(stripeEven)
                .contextMenu {
                    Button("Reveal in Finder", action: onReveal)
                        .disabled(selection.isEmpty)
                    Button("Open", action: onOpen)
                        .disabled(selection.isEmpty)
                    Button("Copy Path", action: onCopyPath)
                        .disabled(selection.isEmpty)
                    Divider()
                    Button("Move to Trash", role: .destructive, action: onTrash)
                        .disabled(selection.isEmpty)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Button("Reveal", action: onReveal)
                .disabled(selection.isEmpty)
            Button("Open", action: onOpen)
                .disabled(selection.isEmpty)
            Button("Move to Trash", action: onTrash)
                .disabled(selection.isEmpty)

            Spacer()

            if showResultCount {
                Text("\(resultCount) found")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Expand All", action: onExpandAll)
                .disabled(roots.isEmpty)
            Button("Collapse All", action: onCollapseAll)
                .disabled(roots.isEmpty)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No results")
                .font(.headline)
            Text("Enter a name and click Find.")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Strict even/odd zebra; selection uses system highlight (not a broken repeating palette).
    @ViewBuilder
    private func rowBackground(index: Int, isSelected: Bool) -> some View {
        if isSelected {
            Color(nsColor: .selectedContentBackgroundColor)
        } else if index % 2 == 0 {
            stripeEven
        } else {
            stripeOdd
        }
    }

    private func toggle(_ node: ResultTreeNode) {
        guard node.children?.isEmpty == false else { return }
        if expanded.contains(node.id) {
            expanded.remove(node.id)
        } else {
            expanded.insert(node.id)
        }
    }

    private func flatten(_ nodes: [ResultTreeNode], depth: Int) -> [FlatRow] {
        var rows: [FlatRow] = []
        for node in nodes {
            let hasChildren = !(node.children ?? []).isEmpty
            rows.append(FlatRow(node: node, depth: depth, hasChildren: hasChildren))
            if hasChildren, expanded.contains(node.id), let children = node.children {
                rows.append(contentsOf: flatten(children, depth: depth + 1))
            }
        }
        return rows
    }
}

private struct FlatRow: Identifiable {
    var id: URL { node.id }
    let node: ResultTreeNode
    let depth: Int
    let hasChildren: Bool
}

private struct ResultFlatRowView: View {
    let row: FlatRow
    let highlightQuery: String
    let isExpanded: Bool
    let isSelected: Bool
    let onToggle: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var isMatch: Bool { row.node.hit != nil }

    var body: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: CGFloat(row.depth) * 14)

            if row.hasChildren {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Color.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse" : "Expand")
            } else {
                Color.clear.frame(width: 28, height: 28)
            }

            Image(nsImage: iconImage)
                .resizable()
                .frame(width: 16, height: 16)

            Group {
                if isMatch {
                    HighlightedText(
                        text: row.node.name,
                        highlight: highlightQuery,
                        baseFont: .body.weight(.semibold),
                        baseColor: isSelected ? .white : .primary,
                        highlightBackground: isSelected
                            ? Color.white.opacity(0.28)
                            : Color(nsColor: .selectedContentBackgroundColor).opacity(0.45)
                    )
                } else {
                    Text(row.node.name)
                        .font(.body.italic())
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                }
            }
            .lineLimit(1)
            // Clicking the name of a folder also toggles fold (bigger target than chevron alone).
            .onTapGesture(count: 2) {
                if row.hasChildren { onToggle() }
            }

            Spacer(minLength: 8)

            if let modified = row.node.modificationDate {
                Text(Self.dateFormatter.string(from: modified))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .layoutPriority(-1)
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.6) : Color.secondary.opacity(0.6))
            }
        }
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .help(row.node.url.path)
    }

    private var iconImage: NSImage {
        let workspace = NSWorkspace.shared
        if FileManager.default.fileExists(atPath: row.node.url.path) {
            return workspace.icon(forFile: row.node.url.path)
        }
        if row.node.isDirectoryNode {
            return workspace.icon(forFileType: "public.folder")
        }
        return workspace.icon(forFileType: row.node.url.pathExtension)
    }
}

private struct HighlightedText: View {
    let text: String
    let highlight: String
    let baseFont: Font
    let baseColor: Color
    var highlightBackground: Color = Color(nsColor: .selectedContentBackgroundColor).opacity(0.45)

    var body: some View {
        let needle = highlight.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            Text(text).font(baseFont).foregroundColor(baseColor)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(segments(needle: needle).enumerated()), id: \.offset) { _, segment in
                    if segment.isMatch {
                        Text(segment.text)
                            .font(baseFont)
                            .foregroundColor(baseColor)
                            .background(highlightBackground)
                    } else {
                        Text(segment.text)
                            .font(baseFont)
                            .foregroundColor(baseColor)
                    }
                }
            }
        }
    }

    private struct Segment {
        let text: String
        let isMatch: Bool
    }

    private func segments(needle: String) -> [Segment] {
        var parts: [Segment] = []
        let lower = text.lowercased()
        let needleLower = needle.lowercased()
        var searchStart = lower.startIndex

        while searchStart < lower.endIndex,
              let range = lower.range(of: needleLower, range: searchStart..<lower.endIndex) {
            let before = text[searchStart..<range.lowerBound]
            if !before.isEmpty {
                parts.append(Segment(text: String(before), isMatch: false))
            }
            parts.append(Segment(text: String(text[range]), isMatch: true))
            searchStart = range.upperBound
        }

        let rest = text[searchStart...]
        if !rest.isEmpty {
            parts.append(Segment(text: String(rest), isMatch: false))
        }
        return parts
    }
}
