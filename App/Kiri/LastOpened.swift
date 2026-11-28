import AppKit

/// What Kiri opens when it is simply launched and nothing else opens (no
/// file or folder named, no window AppKit brings back): the last folder
/// or file it showed, instead of an empty editor. Settings ▸ Editor ▸
/// Reopen at launch turns it off (`Prefs.reopenAtLaunchKey`).
///
/// The last thing shown is the front document window's folder, with the
/// file its tab showed, or that file alone in a window without a folder.
/// It is noted (in memory) as windows come forward and tabs are chosen,
/// so the window closed last counts when none is open at the end, and it
/// is kept in the preferences when Kiri quits. Untitled documents, piped
/// input and the files `kiri -w` waits on (a commit message) are never
/// it: what was noted before stays.
///
/// Reopening comes after launching, from `LaunchDocument`, where the
/// empty document would otherwise open. A file or folder that is gone
/// (deleted, on a disk that isn't there) gives the empty document, with
/// nothing said; the check runs off the main thread, so a dead network
/// mount can't hold up the launch.
enum LastOpened {
    static let key = "KiriLastOpened"

    /// A folder, a file, or a file in its folder's window.
    nonisolated struct Item: Equatable, Sendable {
        var folder: URL?
        var file: URL?

        var isEmpty: Bool { folder == nil && file == nil }

        /// In the preferences: the paths.
        var plist: [String: String] {
            var p: [String: String] = [:]
            if let folder { p["folder"] = folder.path }
            if let file { p["file"] = file.path }
            return p
        }

        init(folder: URL? = nil, file: URL? = nil) {
            self.folder = folder.map { URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL }
            self.file = file?.standardizedFileURL
        }

        init?(plist: Any?) {
            guard let p = plist as? [String: Any] else { return nil }
            let path = { (key: String) in (p[key] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil } }
            self.init(folder: path("folder").map { URL(fileURLWithPath: $0, isDirectory: true) },
                      file: path("file").map { URL(fileURLWithPath: $0) })
            if isEmpty { return nil }
        }
    }

    static var enabled: Bool { UserDefaults.standard.object(forKey: Prefs.reopenAtLaunchKey) as? Bool ?? true }

    /// The last thing shown in this launch, not yet written.
    private(set) static var current: Item?
    private static var started = false

    /// Kiri quits: the front window is the last thing shown, and what was
    /// noted is kept for the next launch.
    static func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                if let front = DocumentWindow.front { note(front) }
                save()
            }
        }
    }

    /// `window` came forward or shows another tab.
    static func note(_ window: DocumentNSWindow) {
        guard let item = item(of: window) else { return }
        // The folder's window without a file in front (its last tab
        // closed, or an untitled one): the file noted in it stays.
        if item.file == nil, let current, current.folder != nil, current.folder == item.folder { return }
        current = item
    }

    /// What `window` would bring back: its folder and the file of the tab
    /// that shows (one that can come back), nil when it has neither.
    static func item(of window: DocumentNSWindow) -> Item? {
        let folder = FolderSessions.session(for: window)?.root.url
        let file = window.tabs.selectedTab.flatMap { tab in reopenable(tab.document) ? tab.document.fileURL : nil }
        let item = Item(folder: folder, file: file)
        return item.isEmpty ? nil : item
    }

    /// A document with a file of the person's own: not piped input, not a
    /// file `kiri -w` is waiting on.
    private static func reopenable(_ document: KiriDocument) -> Bool {
        guard let url = document.fileURL else { return false }
        let controller = NSDocumentController.shared as? KiriDocumentController
        if controller?.isStream(url) == true || Waits.shared.isWaiting(on: document) { return false }
        let requests = KiriCLI.requestDirectory.standardizedFileURL.path + "/"
        return !url.standardizedFileURL.path.hasPrefix(requests)
    }

    /// What the last launch kept. A test launch reads only what it was
    /// given (`-KiriLastOpened '{ file = "/path"; }'`), never the person's.
    static var saved: Item? {
        #if DEBUG || KIRI_SELFTEST
        if SelfTest.isTestLaunch { return Item(plist: UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key]) }
        #endif
        return Item(plist: UserDefaults.standard.dictionary(forKey: key))
    }

    private static func save() {
        guard let current else { return }
        #if DEBUG || KIRI_SELFTEST
        if SelfTest.isTestLaunch { SelfTest.setArgument(key, plist: current.plist); return }
        #endif
        UserDefaults.standard.set(current.plist, forKey: key)
    }

    /// Instead of the empty document of a plain launch: opens what was
    /// kept, or calls `otherwise` when that is off, nothing was kept or
    /// none of it is there any more (or something else opened meanwhile).
    static func reopen(otherwise: @escaping @MainActor () -> Void) {
        guard enabled, let saved else { otherwise(); return }
        Task {
            let found = await existing(saved)
            guard NSDocumentController.shared.documents.isEmpty, !KiriCLI.hasOpenedSomething else { return }
            guard let found else { otherwise(); return }
            open(found)
        }
    }

    /// Opens `item` as `kiri <folder> <file>` would: the folder's window,
    /// with the file in it.
    static func open(_ item: Item) {
        var entries: [KiriCLI.Request.Entry] = []
        if let folder = item.folder { entries.append(.folder(folder)) }
        let controller = NSDocumentController.shared as? KiriDocumentController
        if let file = item.file {
            // A large file opens read-only without asking, as a window
            // AppKit brings back does.
            controller?.reopensQuietly(file)
            entries.append(.file(file, line: 0, column: 0))
        }
        KiriCLI.open(KiriCLI.Request(entries: entries)) {
            if let file = item.file { controller?.reopened(file) }
        }
    }

    /// The part of `item` that is still there: the folder if it is a
    /// folder, the file if it is a file. Nil for neither.
    @concurrent nonisolated static func existing(_ item: Item) async -> Item? {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        let folder = item.folder.flatMap { files.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue ? $0 : nil }
        let file = item.file.flatMap { files.fileExists(atPath: $0.path, isDirectory: &isDirectory) && !isDirectory.boolValue ? $0 : nil }
        let found = Item(folder: folder, file: file)
        return found.isEmpty ? nil : found
    }

    #if DEBUG || KIRI_SELFTEST
    /// For the self-test: forgets what was noted.
    static func forget() { current = nil }
    #endif
}
