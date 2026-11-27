import Foundation

/// What a change on disk means for a folder window: the folder sidebar
/// and its index (`FolderIndex`) follow files made, renamed and deleted
/// outside Kiri. macOS says which folders had something change in them
/// (FSEvents), as paths; these say where under the window's folder each
/// one is, and whether the index has to read the folder again for it.
public enum FolderChanges {
    /// The names from `root` down to `path`, [] for `root` itself, or nil
    /// for a path that isn't in `root` (a folder above it, or elsewhere).
    /// A "/" at either end is no matter, and letter case isn't either:
    /// the disks Macs start from don't tell "Notes" from "notes", and a
    /// folder read again for nothing costs little.
    public static func names(of path: String, under root: String) -> [String]? {
        let rootNames = root.split(separator: "/")
        let names = path.split(separator: "/")
        guard names.count >= rootNames.count else { return nil }
        for (name, rootName) in zip(names, rootNames) where name != rootName {
            guard name.caseInsensitiveCompare(rootName) == .orderedSame else { return nil }
        }
        return names.dropFirst(rootNames.count).map(String.init)
    }

    /// The index reads every folder under the root but the `skipped` ones
    /// (version control, packages, builds), so a change in one of those,
    /// at any depth, leaves it as it is. Build tools and `git` write there
    /// all the time.
    public static func reachesIndex(_ names: [String], skipping skipped: Set<String>) -> Bool {
        !names.contains { skipped.contains($0) }
    }
}
