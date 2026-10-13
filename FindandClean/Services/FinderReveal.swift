import AppKit

enum FinderReveal {
    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func open(_ urls: [URL]) {
        for url in urls {
            NSWorkspace.shared.open(url)
        }
    }
}
