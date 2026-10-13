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
        let names = info.matchNames.map { $0.lowercased() }
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

    private func resolveInput(_ url: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) else {
            throw ScannerError.notAnApp(url)
        }
        if resolved.pathExtension.lowercased() == "app" {
            return resolved
        }
        // Allow dropping a directory that contains Contents/Info.plist
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

        let rootPath = root.url.path
        let rootDepth = root.url.pathComponents.count

        for case let fileURL as URL in enumerator {
            let depth = fileURL.pathComponents.count - rootDepth
            if depth > root.maxDepth {
                enumerator.skipDescendants()
                continue
            }

            // Never match the dropped app path again under roots.
            if fileURL.path == appPath { continue }

            let name = fileURL.lastPathComponent.lowercased()
            let matched: Bool
            switch root.matchMode {
            case .bundleID:
                matched = idFragments.contains { fragment in
                    !fragment.isEmpty && name.contains(fragment)
                } || names.contains { name == $0 || name.hasPrefix($0 + ".") || name.hasPrefix($0 + "-") }
            case .name:
                matched = matchesName(name, names: names, idFragments: idFragments)
            }

            if matched {
                let defaultSelected = !root.category.isUserDataSensitive
                if let item = makeItem(url: fileURL, category: root.category, defaultSelected: defaultSelected) {
                    results.append(item)
                }
                // Don't descend into matched containers/folders — treat as one unit.
                var isDirectory = false
                if let vals = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]), vals.isDirectory == true {
                    isDirectory = true
                }
                if isDirectory {
                    enumerator.skipDescendants()
                }
            }
        }

        // Also scan immediate children of the root if maxDepth >= 1 and nothing deep needed
        _ = rootPath
        return results
    }

    private func matchesName(_ name: String, names: [String], idFragments: [String]) -> Bool {
        for n in names where !n.isEmpty {
            if name == n { return true }
            if name.hasPrefix(n + ".") { return true }
            if name.hasPrefix(n + "-") { return true }
            if name.contains(n) && n.count >= 3 { return true }
            // Preferences often: com.vendor.app.plist
            if name.hasSuffix(".plist") {
                let base = String(name.dropLast(5))
                if base == n || base.hasSuffix("." + n) || base.contains(n) { return true }
            }
            if name.hasSuffix(".savedstate") || name.hasSuffix(".savedState".lowercased()) {
                if name.contains(n) { return true }
            }
        }
        for fragment in idFragments where fragment.count >= 3 {
            if name.contains(fragment) { return true }
            if name.hasSuffix(".plist") && String(name.dropLast(5)).contains(fragment) { return true }
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
            size = directorySize(url)
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
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        var count = 0
        for case let fileURL as URL in enumerator {
            count += 1
            if count > 50_000 { break } // safety cap for huge trees
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
