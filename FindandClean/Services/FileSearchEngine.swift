import Foundation
import UniformTypeIdentifiers

/// Thread-safe path deduper for streaming Spotlight + filesystem hits.
private final class HitDeduper: @unchecked Sendable {
    private let lock = NSLock()
    private var paths = Set<String>()

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return paths.count
    }

    func takeNew(_ hits: [FileHit]) -> [FileHit] {
        lock.lock(); defer { lock.unlock() }
        var fresh: [FileHit] = []
        for hit in hits {
            if paths.insert(hit.url.path).inserted {
                fresh.append(hit)
            }
        }
        return fresh
    }
}

actor FileSearchEngine {
    static let resultCap = 25_000

    struct Progress: Sendable {
        var fraction: Double
        var message: String
        var found: Int
    }

    enum SearchError: LocalizedError {
        case invalidQuery
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidQuery:
                return "Enter a name and choose a valid search location."
            case .cancelled:
                return "Search cancelled."
            }
        }
    }

    /// Streams batches of hits as they are found (`onHits`), plus progress updates.
    func search(
        query: SearchQuery,
        onHits: @escaping @Sendable ([FileHit]) -> Void,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        guard query.isValid, let root = query.rootURL else {
            throw SearchError.invalidQuery
        }

        let name = query.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let regex: NSRegularExpression?
        if query.nameMode == .regex {
            do {
                regex = try NSRegularExpression(pattern: name, options: [.caseInsensitive])
            } catch {
                throw SearchError.invalidQuery
            }
        } else {
            regex = nil
        }

        let kindExt = query.kindExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        // Dedup across Spotlight + FS; safe to touch from Spotlight's main-queue callbacks.
        let seen = HitDeduper()
        let roots = Self.expandedRoots(for: root, preset: query.rootPreset)

        // 1) Spotlight (streams gathering updates)
        if query.nameMode != .regex {
            progress(Progress(fraction: 0.05, message: "Spotlight…", found: 0))
            try await Self.spotlightSearch(
                name: name,
                mode: query.nameMode,
                roots: roots,
                kindExt: kindExt,
                query: query,
                onBatch: { batch in
                    let fresh = seen.takeNew(batch)
                    guard !fresh.isEmpty else { return }
                    onHits(fresh)
                    // Only deep-scan real packages (.app / .bundle), never arbitrary folders
                    // (path-wide directory scans were pulling multi‑GB trees like DerivedData).
                    for hit in fresh where Self.isPackage(hit.url) {
                        let nested = Self.deepScanPackage(
                            hit.url,
                            name: name,
                            mode: query.nameMode,
                            regex: regex,
                            kindExt: kindExt,
                            query: query,
                            limit: 500
                        )
                        let nestedFresh = seen.takeNew(nested)
                        if !nestedFresh.isEmpty {
                            onHits(nestedFresh)
                        }
                    }
                    progress(Progress(fraction: 0.2, message: "Spotlight…", found: seen.count))
                }
            )
            progress(Progress(fraction: 0.25, message: "Spotlight done", found: seen.count))
        }

        try Task.checkCancellation()

        // 2) Filesystem walk — Applications first so .app package contents (e.g. BatFiKit_*.bundle) appear quickly
        let rootCount = max(roots.count, 1)
        for (index, fsRoot) in roots.enumerated() {
            try Task.checkCancellation()
            if seen.count >= Self.resultCap { break }

            let base = 0.25 + 0.7 * (Double(index) / Double(rootCount))
            progress(Progress(fraction: base, message: "Scanning \(fsRoot.path)…", found: seen.count))

            try Self.walkFileSystem(
                root: fsRoot,
                name: name,
                mode: query.nameMode,
                regex: regex,
                kindExt: kindExt,
                query: query,
                resultCap: Self.resultCap,
                currentCount: { seen.count },
                onBatch: { batch in
                    let fresh = seen.takeNew(batch)
                    guard !fresh.isEmpty else { return }
                    onHits(fresh)
                    progress(Progress(
                        fraction: min(0.95, base + 0.05),
                        message: "Scanning \(fsRoot.lastPathComponent)…",
                        found: seen.count
                    ))
                }
            )
        }

        progress(Progress(fraction: 1, message: "Done", found: seen.count))
    }

    private static func expandedRoots(for root: URL, preset: SearchRootPreset) -> [URL] {
        let fm = FileManager.default
        switch preset {
        case .macintoshHD:
            // Apps + protected ~/Library folders (Biome, etc.) before a full Home walk.
            // Biome is TCC-gated; a dedicated root is required — a parent Home walk often never surfaces it.
            var candidates: [String] = [
                "/Applications",
                "/System/Volumes/Data/Applications",
                "/Library",
                "/System/Volumes/Data/Library"
            ]
            candidates.append(contentsOf: userLibrarySearchPaths().map(\.path))
            candidates.append(contentsOf: [
                fm.homeDirectoryForCurrentUser.path,
                "/Users",
                "/System/Volumes/Data/Users",
                "/private/var",
                "/private/tmp",
                "/opt",
                "/usr/local"
            ])
            return uniqueExistingDirectories(candidates, fallback: root)
        case .home:
            // Home + explicit Library/Biome roots (same TCC issue).
            var candidates = userLibrarySearchPaths().map(\.path)
            candidates.append(root.resolvingSymlinksInPath().path)
            return uniqueExistingDirectories(candidates, fallback: root)
        case .applications, .custom:
            return [root.resolvingSymlinksInPath()]
        }
    }

    /// TCC-sensitive and common leftover locations under ~/Library that Find Any File routinely hits.
    private static func userLibrarySearchPaths() -> [URL] {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
        let relative = [
            "Biome",
            "Safari",
            "Mail",
            "Accounts",
            "Cookies",
            "Suggestions",
            "IntelligencePlatform",
            "PersonalizationPortrait",
            "DuetExpertCenter",
            "Containers",
            "Group Containers",
            "Application Support",
            "Preferences",
            "Caches",
            "HTTPStorages",
            "WebKit",
            "LaunchAgents",
            "Saved Application State",
            "Logs",
            "Application Scripts"
        ]
        var urls = [library]
        urls.append(contentsOf: relative.map {
            library.appendingPathComponent($0, isDirectory: true)
        })
        return urls
    }

    private static func uniqueExistingDirectories(_ paths: [String], fallback: URL) -> [URL] {
        let fm = FileManager.default
        var unique = Set<String>()
        var urls: [URL] = []
        for path in paths {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            // Do not resolveSymlinksInPath for Library children — can break TCC path identity.
            let key = url.standardizedFileURL.path
            guard unique.insert(key).inserted else { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                urls.append(url)
                continue
            }
            // TCC folders (Biome, Mail, …) often look “missing” without Full Disk Access.
            // Still queue them so a granted-FDA run actually enumerates them.
            let last = url.lastPathComponent
            let protected: Set<String> = [
                "Biome", "Safari", "Mail", "Accounts", "Cookies",
                "Suggestions", "IntelligencePlatform", "PersonalizationPortrait",
                "DuetExpertCenter", "Containers", "Group Containers"
            ]
            if protected.contains(last) || key.contains("/Library/Biome") {
                urls.append(url)
            }
        }
        return urls.isEmpty ? [fallback] : urls
    }

    private static func walkFileSystem(
        root: URL,
        name: String,
        mode: NameMatchMode,
        regex: NSRegularExpression?,
        kindExt: String,
        query: SearchQuery,
        resultCap: Int,
        currentCount: @Sendable () -> Int,
        onBatch: @Sendable ([FileHit]) -> Void
    ) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .creationDateKey
        ]

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return
        }

        var batch: [FileHit] = []
        var visited = 0
        let skipNames: Set<String> = [
            ".Trash", ".Trashes", "Backups.backupdb",
            ".derivedData", "DerivedData", "Index.noindex",
            "Node Modules", "node_modules", ".git", "Pods"
        ]

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            if currentCount() >= resultCap { break }
            visited += 1

            let last = fileURL.lastPathComponent
            if skipNames.contains(last) {
                enumerator.skipDescendants()
                continue
            }
            if last == "Volumes",
               fileURL.deletingLastPathComponent().path == "/"
                || fileURL.deletingLastPathComponent().path == "/System" {
                enumerator.skipDescendants()
                continue
            }

            guard nameMatches(last, needle: name, mode: mode, regex: regex) else {
                continue
            }

            if let hit = makeHit(url: fileURL, kindExt: kindExt, query: query) {
                batch.append(hit)
                // Matching .app/.bundle only — not plain folders (avoids multi‑GB folder walks).
                if isPackage(fileURL) {
                    let nested = deepScanPackage(
                        fileURL,
                        name: name,
                        mode: mode,
                        regex: regex,
                        kindExt: kindExt,
                        query: query,
                        limit: 500
                    )
                    batch.append(contentsOf: nested)
                }
                if batch.count >= 20 || visited % 500 == 0 {
                    onBatch(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
        }

        if !batch.isEmpty {
            onBatch(batch)
        }
    }

    private static func isPackage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["app", "bundle", "framework", "plugin", "appex", "kext"].contains(ext)
    }

    /// Walk inside a package/folder for additional name matches (Find Any File deep coverage).
    private static func deepScanPackage(
        _ packageURL: URL,
        name: String,
        mode: NameMatchMode,
        regex: NSRegularExpression?,
        kindExt: String,
        query: SearchQuery,
        limit: Int
    ) -> [FileHit] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .creationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: keys,
            options: [], // enter nested packages
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var hits: [FileHit] = []
        for case let fileURL as URL in enumerator {
            if fileURL.standardizedFileURL == packageURL.standardizedFileURL { continue }
            let last = fileURL.lastPathComponent
            guard nameMatches(last, needle: name, mode: mode, regex: regex) else { continue }
            if let hit = makeHit(url: fileURL, kindExt: kindExt, query: query) {
                hits.append(hit)
                if hits.count >= limit { break }
            }
        }
        return hits
    }

    private static func spotlightSearch(
        name: String,
        mode: NameMatchMode,
        roots: [URL],
        kindExt: String,
        query: SearchQuery,
        onBatch: @escaping @Sendable ([FileHit]) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let predicate: NSPredicate
            switch mode {
            case .contains:
                // Filename / display name only — never kMDItemPath (that matched every file under
                // a project folder named like the query, e.g. FindandClean/.derivedData → GBs).
                predicate = NSPredicate(
                    format: "(kMDItemFSName CONTAINS[cd] %@) OR (kMDItemDisplayName CONTAINS[cd] %@)",
                    name, name
                )
            case .startsWith:
                predicate = NSPredicate(
                    format: "(kMDItemFSName BEGINSWITH[cd] %@) OR (kMDItemDisplayName BEGINSWITH[cd] %@)",
                    name, name
                )
            case .equals:
                predicate = NSPredicate(
                    format: "(kMDItemFSName ==[cd] %@) OR (kMDItemDisplayName ==[cd] %@)",
                    name, name
                )
            case .regex:
                continuation.resume()
                return
            }

            let mdQuery = NSMetadataQuery()
            mdQuery.predicate = predicate
            if roots.count > 1 {
                mdQuery.searchScopes = [NSMetadataQueryLocalComputerScope]
            } else {
                mdQuery.searchScopes = roots.map(\.path)
            }

            final class Gate: @unchecked Sendable {
                var finished = false
                let lock = NSLock()
                var emitted = Set<String>()
                var observers: [NSObjectProtocol] = []
                var timeout: DispatchWorkItem?
            }
            let gate = Gate()
            let rootPaths = roots.map { $0.standardizedFileURL.path }

            func emitNewResults() {
                var batch: [FileHit] = []
                for item in mdQuery.results {
                    guard let item = item as? NSMetadataItem,
                          let path = item.value(forAttribute: kMDItemPath as String) as? String else {
                        continue
                    }
                    let url = URL(fileURLWithPath: path).standardizedFileURL
                    let itemPath = url.path
                    if roots.count == 1 {
                        let rp = rootPaths[0]
                        guard itemPath == rp || itemPath.hasPrefix(rp + "/") else { continue }
                    }
                    gate.lock.lock()
                    let inserted = gate.emitted.insert(itemPath).inserted
                    gate.lock.unlock()
                    guard inserted else { continue }
                    if let hit = makeHit(url: url, kindExt: kindExt, query: query) {
                        batch.append(hit)
                    }
                }
                if !batch.isEmpty {
                    onBatch(batch)
                }
            }

            func finish() {
                gate.lock.lock()
                defer { gate.lock.unlock() }
                guard !gate.finished else { return }
                gate.finished = true
                for observer in gate.observers {
                    NotificationCenter.default.removeObserver(observer)
                }
                gate.timeout?.cancel()
                mdQuery.stop()
                continuation.resume()
            }

            let updateObs = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidUpdate,
                object: mdQuery,
                queue: .main
            ) { _ in
                emitNewResults()
            }
            let finishObs = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: mdQuery,
                queue: .main
            ) { _ in
                mdQuery.disableUpdates()
                emitNewResults()
                finish()
            }
            gate.observers = [updateObs, finishObs]

            let timeout = DispatchWorkItem {
                mdQuery.disableUpdates()
                emitNewResults()
                finish()
            }
            gate.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)

            DispatchQueue.main.async {
                if !mdQuery.start() {
                    finish()
                }
            }
        }
    }

    private static func makeHit(url: URL, kindExt: String, query: SearchQuery) -> FileHit? {
        let standardized = url.standardizedFileURL
        if standardized.path == "/" || standardized.path == "/System" { return nil }

        let values = try? standardized.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .creationDateKey
        ])
        let isDir = values?.isDirectory ?? standardized.hasDirectoryPath
        let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        let modified = values?.contentModificationDate
        let created = values?.creationDate

        if let minSize = query.minSizeBytes, size < minSize { return nil }
        if let maxSize = query.maxSizeBytes, size > maxSize { return nil }
        if let after = query.modifiedAfter, let modified, modified < after { return nil }
        if let before = query.modifiedBefore, let modified, modified > before { return nil }

        if !kindExt.isEmpty {
            if isDir {
                if kindExt != "folder" && kindExt != "directory" { return nil }
            } else if standardized.pathExtension.lowercased() != kindExt {
                return nil
            }
        }

        return FileHit(
            id: standardized,
            url: standardized,
            byteSize: size,
            modificationDate: modified,
            creationDate: created,
            isDirectory: isDir
        )
    }

    private static func nameMatches(
        _ fileName: String,
        needle: String,
        mode: NameMatchMode,
        regex: NSRegularExpression?
    ) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let stem = (fileName as NSString).deletingPathExtension

        switch mode {
        case .contains:
            return fileName.range(of: needle, options: options) != nil
                || stem.range(of: needle, options: options) != nil
        case .startsWith:
            return fileName.lowercased().hasPrefix(needle.lowercased())
                || stem.lowercased().hasPrefix(needle.lowercased())
        case .equals:
            return fileName.compare(needle, options: options) == .orderedSame
                || stem.compare(needle, options: options) == .orderedSame
        case .regex:
            guard let regex else { return false }
            let range = NSRange(fileName.startIndex..., in: fileName)
            if regex.firstMatch(in: fileName, options: [], range: range) != nil { return true }
            let stemRange = NSRange(stem.startIndex..., in: stem)
            return regex.firstMatch(in: stem, options: [], range: stemRange) != nil
        }
    }
}
