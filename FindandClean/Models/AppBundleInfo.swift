import Foundation

struct AppBundleInfo: Equatable, Sendable {
    let url: URL
    let bundleIdentifier: String?
    let bundleName: String?
    let executableName: String?
    let displayName: String

    var matchNames: [String] {
        var names: [String] = []
        let base = url.deletingPathExtension().lastPathComponent
        names.append(base)
        if let bundleName, !bundleName.isEmpty { names.append(bundleName) }
        if let executableName, !executableName.isEmpty { names.append(executableName) }
        if let displayName = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            names.append(displayName)
        }
        return Array(Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
    }

    var bundleIDFragments: [String] {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return [] }
        var fragments = [bundleIdentifier]
        let parts = bundleIdentifier.split(separator: ".")
        if parts.count >= 2 {
            fragments.append(parts.suffix(2).joined(separator: "."))
        }
        if let last = parts.last {
            fragments.append(String(last))
        }
        return Array(Set(fragments))
    }

    var isAppleOrSystemProtected: Bool {
        if let bundleIdentifier {
            let lower = bundleIdentifier.lowercased()
            if lower.hasPrefix("com.apple.") || lower.hasPrefix("com.apple") {
                return true
            }
        }
        let path = url.path
        if path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/") {
            return true
        }
        return false
    }

    static func load(from url: URL) throws -> AppBundleInfo {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ScannerError.notAnApp(url)
        }
        let ext = url.pathExtension.lowercased()
        guard ext == "app" || Bundle(url: url) != nil else {
            throw ScannerError.notAnApp(url)
        }

        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let plist: [String: Any]
        if let data = try? Data(contentsOf: infoURL),
           let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            plist = obj
        } else if let info = Bundle(url: url)?.infoDictionary {
            plist = info
        } else {
            plist = [:]
        }

        let bundleID = plist["CFBundleIdentifier"] as? String
        let bundleName = plist["CFBundleName"] as? String
        let executable = plist["CFBundleExecutable"] as? String
        let display = (plist["CFBundleDisplayName"] as? String)
            ?? bundleName
            ?? url.deletingPathExtension().lastPathComponent

        return AppBundleInfo(
            url: url,
            bundleIdentifier: bundleID,
            bundleName: bundleName,
            executableName: executable,
            displayName: display
        )
    }
}

enum ScannerError: LocalizedError {
    case notAnApp(URL)
    case protectedApp(String)
    case rootsMissing

    var errorDescription: String? {
        switch self {
        case .notAnApp(let url):
            return "Not an application bundle: \(url.lastPathComponent)"
        case .protectedApp(let name):
            return "“\(name)” is a protected Apple/system app and cannot be cleaned."
        case .rootsMissing:
            return "Scan roots list is missing from the app bundle."
        }
    }
}
