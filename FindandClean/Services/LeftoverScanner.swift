import Foundation

actor LeftoverScanner {
    struct Progress: Sendable {
        var fraction: Double
        var message: String
    }

    private struct RootSpec {
        let url: URL
        let category: RelatedFileCategory
        let maxDepth: Int
        let matchMode: MatchMode
    }

    private enum MatchMode: String {
        case name
        case bundleID
    }

    /// Hard cap so one false-positive folder can't report multi‑GB "leftovers".
    private static let maxReportedDirectoryBytes: Int64 = 2_000_000_000 // 2 GB
    private static let maxDirectoryFileVisits = 8_000

    func scan(
        appURL: URL,
        progress: @Sendable (Progress) -> Void
    ) async throws -> [RelatedFileItem] {
        let resolved = try resolveInput(appURL)
        let info = try AppBundleInfo.load(from: resolved)

        if info.isAppleOrSystemProtected {
            throw ScannerError.protectedApp(info.displayName)
        }

        let roots = try loadRoots()
        var found: [URL: RelatedFileItem] = [:]
        let names = info.matchNames
            .map { $0.lowercased() }
            .filter { $0.count >= 3 && !Self.genericNameTokens.contains($0) }
        let idFragments = info.bundleIDFragments.map { $0.lowercased() }

        for (index, root) in roots.enumerated() {
            try Task.checkCancellation()
            let frac = Double(index) / Double(max(roots.count, 1))
            progress(Progress(fraction: frac, message: "Scanning \(root.url.lastPathComponent)…"))

            let hits = walk(
                root: root,
                names: names,
                idFragments: idFragments,
                appPath: info.url.path
            )
            for item in hits {
                if found[item.url] == nil {
                    found[item.url] = item
                }
            }
        }

        // Also include the app itself as a selected item under Miscellaneous.
        if let appItem = makeItem(url: info.url, category: .miscellaneous, defaultSelected: true) {
            found[appItem.url] = appItem
        }

        progress(Progress(fraction: 1, message: "Done"))
        return found.values.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private static let genericNameTokens: Set<String> = [
        "app", "apps", "helper", "agent", "service", "mac", "osx", "desktop"
    ]

    private func resolveInput(_ url: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) else {
            throw ScannerError.notAnApp(url)
        }
        if resolved.pathExtension.lowercased() == "app" {
            return resolved
        }
        let info = resolved.appendingPathComponent("Contents/Info.plist")
        if FileManager.default.fileExists(atPath: info.path) {
            return resolved
        }
        throw ScannerError.notAnApp(url)
    }

    private func loadRoots() throws -> [RootSpec] {
        guard let plistURL = Bundle.main.url(forResource: "ScanRoots", withExtension: "plist"),
              let data = try? Data(contentsOf: plistURL),
              let array = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else {
            throw ScannerError.rootsMissing
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return array.compactMap { dict in
            guard var path = dict["path"] as? String,
                  let categoryRaw = dict["category"] as? String else { return nil }
            if path.hasPrefix("~/") {
                path = home + String(path.dropFirst(1))
            } else if path == "~" {
                path = home
            }
            let category = category(from: categoryRaw)
            let depth = dict["maxDepth"] as? Int ?? 2
            let mode = MatchMode(rawValue: (dict["matchMode"] as? String) ?? "name") ?? .name
            return RootSpec(
                url: URL(fileURLWithPath: path, isDirectory: true),
                category: category,
                maxDepth: depth,
                matchMode: mode
            )
        }
    }

    private func category(from raw: String) -> RelatedFileCategory {
        switch raw {
        case "preferences": return .preferences
        case "caches": return .caches
        case "applicationSupport": return .applicationSupport
        case "containers": return .containers
        case "groupContainers": return .groupContainers
        case "agents": return .agents
        case "logs": return .logs
        case "savedState": return .savedState
        case "services": return .services
        case "widgets": return .widgets
        default: return .miscellaneous
        }
    }

    private func walk(
        root: RootSpec,
        names: [String],
        idFragments: [String],
        appPath: String
    ) -> [RelatedFileItem] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.url.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var results: [RelatedFileItem] = []
        guard let enumerator = fm.enumerator(
            at: root.url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let rootDepth = root.url.pathComponents.count
        let rootName = root.url.lastPathComponent.lowercased()

        for case let fileURL as URL in enumerator {
            let depth = fileURL.pathComponents.count - rootDepth
            // Never treat the scan root itself as a leftover (e.g. "Application Support" ≠ app).
            if depth == 0 { continue }
            if depth > root.maxDepth {
                enumerator.skipDescendants()
                continue
            }

            if fileURL.path == appPath { continue }

            let name = fileURL.lastPathComponent.lowercased()
            // Guard against matching the parent folder name again if enumerator yields it.
            if name == rootName { continue }

            let matched: Bool
            switch root.matchMode {
            case .bundleID:
                matched = idFragments.contains { fragment in
                    guard fragment.count >= 4 else { return false }
                    return name == fragment
                        || name.hasPrefix(fragment + ".")
                        || name.hasPrefix(fragment + "-")
                        || name.contains(fragment)
                } || names.contains {
                    name == $0 || name.hasPrefix($0 + ".") || name.hasPrefix($0 + "-")
                }
            case .name:
                matched = matchesName(name, names: names, idFragments: idFragments)
            }

            if matched {
                let defaultSelected = !root.category.isUserDataSensitive
                if let item = makeItem(url: fileURL, category: root.category, defaultSelected: defaultSelected) {
                    results.append(item)
                }
                var isDirectory = false
                if let vals = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]), vals.isDirectory == true {
                    isDirectory = true
                }
                if isDirectory {
                    enumerator.skipDescendants()
                }
            }
        }

        return results
    }

    private func matchesName(_ name: String, names: [String], idFragments: [String]) -> Bool {
        for n in names where n.count >= 3 {
            if name == n { return true }
            if name.hasPrefix(n + ".") { return true }
            if name.hasPrefix(n + "-") { return true }
            // Require longer tokens for loose "contains" to avoid "app" / "mac" style false positives.
            if n.count >= 5, name.contains(n) { return true }
            if name.hasSuffix(".plist") {
                let base = String(name.dropLast(5))
                if base == n || base.hasSuffix("." + n) { return true }
                if n.count >= 5, base.contains(n) { return true }
            }
            if name.hasSuffix(".savedstate"), n.count >= 5, name.contains(n) {
                return true
            }
        }
        for fragment in idFragments where fragment.count >= 4 {
            if name == fragment || name.hasPrefix(fragment + ".") || name.hasPrefix(fragment + "-") {
                return true
            }
            if name.contains(fragment) { return true }
            if name.hasSuffix(".plist") {
                let base = String(name.dropLast(5))
                if base == fragment || base.hasSuffix("." + fragment) || base.contains(fragment) {
                    return true
                }
            }
        }
        return false
    }

    private func makeItem(url: URL, category: RelatedFileCategory, defaultSelected: Bool) -> RelatedFileItem? {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey
        ])
        let isDir = values?.isDirectory ?? false
        let size: Int64
        if isDir {
            size = min(directorySize(url), Self.maxReportedDirectoryBytes)
        } else {
            size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        let protected = url.path.hasPrefix("/System/") || url.path.contains("/Library/Apple/")
        return RelatedFileItem(
            id: url,
            url: url,
            category: category,
            byteSize: size,
            isDirectory: isDir,
            isProtected: protected,
            isSelected: defaultSelected && !protected
        )
    }

    private func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var total: Int64 = 0
        var count = 0
        for case let fileURL as URL in enumerator {
            count += 1
            if count > Self.maxDirectoryFileVisits { break }
            if total >= Self.maxReportedDirectoryBytes { break }
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
