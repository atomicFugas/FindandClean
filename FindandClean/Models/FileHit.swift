import Foundation
import UniformTypeIdentifiers

struct FileHit: Identifiable, Hashable, Sendable {
    let id: URL
    let url: URL
    let byteSize: Int64
    let modificationDate: Date?
    let creationDate: Date?
    let isDirectory: Bool

    var path: String { url.path }
    var name: String { url.lastPathComponent }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    var kindLabel: String {
        if isDirectory { return "Folder" }
        if let type = UTType(filenameExtension: url.pathExtension), let desc = type.localizedDescription {
            return desc
        }
        let ext = url.pathExtension
        return ext.isEmpty ? "Document" : ext.uppercased()
    }
}
