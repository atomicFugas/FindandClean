import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct DropZoneView: View {
    var isScanning: Bool
    var onDrop: ([URL]) -> Void

    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                )

            VStack(spacing: 8) {
                Image(systemName: "app.dashed")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                Text("Drop apps here")
                    .font(.headline)
                Text("Drop a .app to find related leftover files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Choose App…") {
                    chooseApp()
                }
                .disabled(isScanning)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task { await handleDrop(providers) }
            return true
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application, .applicationBundle, .directory]
        panel.message = "Choose an application to scan for leftovers"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            onDrop([url])
        }
    }

    @MainActor
    private func handleDrop(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadURL(from: provider) {
                urls.append(url)
            }
        }
        if !urls.isEmpty {
            onDrop(urls)
        }
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
