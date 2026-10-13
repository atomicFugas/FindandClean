import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct MainSplitView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var searchModel = SearchViewModel()
    @StateObject private var uninstallModel = UninstallViewModel()
    @State private var isAppDropTargeted = false

    var body: some View {
        Group {
            switch appState.mode {
            case .find:
                findWorkspace
            case .duo:
                duoWorkspace
            }
        }
        .padding(10)
        .onDrop(of: [.fileURL], isTargeted: $isAppDropTargeted) { providers in
            Task { await handleAppDrop(providers) }
            return true
        }
        .overlay {
            if isAppDropTargeted && appState.mode == .find {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.08))
                    )
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "app.dashed")
                                .font(.system(size: 40, weight: .light))
                            Text("Drop app to open Uninstall")
                                .font(.title3.weight(.semibold))
                            Text("Find stays open on the right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    private var findWorkspace: some View {
        SearchPane(model: searchModel, showsDropHint: true)
    }

    private var duoWorkspace: some View {
        HSplitView {
            UninstallPane(
                model: uninstallModel,
                onClose: {
                    uninstallModel.reset()
                    appState.exitDuo()
                }
            )
            .frame(minWidth: 360, idealWidth: 440)

            SearchPane(model: searchModel, showsDropHint: false)
                .frame(minWidth: 420, idealWidth: 540)
        }
    }

    @MainActor
    private func handleAppDrop(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadURL(from: provider) {
                urls.append(url)
            }
        }
        let apps = urls.filter(isAppLike)
        guard !apps.isEmpty else { return }
        await openUninstall(with: apps)
    }

    @MainActor
    private func openUninstall(with urls: [URL]) async {
        appState.enterDuo()
        await uninstallModel.scan(urls: urls)
    }

    private func isAppLike(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        if resolved.pathExtension.lowercased() == "app" { return true }
        return FileManager.default.fileExists(atPath: resolved.appendingPathComponent("Contents/Info.plist").path)
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

struct UninstallPane: View {
    @ObservedObject var model: UninstallViewModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Uninstall")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Close Uninstall and return to Find")
            }

            DropZoneView(isScanning: model.isScanning) { urls in
                Task { await model.scan(urls: urls) }
            }

            if model.isScanning {
                ProgressView(value: model.progress) {
                    Text(model.statusText)
                }
            } else if let summary = model.summaryText {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            RelatedFilesView(
                groups: model.groups,
                onToggle: model.toggle,
                onToggleCategory: model.toggleCategory
            )

            HStack {
                Spacer()
                Button("Remove Checked") {
                    Task { await model.removeChecked() }
                }
                .disabled(!model.canRemove)
            }
        }
        .padding(8)
        .alert("Confirm removal", isPresented: $model.showConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                Task { await model.performRemoval() }
            }
        } message: {
            Text(model.confirmMessage)
        }
        .alert("Protected apps", isPresented: $model.showProtectedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.protectedMessage)
        }
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct SearchPane: View {
    @ObservedObject var model: SearchViewModel
    var showsDropHint: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Files")
                .font(.title2.weight(.semibold))

            if showsDropHint {
                Text("Drop an app onto the window to open Uninstall beside Find.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SearchFormView(
                query: $model.query,
                isSearching: model.isSearching,
                onSearch: { model.search() },
                onStop: { model.stopSearch() }
            )

            // Full-width progress while searching; count lives in the results toolbar.
            Group {
                if model.isSearching {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                } else {
                    Color.clear.frame(height: 4)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 8)

            ResultsTableView(
                roots: model.treeRoots,
                resultCount: model.hits.count,
                showResultCount: !model.isSearching && !model.hits.isEmpty,
                highlightQuery: model.query.name,
                selection: $model.selection,
                expanded: $model.expanded,
                onReveal: model.revealSelection,
                onOpen: model.openSelection,
                onTrash: {
                    Task { await model.trashSelection() }
                },
                onCopyPath: model.copySelectionPaths,
                onExpandAll: model.expandAll,
                onCollapseAll: model.collapseAll
            )
        }
        .padding(8)
        .alert("Confirm trash", isPresented: $model.showConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                Task { await model.performTrash() }
            }
        } message: {
            Text(model.confirmMessage)
        }
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
