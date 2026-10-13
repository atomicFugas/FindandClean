import Foundation

enum NameMatchMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case contains = "Contains"
    case startsWith = "Starts with"
    case equals = "Equals"
    case regex = "Regex"

    var id: String { rawValue }
}

enum SearchRootPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case home = "Home"
    case macintoshHD = "Macintosh HD"
    case applications = "Applications"
    case custom = "Custom…"

    var id: String { rawValue }

    func resolvedURL(custom: URL?) -> URL? {
        switch self {
        case .home:
            return FileManager.default.homeDirectoryForCurrentUser
        case .macintoshHD:
            return URL(fileURLWithPath: "/", isDirectory: true)
        case .applications:
            return URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .custom:
            return custom
        }
    }
}

struct SearchQuery: Equatable, Sendable {
    var name: String = ""
    var nameMode: NameMatchMode = .contains
    var rootPreset: SearchRootPreset = .macintoshHD
    var customRoot: URL? = nil
    var minSizeBytes: Int64? = nil
    var maxSizeBytes: Int64? = nil
    var modifiedAfter: Date? = nil
    var modifiedBefore: Date? = nil
    var kindExtension: String = ""

    var rootURL: URL? {
        rootPreset.resolvedURL(custom: customRoot)
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && rootURL != nil
    }
}
