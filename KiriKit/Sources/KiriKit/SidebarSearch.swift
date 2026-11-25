import Foundation

/// Find in the folder sidebar (⌘F while the sidebar has the keyboard):
/// which files and folders a query finds, in the order the sidebar shows
/// them, and which of them comes next from a row, going round at the ends.
///
/// Everything is a path from the folder the sidebar shows
/// ("Sources/Tidepool/Greeter.swift"), with whether it is a folder. A
/// query matches a name, never the folders above it, letter case and
/// accents aside: "greet" finds Greeter.swift, "cafe" finds Café.md.
///
/// A folder can have 20 000 files (`FolderIndex.limit`), and a query is
/// looked for at every key: the entries are put in order once (`ordered`),
/// and a query only picks from them (`find(_:inOrdered:)`).
public enum SidebarSearch {
    /// A file or folder under the sidebar's folder.
    public struct Entry: Hashable, Sendable {
        /// From the sidebar's folder, "/" between the names, no "/" at
        /// either end.
        public let path: String
        public let isFolder: Bool
        /// The names along the path, the row's own last.
        let components: [Substring]

        public init(path: String, isFolder: Bool) {
            self.path = path
            self.isFolder = isFolder
            components = path.split(separator: "/")
        }

        /// The last name of the path: what the row shows.
        public var name: Substring { components.last ?? Substring(path) }

        public static func == (a: Entry, b: Entry) -> Bool { a.path == b.path && a.isFolder == b.isFolder }
        public func hash(into hasher: inout Hasher) { hasher.combine(path) }
    }

    /// Whether `name` has `query` in it, as Finder's search would put it:
    /// letter case and accents aside. An empty query finds nothing.
    public static func matches<S: StringProtocol>(_ name: S, query: String) -> Bool {
        guard !query.isEmpty else { return false }
        #if canImport(Darwin)
        return name.localizedStandardContains(query)
        #else
        return name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        #endif
    }

    /// The entries in the sidebar's order (`inTreeOrder`), each path once.
    ///
    /// The paths are put in a tree first and each folder's names sorted
    /// on their own, then read top to bottom: a name is only ever compared
    /// with the others in its folder, not every path with every other, so
    /// 20 000 files take a fraction of what one big sort by `inTreeOrder`
    /// would. The order is the same.
    public static func ordered(_ entries: [Entry]) -> [Entry] {
        let root = TreeNode(name: "", isFolder: true)
        var seen = Set<String>()
        for entry in entries where seen.insert(entry.path).inserted {
            var node = root
            for (i, name) in entry.components.enumerated() {
                let last = i == entry.components.count - 1
                node = node.child(name, isFolder: !last || entry.isFolder)
            }
            node.entry = entry
        }
        var out: [Entry] = []
        out.reserveCapacity(entries.count)
        func walk(_ node: TreeNode) {
            if let entry = node.entry { out.append(entry) }
            for child in node.sortedChildren() { walk(child) }
        }
        walk(root)
        return out
    }

    /// A name in the tree `ordered` reads: an entry's own, or a folder
    /// above entries that may not be one itself.
    private final class TreeNode {
        let name: Substring
        let isFolder: Bool
        var entry: Entry?
        private var children: [Key: TreeNode] = [:]

        private struct Key: Hashable {
            let name: Substring
            let isFolder: Bool
        }

        init(name: Substring, isFolder: Bool) {
            self.name = name
            self.isFolder = isFolder
        }

        func child(_ name: Substring, isFolder: Bool) -> TreeNode {
            let key = Key(name: name, isFolder: isFolder)
            if let node = children[key] { return node }
            let node = TreeNode(name: name, isFolder: isFolder)
            children[key] = node
            return node
        }

        /// Folders first, then files, each by name as `inTreeOrder` has them.
        func sortedChildren() -> [TreeNode] {
            children.values.sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                switch SidebarSearch.compare(a.name, b.name) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return a.name < b.name
                }
            }
        }
    }

    /// The entries of `ordered` (in the sidebar's order already) whose
    /// names have `query` in them, in that order.
    public static func find(_ query: String, inOrdered ordered: [Entry]) -> [Entry] {
        guard !query.isEmpty else { return [] }
        return ordered.filter { matches($0.name, query: query) }
    }

    /// The entries whose names have `query` in them, each once, in the
    /// sidebar's order.
    public static func find(_ query: String, in entries: [Entry]) -> [Entry] {
        guard !query.isEmpty else { return [] }
        return ordered(entries.filter { matches($0.name, query: query) })
    }

    /// Two lists in the sidebar's order as one, each path once.
    public static func merged(_ a: [Entry], _ b: [Entry]) -> [Entry] {
        var out: [Entry] = []
        out.reserveCapacity(a.count + b.count)
        var seen = Set<String>()
        var i = 0, j = 0
        while i < a.count || j < b.count {
            let next: Entry
            if j == b.count || i < a.count && !inTreeOrder(b[j], a[i]) {
                next = a[i]
                i += 1
            } else {
                next = b[j]
                j += 1
            }
            if seen.insert(next.path).inserted { out.append(next) }
        }
        return out
    }

    /// Every folder above the files at `paths` ("a/b/c.txt" has "a" and
    /// "a/b"), each once: the folders a list of files alone leaves out.
    public static func folders(above paths: [String]) -> [String] {
        var seen = Set<Substring>()
        var folders: [String] = []
        for path in paths {
            var end = path.startIndex
            while let slash = path[end...].firstIndex(of: "/") {
                let folder = path[..<slash]
                if seen.insert(folder).inserted { folders.append(String(folder)) }
                end = path.index(after: slash)
            }
        }
        return folders
    }

    /// Whether `a` comes before `b` in the sidebar: a folder before what
    /// is in it, and among the things in one folder the folders first,
    /// then the files, each by name as Finder sorts them
    /// (`localizedStandardCompare`), "file2" before "file10".
    public static func inTreeOrder(_ a: Entry, _ b: Entry) -> Bool {
        let x = a.components, y = b.components
        for i in 0..<min(x.count, y.count) where x[i] != y[i] {
            // Something deeper down is inside a folder.
            let xFolder = i < x.count - 1 || a.isFolder
            let yFolder = i < y.count - 1 || b.isFolder
            if xFolder != yFolder { return xFolder }
            switch compare(x[i], y[i]) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            // Names only Finder's order calls the same ("a" and "A"): by their letters.
            case .orderedSame: return x[i] < y[i]
            }
        }
        // One is the other, or a folder holding it: the folder first.
        return x.count < y.count
    }

    /// The names as the sidebar sorts them.
    private static func compare(_ a: Substring, _ b: Substring) -> ComparisonResult {
        #if canImport(Darwin)
        return a.localizedStandardCompare(b)
        #else
        return a.compare(b, options: [.caseInsensitive, .numeric, .widthInsensitive])
        #endif
    }

    /// Which way to look from a row.
    public enum Direction: Sendable {
        /// The row itself if it is found, else the next found below it:
        /// where typing a query goes.
        case atOrAfter
        /// The next found below the row (⌘G).
        case after
        /// The next found above the row (⇧⌘G).
        case before
    }

    /// The position in `found` (in the sidebar's order) to go to from the
    /// row `from`, which need not be one of them, going round at the
    /// ends. With no row, the first (or, going up, the last). Nil when
    /// nothing is found.
    public static func index(in found: [Entry], from: Entry?, _ direction: Direction) -> Int? {
        guard !found.isEmpty else { return nil }
        guard let from else { return direction == .before ? found.count - 1 : 0 }
        switch direction {
        case .atOrAfter:
            return found.firstIndex { !inTreeOrder($0, from) } ?? 0
        case .after:
            return found.firstIndex { inTreeOrder(from, $0) } ?? 0
        case .before:
            return found.lastIndex { inTreeOrder($0, from) } ?? found.count - 1
        }
    }
}
