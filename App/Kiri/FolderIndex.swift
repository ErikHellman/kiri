import Foundation
import KiriKit
import Observation

/// Every file under a folder window's folder, for the command palette and
/// for find in the sidebar (`SidebarFind`): the tree shows one folder at a
/// time, and they find a file anywhere under it by a few letters of its name.
///
/// The folder is read off the main thread, and what was read before stays
/// in use until the new reading is in: typing never waits for the disk.
/// It is read again when the palette or the sidebar's find opens and when the folder session
/// refreshes (a file made or renamed in the sidebar, View ▸ Refresh Folder).
@Observable final class FolderIndex {
    let root: URL

    /// The files, as paths from the folder ("Sources/Tidepool/Greeter.swift"),
    /// nearest the top first, and the same prepared for matching.
    private(set) var paths: [String] = []
    @ObservationIgnored private(set) var candidates: [FuzzyCandidate] = []
    /// The folder has more files than are kept (`limit`).
    private(set) var isCut = false
    /// A first reading is under way and there is nothing to show yet.
    private(set) var isReading = false

    /// Posted (with the index as its object) when a reading is in.
    static let didChange = Notification.Name("KiriFolderIndexDidChange")

    /// The most files that are kept: a folder with more is a folder to
    /// open a part of.
    nonisolated static let limit = 20_000

    /// Folders nobody opens a file in by hand: version control, packages
    /// fetched by a tool, and what a build leaves behind.
    nonisolated static let skippedFolders: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", "build", "DerivedData", "Pods", ".swiftpm", ".gradle", ".idea",
        "__pycache__", ".venv", ".next", ".cache",
    ]
    nonisolated static let skippedFiles: Set<String> = [".DS_Store"]

    @ObservationIgnored private var reading: Reading?
    /// The folder has been read at least once (`paths` is what was found).
    @ObservationIgnored private(set) var hasRead = false

    /// Says whether a reading is still wanted.
    nonisolated private final class Reading: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// The file at one of `paths`.
    func url(for path: String) -> URL { root.appendingPathComponent(path).standardizedFileURL }

    /// Reads the folder again if it has been read before: an index
    /// nobody has asked for is not kept up.
    func refreshIfInUse() {
        if hasRead || reading != nil { refresh() }
    }

    /// Reads the folder again, off the main thread. A reading that is
    /// under way is given up for the new one.
    func refresh() {
        reading?.cancel()
        let reading = Reading()
        self.reading = reading
        if !hasRead { isReading = true }
        let root = root
        DispatchQueue.global(qos: .userInitiated).async {
            guard let found = Self.read(root, isCancelled: { reading.isCancelled }) else { return }
            let candidates = found.paths.map { FuzzyCandidate($0, isPath: true) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.reading === reading, !reading.isCancelled else { return }
                    self.reading = nil
                    self.hasRead = true
                    self.isReading = false
                    self.candidates = candidates
                    if self.paths != found.paths { self.paths = found.paths }
                    if self.isCut != found.cut { self.isCut = found.cut }
                    NotificationCenter.default.post(name: Self.didChange, object: self)
                }
            }
        }
    }

    /// The files under `root`, a folder at a time from the top, so that a
    /// folder too big to keep whole is cut in its depths and not after
    /// its first deep branch. Folders and files are in name order; a
    /// package (an app, a bundle) is not looked into, nor a link to a
    /// folder followed.
    nonisolated static func read(_ root: URL, limit: Int = FolderIndex.limit,
                                 isCancelled: () -> Bool = { false }) -> (paths: [String], cut: Bool)? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        var paths: [String] = []
        var folders: [(url: URL, path: String)] = [(root, "")]
        var next = 0
        while next < folders.count {
            if isCancelled() { return nil }
            let (folder, prefix) = folders[next]
            next += 1
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
            var files: [String] = []
            var inside: [(url: URL, path: String)] = []
            for item in items {
                let name = item.lastPathComponent
                let values = try? item.resourceValues(forKeys: Set(keys))
                // A link to a file is a file; a link to a folder is not followed.
                if values?.isSymbolicLink == true {
                    let target = try? item.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey])
                    if target?.isDirectory != false { continue }
                }
                if values?.isDirectory == true, values?.isPackage != true {
                    if !skippedFolders.contains(name) { inside.append((item, prefix + name + "/")) }
                } else if values?.isDirectory != true, !skippedFiles.contains(name) {
                    files.append(prefix + name)
                }
            }
            files.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            inside.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            for file in files {
                if paths.count == limit { return (paths, true) }
                paths.append(file)
            }
            folders.append(contentsOf: inside)
        }
        return (paths, false)
    }
}
