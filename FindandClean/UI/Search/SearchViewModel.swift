import Foundation
import AppKit
import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = SearchQuery()
    @Published var hits: [FileHit] = []
    @Published var treeRoots: [ResultTreeNode] = []
    @Published var selection: Set<ResultTreeNode.ID> = []
    @Published var expanded: Set<ResultTreeNode.ID> = []
    @Published var isSearching = false
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var summaryText: String?
    @Published var errorMessage: String?
    @Published var showConfirm = false
    @Published var confirmMessage = ""

    private let engine = FileSearchEngine()
    private let trash = TrashService()
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var pendingTrash: [URL] = []
    private var pendingHits: [FileHit] = []
    private var flushTask: Task<Void, Never>?
    private var hitIndex: [String: FileHit] = [:]

    func search() {
        guard query.isValid else {
            errorMessage = FileSearchEngine.SearchError.invalidQuery.localizedDescription
            return
        }

        // Cancel any in-flight search; only this generation may update UI afterward.
        searchTask?.cancel()
        flushTask?.cancel()
        flushTask = nil

        searchGeneration += 1
        let generation = searchGeneration
        let q = query

        isSearching = true
        progress = 0
        statusText = "Searching…"
        summaryText = "Starting…"
        errorMessage = nil
        selection = []
        pendingHits = []
        hitIndex = [:]
        hits = []
        treeRoots = []
        expanded = []

        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.search(
                    query: q,
                    onHits: { [weak self] batch in
                        Task { @MainActor in
                            self?.enqueue(batch, generation: generation)
                        }
                    },
                    progress: { [weak self] update in
                        Task { @MainActor in
                            self?.applyProgress(update, generation: generation)
                        }
                    }
                )
                await MainActor.run {
                    self.finishSearch(generation: generation, cancelled: Task.isCancelled)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.finishSearch(generation: generation, cancelled: true)
                }
            } catch {
                await MainActor.run {
                    guard generation == self.searchGeneration else { return }
                    self.errorMessage = error.localizedDescription
                    self.finishSearch(generation: generation, cancelled: false)
                }
            }
        }
    }

    func stopSearch() {
        searchTask?.cancel()
        flushTask?.cancel()
        flushTask = nil
        // finishSearch runs from the cancelled task with the current generation.
        if isSearching {
            statusText = "Stopping…"
        }
    }

    func expandAll() {
        var ids = Set<ResultTreeNode.ID>()
        for root in treeRoots {
            ids.formUnion(root.allFolderIDs())
        }
        expanded = ids
    }

    func collapseAll() {
        expanded = []
    }

    func selectedURLs() -> [URL] {
        var urls: [URL] = []
        var seen = Set<URL>()
        for root in treeRoots {
            collectSelectedURLs(from: root, into: &urls, seen: &seen)
        }
        return urls
    }

    func revealSelection() {
        FinderReveal.reveal(selectedURLs())
    }

    func openSelection() {
        FinderReveal.open(selectedURLs())
    }

    func copySelectionPaths() {
        let paths = selectedURLs().map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    func trashSelection() async {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        confirmMessage = "Move \(urls.count) item(s) to the Trash?"
        pendingTrash = urls
        showConfirm = true
    }

    func performTrash() async {
        let urls = pendingTrash
        pendingTrash = []
        guard !urls.isEmpty else { return }

        do {
            let result = try await trash.trash(urls: urls)
            let trashed = Set(result.trashed.map { $0.standardizedFileURL.path })
            for path in trashed {
                hitIndex.removeValue(forKey: path)
            }
            hits = Array(hitIndex.values)
            rebuildTree(expandNew: false)
            selection = []
            summaryText = "\(hits.count) results"
            if !result.failed.isEmpty {
                errorMessage = result.failed.map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyProgress(_ update: FileSearchEngine.Progress, generation: Int) {
        guard generation == searchGeneration else { return }
        progress = update.fraction
        statusText = "\(update.message) · \(update.found)"
        summaryText = "\(update.found) found…"
    }

    private func finishSearch(generation: Int, cancelled: Bool) {
        guard generation == searchGeneration else { return }
        flushPending(force: true, generation: generation)
        if cancelled {
            statusText = "Cancelled"
            summaryText = hits.isEmpty ? "Cancelled" : "\(hits.count) results (stopped)"
        } else if hits.count >= FileSearchEngine.resultCap {
            summaryText = "\(hits.count) results (limit reached)"
            statusText = "Done"
        } else {
            summaryText = "\(hits.count) results"
            statusText = "Done"
        }
        isSearching = false
        progress = cancelled ? progress : 1
    }

    private func enqueue(_ batch: [FileHit], generation: Int) {
        guard generation == searchGeneration else { return }
        var added = false
        for hit in batch {
            let key = hit.url.path
            if hitIndex[key] == nil {
                hitIndex[key] = hit
                pendingHits.append(hit)
                added = true
            }
        }
        guard added else { return }

        if flushTask == nil {
            let gen = generation
            flushTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                flushPending(force: false, generation: gen)
                if searchGeneration == gen {
                    flushTask = nil
                }
            }
        }
        if pendingHits.count >= 40 {
            flushPending(force: true, generation: generation)
        }
    }

    private func flushPending(force: Bool, generation: Int) {
        guard generation == searchGeneration else { return }
        guard force || !pendingHits.isEmpty else { return }
        pendingHits.removeAll(keepingCapacity: true)
        hits = Array(hitIndex.values)
        rebuildTree(expandNew: true)
        if isSearching {
            summaryText = "\(hits.count) found…"
        }
    }

    private func rebuildTree(expandNew: Bool) {
        treeRoots = ResultTreeNode.build(
            from: hits,
            searchRoot: query.rootURL,
            rootDisplayName: query.rootPreset == .custom
                ? (query.customRoot.map { ResultTreeNode.displayName(forSearchRoot: $0) })
                : query.rootPreset.rawValue.replacingOccurrences(of: "…", with: "")
        )
        if expandNew {
            var ids = expanded
            for root in treeRoots {
                ids.formUnion(root.allFolderIDs())
            }
            expanded = ids
        }
    }

    private func collectSelectedURLs(
        from node: ResultTreeNode,
        into urls: inout [URL],
        seen: inout Set<URL>
    ) {
        if selection.contains(node.id) {
            // Only the selected node itself — not descendants (Reveal/Open/Trash stay non-recursive).
            let key = node.url.standardizedFileURL
            if seen.insert(key).inserted {
                urls.append(node.url)
            }
            return
        }
        for child in node.children ?? [] {
            collectSelectedURLs(from: child, into: &urls, seen: &seen)
        }
    }
}
