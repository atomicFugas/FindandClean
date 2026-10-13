import Foundation

/// Hierarchical node for search results. Intermediate folders may not be hits themselves.
final class ResultTreeNode: Identifiable, Hashable {
    let id: URL
    let name: String
    let url: URL
    let hit: FileHit?
    /// Modification date from the filesystem (for path folders that aren't hits).
    let folderModificationDate: Date?
    var children: [ResultTreeNode]?

    init(
        url: URL,
        hit: FileHit? = nil,
        folderModificationDate: Date? = nil,
        children: [ResultTreeNode]? = nil,
        displayName: String? = nil
    ) {
        let standardized = url.standardizedFileURL
        self.id = standardized
        self.url = standardized
        if let displayName, !displayName.isEmpty {
            self.name = displayName
        } else {
            let last = standardized.lastPathComponent
            self.name = last.isEmpty || last == "/" ? "Macintosh HD" : last
        }
        self.hit = hit
        self.folderModificationDate = folderModificationDate ?? Self.readModificationDate(standardized)
        self.children = children
    }

    var isDirectoryNode: Bool {
        if let children, !children.isEmpty { return true }
        return hit?.isDirectory ?? true
    }

    var matchCount: Int {
        if hit != nil, children == nil || children?.isEmpty == true {
            return 1
        }
        let childCount = (children ?? []).reduce(0) { $0 + $1.matchCount }
        return max(childCount, hit != nil && childCount == 0 ? 1 : childCount)
    }

    /// Prefer the node's own date; folders fall back to newest descendant hit.
    var modificationDate: Date? {
        if let hitDate = hit?.modificationDate { return hitDate }
        if let folderModificationDate { return folderModificationDate }
        return allHits().compactMap(\.modificationDate).max()
    }

    func allHits() -> [FileHit] {
        var result: [FileHit] = []
        if let hit { result.append(hit) }
        for child in children ?? [] {
            result.append(contentsOf: child.allHits())
        }
        return result
    }

    func allURLs() -> [URL] {
        allHits().map(\.url)
    }

    func allFolderIDs() -> Set<URL> {
        var ids = Set<URL>()
        if let children, !children.isEmpty {
            ids.insert(id)
            for child in children {
                ids.formUnion(child.allFolderIDs())
            }
        }
        return ids
    }

    static func == (lhs: ResultTreeNode, rhs: ResultTreeNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Builds a tree rooted at `searchRoot` so the full path is visible under the main root.
    static func build(
        from hits: [FileHit],
        searchRoot: URL?,
        rootDisplayName: String? = nil
    ) -> [ResultTreeNode] {
        guard !hits.isEmpty else { return [] }

        let anchor = (searchRoot ?? URL(fileURLWithPath: "/")).standardizedFileURL
        let rootName = rootDisplayName ?? displayName(forSearchRoot: anchor)
        let root = ResultTreeNode(url: anchor, children: [], displayName: rootName)

        for hit in hits {
            insert(hit: hit, under: root, searchRoot: anchor)
        }

        sortRecursively(root)

        let kids = (root.children ?? []).filter { $0.hit != nil || !($0.children ?? []).isEmpty }
        root.children = kids.isEmpty ? nil : kids
        // Always keep the main “Find from” root so the tree shows the full path.
        return [root]
    }

    static func displayName(forSearchRoot url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path == "/" { return "Macintosh HD" }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home { return "Home" }
        if path == "/Applications" { return "Applications" }
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? path : last
    }

    private static func insert(hit: FileHit, under root: ResultTreeNode, searchRoot: URL) {
        let hitURL = hit.url.standardizedFileURL
        var components = hitURL.pathComponents
        if components.first == "/" {
            components.removeFirst()
        }

        // Drop path segments that belong to the search root so the tree starts there.
        let rootComponents = searchRoot.pathComponents.filter { $0 != "/" }
        if !rootComponents.isEmpty,
           components.starts(with: rootComponents) {
            components = Array(components.dropFirst(rootComponents.count))
        }

        // Hit is exactly the search root.
        if components.isEmpty {
            root.children = mergeHit(hit, into: root.children ?? [], url: hitURL)
            return
        }

        var current = root
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let nextURL: URL = {
                if isLast { return hitURL }
                return current.url.appendingPathComponent(component, isDirectory: true).standardizedFileURL
            }()

            if isLast {
                current.children = mergeHit(hit, into: current.children ?? [], url: nextURL)
            } else {
                if let idx = current.children?.firstIndex(where: { $0.name == component }) {
                    if current.children?[idx].children == nil {
                        let existing = current.children![idx]
                        current.children?[idx] = ResultTreeNode(
                            url: existing.url,
                            hit: existing.hit,
                            folderModificationDate: existing.folderModificationDate,
                            children: []
                        )
                    }
                    current = current.children![idx]
                } else {
                    let folder = ResultTreeNode(url: nextURL, hit: nil, children: [])
                    if current.children == nil { current.children = [] }
                    current.children?.append(folder)
                    current = folder
                }
            }
        }
    }

    private static func mergeHit(_ hit: FileHit, into kids: [ResultTreeNode], url: URL) -> [ResultTreeNode] {
        var kids = kids
        if let idx = kids.firstIndex(where: { $0.id == url.standardizedFileURL }) {
            let existingKids = kids[idx].children
            kids[idx] = ResultTreeNode(
                url: hit.url,
                hit: hit,
                folderModificationDate: hit.modificationDate,
                children: existingKids
            )
        } else {
            kids.append(ResultTreeNode(url: hit.url, hit: hit, children: nil))
        }
        return kids
    }

    private static func sortRecursively(_ node: ResultTreeNode) {
        guard var kids = node.children, !kids.isEmpty else { return }
        kids.sort { a, b in
            if a.isDirectoryNode != b.isDirectoryNode {
                return a.isDirectoryNode && !b.isDirectoryNode
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        node.children = kids
        for kid in kids {
            sortRecursively(kid)
        }
    }

    private static func readModificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
