import AppKit
import KiriKit

/// The app side of the `kiri` command (App/CLI/kiri): the script writes a
/// request file to the per-user temporary folder and opens
/// `kiri://open?id=…`; Kiri reads the request, deletes it and opens what it
/// asks for.
///
/// Request format, one entry per line:
///
///     kiri 1
///     window front|new
///     wait <marker path>          (optional: delete the marker when the tabs close)
///     file <line> <column> <path> (0 for no position; a missing file opens empty)
///     folder <path>               (a new window with a file sidebar)
///     stdin <path>                (a new untitled tab with this text; the file is deleted)
///     untitled                    (a new untitled tab)
@MainActor enum KiriCLI {
    static let scheme = "kiri"

    static var requestDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("kiri-cli")
    }

    struct Request: Equatable {
        enum Entry: Equatable {
            case file(URL, line: Int, column: Int)
            case folder(URL)
            case stdin(URL)
            case untitled
        }

        var newWindow = false
        var waitMarker: URL?
        var entries: [Entry] = []

        init(newWindow: Bool = false, waitMarker: URL? = nil, entries: [Entry]) {
            self.newWindow = newWindow
            self.waitMarker = waitMarker
            self.entries = entries
        }

        init?(parsing text: String) {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard lines.first == "kiri 1" else { return nil }
            lines.removeFirst()
            for line in lines {
                let (word, rest) = Self.split(line)
                switch word {
                case "window": newWindow = rest == "new"
                case "wait": waitMarker = URL(fileURLWithPath: rest)
                case "folder": entries.append(.folder(URL(fileURLWithPath: rest, isDirectory: true)))
                case "stdin": entries.append(.stdin(URL(fileURLWithPath: rest)))
                case "untitled": entries.append(.untitled)
                case "file":
                    let (l, r1) = Self.split(rest)
                    let (c, path) = Self.split(r1)
                    guard let l = Int(l), let c = Int(c), path.hasPrefix("/") else { continue }
                    entries.append(.file(URL(fileURLWithPath: path), line: l, column: c))
                default: continue
                }
            }
        }

        private static func split(_ s: String) -> (String, String) {
            guard let space = s.firstIndex(of: " ") else { return (s, "") }
            return (String(s[..<space]), String(s[s.index(after: space)...]))
        }
    }

    // MARK: URL events

    /// Takes kiri:// URLs from Launch Services. Installed before launch
    /// finishes, so the URL that launched the app arrives here too.
    static func install() {
        NSAppleEventManager.shared().setEventHandler(URLEventHandler.shared,
                                                     andSelector: #selector(URLEventHandler.handle(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        Waits.shared.start()
    }

    static func handle(_ url: URL) {
        guard url.scheme == scheme,
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "id" })?.value,
              id.range(of: #"^request\.[A-Za-z0-9]+$"#, options: .regularExpression) != nil else { return }
        let file = requestDirectory.appendingPathComponent(id + ".req")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        guard let request = Request(parsing: text) else { return }
        // (A test launch stays behind: `SelfTest.stayInTheBackground`.)
        NSApp.activate()
        open(request)
    }

    /// - Parameters:
    ///   - window: the document window whose tabs the files join (one
    ///     they were dropped on); nil for the front one.
    ///   - completion: called when every entry has been opened.
    static func open(_ request: Request, in window: NSWindow? = nil, then completion: (() -> Void)? = nil) {
        hasOpenedSomething = true
        let opener = Opener(request)
        opener.target = window
        opener.completion = completion
        opener.run()
    }

    /// A request has arrived: one that launched Kiri opens what it asks
    /// for, and the empty document of a plain launch isn't wanted.
    private(set) static var hasOpenedSomething = false

    // MARK: Opening

    /// Opens a request's entries one after another, each tab after the one
    /// before.
    @MainActor private final class Opener {
        let request: Request
        var queue: [Request.Entry]
        var opened: [NSDocument] = []
        /// The first document goes into a window of its own.
        var standalone: Bool
        /// The folder of the window being filled, for its sidebar.
        var folder: FolderSession?
        /// The window whose tabs the documents join, when it isn't
        /// simply the front one, and the document the next one goes after.
        weak var target: NSWindow?
        private weak var last: NSDocument?
        /// The window the request's first document went into: the rest
        /// follow it there (a new window's, `kiri -n`, a folder).
        private weak var filling: DocumentNSWindow?
        var completion: (() -> Void)?

        init(_ request: Request) {
            self.request = request
            queue = request.entries
            standalone = request.newWindow
            // A folder and files together: the files fill the folder's
            // window instead of sitting beside an empty tab.
            if let i = queue.firstIndex(where: { if case .folder = $0 { true } else { false } }),
               queue.contains(where: { if case .folder = $0 { false } else { true } }),
               case .folder(let url) = queue[i] {
                queue.remove(at: i)
                folder = FolderSession(root: url)
                standalone = true
            }
        }

        func run() {
            guard !queue.isEmpty else { finish(); return }
            let entry = queue.removeFirst()
            if case .folder(let url) = entry {
                folder = FolderSession(root: url)
                standalone = true
                openUntitled(text: nil)
                return
            }
            switch entry {
            case .file(let url, let line, let column): openFile(url, line: line, column: column)
            case .stdin(let url):
                let data = (try? Data(contentsOf: url)) ?? Data()
                try? FileManager.default.removeItem(at: url)
                let text = (try? TextFile(data: data))?.text ?? String(decoding: data, as: UTF8.self)
                openUntitled(text: text)
            case .untitled, .folder: openUntitled(text: nil)
            }
        }

        private func placeNext() {
            if standalone {
                WindowPlacement.next = .init(folder: folder)
                // What follows fills the new window.
                filling = nil
                last = nil
            } else if let host = filling ?? (target as? DocumentNSWindow) {
                WindowPlacement.next = .init(host: host, after: last ?? host.tabs.document)
            }
            standalone = false
        }

        /// `document` opened: the next goes after it, in its window.
        private func opened(_ document: NSDocument) {
            opened.append(document)
            guard let window = DocumentWindow.window(of: document) else { return }
            if filling == nil { filling = window }
            if window === filling { last = document }
        }

        private func openUntitled(text: String?) {
            placeNext()
            do {
                if let text {
                    opened(KiriDocument.openUntitled(text: text))
                } else {
                    opened(try NSDocumentController.shared.openUntitledDocumentAndDisplay(true))
                }
            } catch {
                WindowPlacement.next = nil
                _ = NSApp.presentError(error)
            }
            continueAfterPlacement()
        }

        private func openFile(_ url: URL, line: Int, column: Int) {
            let url = url.standardizedFileURL
            if !FileManager.default.fileExists(atPath: url.path) {
                // Opens empty; NewFiles deletes it again if it's closed unsaved.
                guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                    _ = NSApp.presentError(CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]))
                    run()
                    return
                }
                NewFiles.shared.created(url)
            }
            placeNext()
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, alreadyOpen, error in
                MainActor.assumeIsolated {
                    if alreadyOpen { WindowPlacement.next = nil }
                    if let error {
                        WindowPlacement.next = nil
                        // (Cancel on "Open it read-only?" says nothing more.)
                        if (error as? CocoaError)?.code != .userCancelled { _ = NSApp.presentError(error) }
                    }
                    if let doc {
                        if alreadyOpen {
                            // It comes forward where it is (`showWindows`).
                            self.opened.append(doc)
                        } else {
                            self.opened(doc)
                        }
                        if line > 0 { Editors.whenReady(doc) { $0.goTo(line: line, column: max(column, 1)) } }
                    }
                    self.continueAfterPlacement()
                }
            }
        }

        /// Waits (briefly) for a new window to take its placement, then
        /// opens the next entry.
        private func continueAfterPlacement(tries: Int = 0) {
            if WindowPlacement.next != nil, tries < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { self.continueAfterPlacement(tries: tries + 1) }
                return
            }
            WindowPlacement.next = nil
            run()
        }

        private func finish() {
            if let marker = request.waitMarker {
                Waits.shared.add(marker: marker, documents: opened)
            }
            completion?()
            completion = nil
        }
    }
}

/// Where the next document that opens goes when that isn't the front
/// window's tabs: a window of its own (with a folder sidebar or not), or
/// among the tabs of `host` (a window files were dropped on), after the
/// tab of `after`. `DocumentWindow.place` takes it.
@MainActor enum WindowPlacement {
    struct Placement {
        var folder: FolderSession?
        weak var host: DocumentNSWindow?
        weak var after: NSDocument?
    }
    static var next: Placement?

    static func take() -> Placement? {
        defer { next = nil }
        return next
    }
}

/// Finds a document's tab and editor.
@MainActor enum Editors {
    /// The window `doc` is a tab of.
    static func window(for doc: NSDocument) -> NSWindow? { DocumentWindow.window(of: doc) }

    /// Runs `action` on `doc`'s editor, with its tab showing, once it is
    /// in a tab.
    static func whenReady(_ doc: NSDocument, tries: Int = 0, _ action: @escaping @MainActor (EditorController) -> Void) {
        if let tab = DocumentWindow.tab(of: doc), let window = tab.window, tab.controller.document != nil {
            window.tabs.select(tab)
            action(tab.controller)
            return
        }
        guard tries < 80 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(25))
            whenReady(doc, tries: tries + 1, action)
        }
    }
}

/// `kiri -w`: deletes each request's marker once all its documents are
/// closed (or Kiri quits), which ends the waiting script.
@MainActor final class Waits {
    static let shared = Waits()
    private struct Wait {
        let marker: URL
        let documents: [WeakDocument]
    }
    private struct WeakDocument { weak var doc: NSDocument? }
    private var waits: [Wait] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // The document is gone from the controller just after its window.
            DispatchQueue.main.async { MainActor.assumeIsolated { Waits.shared.check(); NewFiles.shared.check() } }
        }
        nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for w in Waits.shared.waits { try? FileManager.default.removeItem(at: w.marker) }
                NewFiles.shared.check(all: true)
            }
        }
    }

    func add(marker: URL, documents: [NSDocument]) {
        waits.append(Wait(marker: marker, documents: documents.map { WeakDocument(doc: $0) }))
        // Not in the middle of a commit message: What's new waits.
        WhatsNew.shared.waiting(on: documents)
        check()
    }

    func check() {
        let open = NSDocumentController.shared.documents
        waits.removeAll { w in
            let done = w.documents.allSatisfy { d in d.doc.map { doc in !open.contains { $0 === doc } } ?? true }
            if done { try? FileManager.default.removeItem(at: w.marker) }
            return done
        }
    }
}

/// Files `kiri new.txt` created so they could open: deleted again when
/// their tab closes without a save.
@MainActor final class NewFiles {
    static let shared = NewFiles()
    private var created: [URL: Date] = [:]

    func created(_ url: URL) {
        created[url] = modificationDate(url)
    }

    func check(all: Bool = false) {
        let openURLs = Set(NSDocumentController.shared.documents.compactMap { $0.fileURL?.standardizedFileURL })
        for (url, date) in created where all || !openURLs.contains(url) {
            created[url] = nil
            guard !openURLs.contains(url) || all else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            // Still the empty file Kiri made: never saved.
            if (attrs?[.size] as? Int) == 0, modificationDate(url) == date {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// Apple events arrive on the main thread.
@MainActor private final class URLEventHandler: NSObject {
    static let shared = URLEventHandler()

    @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        KiriCLI.handle(url)
    }
}
