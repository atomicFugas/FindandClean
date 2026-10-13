import Foundation
import SwiftUI

@MainActor
final class UninstallViewModel: ObservableObject {
    @Published var groups: [RelatedFileGroup] = []
    @Published var isScanning = false
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var summaryText: String?
    @Published var errorMessage: String?
    @Published var showConfirm = false
    @Published var confirmMessage = ""
    @Published var showProtectedAlert = false
    @Published var protectedMessage = ""

    private let scanner = LeftoverScanner()
    private let trash = TrashService()
    private var pendingRemoval: [RelatedFileItem] = []
    private var scanTask: Task<Void, Never>?

    var canRemove: Bool {
        !isScanning && groups.contains { $0.items.contains { $0.isSelected && !$0.isProtected } }
    }

    func reset() {
        scanTask?.cancel()
        scanTask = nil
        groups = []
        isScanning = false
        progress = 0
        statusText = ""
        summaryText = nil
        errorMessage = nil
        showConfirm = false
        confirmMessage = ""
        showProtectedAlert = false
        protectedMessage = ""
        pendingRemoval = []
    }

    func scan(urls: [URL]) async {
        guard let first = urls.first else { return }
        scanTask?.cancel()
        isScanning = true
        progress = 0
        statusText = "Reading app…"
        summaryText = nil
        groups = []
        errorMessage = nil

        scanTask = Task {
            do {
                let items = try await scanner.scan(appURL: first) { [weak self] update in
                    Task { @MainActor in
                        self?.progress = update.fraction
                        self?.statusText = update.message
                    }
                }
                guard !Task.isCancelled else { return }
                apply(items: items)
            } catch is CancellationError {
                statusText = "Cancelled"
            } catch let error as ScannerError {
                if case .protectedApp(let name) = error {
                    protectedMessage = error.localizedDescription
                    showProtectedAlert = true
                    _ = name
                } else {
                    errorMessage = error.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isScanning = false
        }
        await scanTask?.value
    }

    func toggle(id: RelatedFileItem.ID, selected: Bool) {
        for g in groups.indices {
            if let idx = groups[g].items.firstIndex(where: { $0.id == id }) {
                groups[g].items[idx].isSelected = selected
                break
            }
        }
        refreshSummary()
    }

    func toggleCategory(_ category: RelatedFileCategory, selected: Bool) {
        for g in groups.indices where groups[g].category == category {
            for i in groups[g].items.indices where !groups[g].items[i].isProtected {
                groups[g].items[i].isSelected = selected
            }
        }
        refreshSummary()
    }

    func removeChecked() async {
        let selected = groups.flatMap(\.items).filter { $0.isSelected && !$0.isProtected }
        guard !selected.isEmpty else { return }

        let sensitive = selected.filter { $0.category.isUserDataSensitive }
        let total = selected.reduce(Int64(0)) { $0 + $1.byteSize }
        let sizeText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)

        if !sensitive.isEmpty {
            confirmMessage = "Move \(selected.count) item(s) (\(sizeText)) to Trash?\n\nThis includes \(sensitive.count) Application Support / Container item(s) that may contain user data."
        } else {
            confirmMessage = "Move \(selected.count) item(s) (\(sizeText)) to the Trash?"
        }
        pendingRemoval = selected
        showConfirm = true
    }

    func performRemoval() async {
        let selected = pendingRemoval
        pendingRemoval = []
        guard !selected.isEmpty else { return }

        do {
            let result = try await trash.trash(urls: selected.map(\.url))
            let trashedSet = Set(result.trashed)
            for g in groups.indices {
                groups[g].items.removeAll { trashedSet.contains($0.url) }
            }
            groups.removeAll { $0.items.isEmpty }
            refreshSummary()

            if !result.failed.isEmpty {
                errorMessage = result.failed.map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(items: [RelatedFileItem]) {
        let dict = Dictionary(grouping: items, by: \.category)
        groups = RelatedFileCategory.allCases.compactMap { category in
            guard let list = dict[category], !list.isEmpty else { return nil }
            return RelatedFileGroup(category: category, items: list)
        }
        refreshSummary()
    }

    private func refreshSummary() {
        let all = groups.flatMap(\.items)
        guard !all.isEmpty else {
            summaryText = nil
            return
        }
        let total = all.reduce(Int64(0)) { $0 + $1.byteSize }
        let checked = all.filter(\.isSelected).count
        let sizeText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        summaryText = "\(all.count) files • \(sizeText) • \(checked) checked"
    }
}
