import Foundation

enum RelatedFileCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case preferences = "Preferences"
    case caches = "Caches"
    case applicationSupport = "Application Support"
    case containers = "Containers"
    case groupContainers = "Group Containers"
    case agents = "Launch Agents / Daemons"
    case logs = "Logs"
    case savedState = "Saved Application State"
    case services = "Services"
    case widgets = "Widgets"
    case miscellaneous = "Miscellaneous"

    var id: String { rawValue }

    var isUserDataSensitive: Bool {
        switch self {
        case .applicationSupport, .containers, .groupContainers:
            return true
        default:
            return false
        }
    }
}

struct RelatedFileItem: Identifiable, Hashable, Sendable {
    let id: URL
    let url: URL
    let category: RelatedFileCategory
    let byteSize: Int64
    let isDirectory: Bool
    let isProtected: Bool
    var isSelected: Bool

    var path: String { url.path }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

struct RelatedFileGroup: Identifiable, Hashable {
    let category: RelatedFileCategory
    var items: [RelatedFileItem]

    var id: String { category.id }

    var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.byteSize }
    }

    var selectedCount: Int {
        items.filter(\.isSelected).count
    }
}
