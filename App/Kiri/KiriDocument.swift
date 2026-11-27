import AppKit
import KiriKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let kiriMarkdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

/// A text document. The text itself lives in the editor's NSTextStorage while
/// a window is open (so typing never round-trips through SwiftUI); the
/// editor pushes a copy here after each edit, and the document writes that.
///
/// A plain `NSDocument`, not one of SwiftUI's: a `DocumentGroup` document
/// autosaves in place and has no switch for it, and Kiri saves only when
/// asked. The file changes on Save (⌘S, the Save button, Save As) and at no
/// other time. What isn't saved yet is kept for a crash in a recovery copy
/// that AppKit writes a few seconds after an edit (`autosavingDelay`),
/// reopens at the next launch and deletes on Save, Revert and close.
///
/// AppKit finds the class by this name (`NSDocumentClass` in `project.yml`).
@objc(KiriDocument) @Observable final class KiriDocument: NSDocument {
    /// The file as read.
    private(set) var file = TextFile()
    /// Encoding and line ending to save with; the status bar and the Format
    /// menu change them (`change`).
    private(set) var encoding = TextEncoding.utf8
    private(set) var lineEnding = LineEnding.lf
    private(set) var hasBOM = false
    /// The latest text from the editor.
    @ObservationIgnored var text = ""
    /// Where the document's file is, nil until it has one. Follows Save As
    /// and a move in Finder (`fileURL` itself tells nobody).
    private(set) var location: URL?
    /// The editor that shows this document: a Revert reads the file into
    /// the same document, and the editor has to show it.
    @ObservationIgnored weak var editor: EditorController?

    /// The file changes when the person saves, never by itself.
    override nonisolated class var autosavesInPlace: Bool { false }
    /// No Versions browser: Revert goes back to the file.
    override nonisolated class var preservesVersions: Bool { false }

    // Reading and writing stay on the main thread, where the text is.
    override nonisolated class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }
    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String,
                                         for saveOperation: NSDocument.SaveOperationType) -> Bool { false }

    // Kiri reads and writes any file that holds text, whatever the system
    // calls its type: a `.toml`, a `Makefile` or a dotfile saves in place
    // like a `.txt` does, instead of being sent to Save As as a type the
    // app "can't write".
    override nonisolated class func isNativeType(_ type: String) -> Bool { true }
    override nonisolated func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        [fileType ?? UTType.plainText.identifier]
    }

    /// A file keeps the name it has. AppKit would otherwise give a saved
    /// file its type's extension: `Makefile` would come back as
    /// `Makefile.make`.
    override nonisolated func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        // (The recovery copy of a document that has no name yet is a .txt.)
        fileURL == nil && saveOperation == .autosaveElsewhereOperation ? "txt" : nil
    }

    override init() {
        super.init()
    }

    /// A new document that starts with text in it (`kiri -`).
    convenience init(text: String) {
        self.init()
        fileType = UTType.plainText.identifier
        take(TextFile(text: text))
    }

    /// Opens a new untitled document with `text` in it, in a tab like any
    /// other. It is not edited: closing piped text asks nothing.
    static func openUntitled(text: String) -> KiriDocument {
        let document = KiriDocument(text: text)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        return document
    }

    // MARK: Large files

    /// Files at least this large (50 MB) open in the read-only viewer
    /// (`LargeFileView`), after asking: the editor would hold the whole
    /// text in memory, several times over.
    static var largeFileThreshold: Int {
        #if DEBUG || KIRI_SELFTEST
        if let limit = largeFileThresholdForTests { return limit }
        #endif
        // (Measured on a release build: the editor shows a 10 MB file as
        // quickly as a 1 MB one, a 50 MB one in 1.3 s, 100 MB in 2.2 s
        // with 550 MB of memory, 500 MB in 9.4 s with 2.3 GB.)
        return 50 << 20
    }
    #if DEBUG || KIRI_SELFTEST
    /// A smaller limit for a self-test.
    static var largeFileThresholdForTests: Int?
    #endif

    /// The file, when it opened read-only for being too large for the
    /// editor. `text` is empty then, and nothing saves.
    private(set) var largeFile: LargeFile?
    /// The document is a large file, shown read-only: no editor, no
    /// syntax colors, no animations of its text, and no saving.
    var isLargeFile: Bool { largeFile != nil }
    /// The viewer that shows it, while a tab does.
    @ObservationIgnored weak var largeViewer: LargeFileViewer?

    /// The viewer opened the file again (it got shorter on disk).
    func largeFileReopened(_ new: LargeFile) { largeFile = new }

    // MARK: Pictures, videos and archives

    /// The file, when it is a picture, a video or an archive: shown in a
    /// read-only viewer (`MediaViewer`) instead of the editor, and never
    /// read as text (a video of some GB opens at once). `text` is empty
    /// then, and nothing saves.
    private(set) var media: MediaFile?
    /// The viewer that shows it, while a tab does.
    @ObservationIgnored weak var mediaViewer: MediaViewer?

    /// Nothing saves the document: a large file, or a picture, video or
    /// archive.
    var isReadOnly: Bool { largeFile != nil || media != nil }

    /// What the file at `url` is, from its first bytes (`MediaKind`), or
    /// nil for a file the editor opens.
    private nonisolated static func mediaKind(of url: URL) -> MediaKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: MediaKind.headLength)) ?? Data()
        return MediaKind.detect(fileName: url.lastPathComponent, head: head)
    }

    /// The document becomes the picture, video or archive `new`: when it
    /// opens, and again when its file changes on disk (a Revert).
    private func openMedia(_ new: MediaFile) {
        let was = media
        media = new
        largeFile = nil
        file = TextFile()
        text = ""
        encoding = .utf8
        lineEnding = .lf
        hasBOM = false
        if let was, was.kind == new.kind {
            mediaViewer?.reload(new)
        } else if was != nil || counted {
            // It was text (or a large file) and its file is now a
            // picture: its tab swaps the editor (emptied) for the viewer.
            editor?.load(self)
            DocumentWindow.tab(of: self)?.documentChangedKind()
        }
        if !counted {
            counted = true
            DispatchQueue.main.async { Telemetry.mediaOpened(new.kind, bytes: new.size) }
        }
    }

    /// A file of `size` bytes at `url` is too large for the editor: whether
    /// to open it read-only, asking first unless it is open already (a
    /// Revert, or a file that grew past the limit while it was open),
    /// reopened as it was (a restored window) or only looked at (the
    /// folder sidebar's preview). False is Cancel.
    private func openLargeFile(at url: URL, size: Int) -> Bool {
        if isLargeFile || counted { return true }
        let controller = NSDocumentController.shared as? KiriDocumentController
        if controller?.opensQuietly(url) == true { return true }
        #if DEBUG || KIRI_SELFTEST
        if let answer = LargeFileAnswer.forTests { return answer }
        #endif
        let alert = NSAlert()
        let name = url.lastPathComponent
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        alert.messageText = "“\(name)” is \(bytes)"
        alert.informativeText = "Files this large open read-only, for reading and searching. Lines show as they "
            + "are needed, and search runs on the whole file."
        alert.addButton(withTitle: "Open Read-Only")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    override nonisolated func read(from url: URL, ofType typeName: String) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let stream = MainActor.assumeIsolated { (NSDocumentController.shared as? KiriDocumentController)?.isStream(url) == true }
        // A picture, a video or an archive: its viewer, at any size. (A
        // stream is never one: its first bytes can be read only once.)
        if !stream, let kind = Self.mediaKind(of: url) {
            MainActor.assumeIsolated { openMedia(MediaFile(url: url, kind: kind, size: size)) }
            return
        }
        // It was one, and is text now.
        let wasMedia = MainActor.assumeIsolated { () -> Bool in
            guard media != nil else { return false }
            media = nil
            return true
        }
        defer {
            if wasMedia { MainActor.assumeIsolated { DocumentWindow.tab(of: self)?.documentChangedKind() } }
        }
        let large = MainActor.assumeIsolated { () -> Bool? in
            guard size >= Self.largeFileThreshold || isLargeFile || stream else { return nil }
            return openLargeFile(at: url, size: size)
        }
        switch large {
        case nil:
            try super.read(from: url, ofType: typeName)
        case false?:
            throw CocoaError(.userCancelled)
        case true?:
            // NUL in the first bytes: a binary file, as the editor says
            // of a smaller one (or UTF-16, which large files don't read).
            let head = (try? FileHandle(forReadingFrom: url)).flatMap { handle in
                defer { try? handle.close() }
                return try? handle.read(upToCount: 64 << 10)
            } ?? Data()
            if head.contains(0) { throw CocoaError(.fileReadUnknownStringEncoding) }
            let opened = try LargeFile(url: url)
            MainActor.assumeIsolated {
                let wasLarge = isLargeFile
                largeFile = opened
                file = TextFile()
                text = ""
                encoding = .utf8
                lineEnding = .lf
                hasBOM = false
                if wasLarge {
                    if let largeViewer, largeViewer.file !== opened { largeViewer.fileMayHaveChanged() }
                } else if counted {
                    // It grew past the limit while it was open: its tab
                    // swaps the editor (emptied) for the viewer.
                    editor?.load(self)
                    DocumentWindow.tab(of: self)?.documentChangedKind()
                }
                if !counted {
                    counted = true
                    DispatchQueue.main.async { Telemetry.fileOpened(language: .plainText, bytes: size) }
                }
            }
        }
    }

    // MARK: Reading

    override nonisolated func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        guard fileWrapper.isRegularFile, let data = fileWrapper.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let read: TextFile
        do { read = try TextFile(data: data) } catch { throw CocoaError(.fileReadUnknownStringEncoding) }
        let bytes = data.count
        MainActor.assumeIsolated {
            take(read)
            // The first read is the file opening (later ones are Revert):
            // its language and rough size, once it has its name.
            if !counted {
                counted = true
                DispatchQueue.main.async { Telemetry.fileOpened(language: self.detectedLanguage, bytes: bytes) }
            }
        }
    }

    /// Whether the opening of this file was counted (`Telemetry`).
    @ObservationIgnored private var counted = false

    /// The document becomes `read`: when it opens, and again on Revert,
    /// which AppKit reads into the document that is already open.
    private func take(_ read: TextFile) {
        file = read
        text = read.text
        encoding = read.encoding
        lineEnding = read.lineEnding
        hasBOM = read.hasBOM
        editor?.load(self)
    }

    // MARK: Writing

    override func data(ofType typeName: String) throws -> Data {
        // A large file, a picture, a video or an archive is never written:
        // its text is not here.
        if isReadOnly { throw CocoaError(.fileWriteNoPermission) }
        do { return try contents().data() } catch { throw CocoaError(.fileWriteInapplicableStringEncoding) }
    }

    /// The text as it is now, in the format chosen for it.
    private func contents() -> TextFile {
        var f = file
        f.text = text
        f.encoding = encoding
        f.lineEnding = lineEnding
        f.hasBOM = hasBOM && encoding.isUnicode
        return f
    }

    override nonisolated func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                                    originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        // A recovery copy must never fail for the reason a save may: text
        // that doesn't fit the chosen encoding. It is kept as UTF-8 then,
        // without a word; the save itself still says what is wrong.
        if saveOperation == .autosaveElsewhereOperation {
            let data = MainActor.assumeIsolated { () -> Data? in
                var f = contents()
                if let data = try? f.data() { return data }
                f.encoding = .utf8
                return try? f.data()
            }
            if let data {
                try data.write(to: url, options: .atomic)
                return
            }
        }
        try super.write(to: url, ofType: typeName, for: saveOperation, originalContentsURL: absoluteOriginalContentsURL)
    }

    /// A save keeps a preview tab: a file that was saved here is one
    /// being worked on. (A recovery copy is no save.)
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        // A large file (a picture, a video, an archive) is read-only.
        // (Cancelled, so no alert says so: Save is off in the menus and on
        // the toolbar already.)
        if isReadOnly {
            completionHandler(CocoaError(.userCancelled))
            return
        }
        super.save(to: url, ofType: typeName, for: saveOperation) { error in
            if error == nil, saveOperation != .autosaveElsewhereOperation {
                MainActor.assumeIsolated { PreviewTabs.keep(self) }
            }
            completionHandler(error)
        }
    }

    // MARK: Recovery copies

    /// AppKit keeps the recovery copy of a document that has a file beside
    /// that file, as "name (Autosaved).ext": in a project folder, where a
    /// build would compile it and git would list it. Kiri keeps them all in
    /// one place instead, with those of untitled documents (which AppKit
    /// puts there itself). AppKit's record of what to reopen holds
    /// bookmarks, so it finds them wherever they are.
    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool,
                           completionHandler: @escaping (Error?) -> Void) {
        guard let fileURL, hasUnautosavedChanges else {
            super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable, completionHandler: completionHandler)
            return
        }
        let copy = autosavedContentsFileURL ?? RecoveryCopies.newURL(for: fileURL)
        save(to: copy, ofType: autosavingFileType ?? fileType ?? UTType.plainText.identifier,
             for: .autosaveElsewhereOperation, completionHandler: completionHandler)
    }

    // MARK: Where the file is

    @ObservationIgnored override nonisolated var fileURL: URL? {
        didSet {
            let url = fileURL
            // Set on the main thread, since nothing here saves off it.
            if Thread.isMainThread {
                MainActor.assumeIsolated { if location != url { location = url } }
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.location != url else { return }
                    self.location = url
                }
            }
        }
    }

    /// The language the file's name, or its first line, says it is in.
    var detectedLanguage: Language {
        if isReadOnly { return .plainText }
        let firstLine = file.text.prefix(200).split(separator: "\n", maxSplits: 1).first.map(String.init)
        return Language.detect(fileName: fileURL?.lastPathComponent, firstLine: firstLine)
    }

    // MARK: Changes on disk

    /// The file was changed by something else (git, a formatter, another
    /// editor). A document with no unsaved changes takes the file up; one
    /// with changes keeps them, and its next Save says the file has
    /// changed and asks which to keep, as AppKit does.
    override nonisolated func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in self?.reloadIfChangedOnDisk() }
    }

    private func reloadIfChangedOnDisk() {
        // A large file follows its file itself (`LargeFileViewer`).
        if isLargeFile {
            largeViewer?.fileMayHaveChanged()
            return
        }
        // The document's own save is not news: it sets `fileModificationDate`.
        guard !isDocumentEdited, let fileURL, let fileType,
              let onDisk = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date,
              onDisk != fileModificationDate else { return }
        try? revert(toContentsOf: fileURL, ofType: fileType)
    }

    // MARK: The save format

    /// Changes the encoding, the line endings or the byte order mark: an
    /// undoable edit, so the document turns dirty.
    func change<V: Equatable>(_ keyPath: ReferenceWritableKeyPath<KiriDocument, V>, to new: V, actionName: String) {
        let old = self[keyPath: keyPath]
        guard old != new, !isReadOnly else { return }
        self[keyPath: keyPath] = new
        // Unsaved changes, so no longer a preview.
        PreviewTabs.keep(self)
        undoManager?.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated { document.change(keyPath, to: old, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
    }

    func setEncoding(_ new: TextEncoding) { change(\.encoding, to: new, actionName: "Change Encoding") }
    func setLineEnding(_ new: LineEnding) { change(\.lineEnding, to: new, actionName: "Change Line Endings") }
    func setByteOrderMark(_ new: Bool) { change(\.hasBOM, to: new, actionName: "Change Byte Order Mark") }

    /// A large file (or a picture, video or archive) has nothing to save,
    /// whatever happens to the (empty, unseen) editor behind it.
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        if isReadOnly { return }
        super.updateChangeCount(change)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if isReadOnly, let action = item.action,
           [#selector(save(_:)), #selector(saveAs(_:)), #selector(saveTo(_:)), #selector(duplicate(_:))].contains(action) {
            return false
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Tabs and panels

    /// A document opens as a tab (`DocumentWindow.place`): of the front
    /// window, or of a window of its own when that is asked for. It has a
    /// window controller only while its tab shows.
    override func makeWindowControllers() {
        DocumentWindow.place(self)
    }

    /// Its tab comes forward, in its window.
    override func showWindows() {
        guard let tab = DocumentWindow.tab(of: self), let window = tab.window else {
            super.showWindows()
            return
        }
        window.tabs.select(tab)
        window.makeKeyAndOrderFront(nil)
    }

    /// Sheets (the close question, Save As, a save that fails) show on its
    /// tab's window, also while another tab shows there.
    override var windowForSheet: NSWindow? {
        DocumentWindow.window(of: self) ?? super.windowForSheet
    }

    /// The close question is asked with its tab showing, so it is seen
    /// whose it is: from the tab's close button, closing the window, Close
    /// All and quitting.
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
                           contextInfo: UnsafeMutableRawPointer?) {
        if isDocumentEdited, let tab = DocumentWindow.tab(of: self), let window = tab.window {
            window.tabs.select(tab)
            window.makeKeyAndOrderFront(nil)
        }
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }

    /// AppKit asks the document that shows when its window is to close
    /// (the window's close button goes there, not to `performClose`):
    /// the window has other tabs to ask about, so it is told no, and
    /// the window closes the way Close Window does (`DocumentWindow.closeWindow`).
    override func shouldCloseWindowController(_ windowController: NSWindowController, delegate: Any?,
                                              shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        guard let window = windowController.window as? DocumentNSWindow, !window.closing else {
            super.shouldCloseWindowController(windowController, delegate: delegate, shouldClose: shouldCloseSelector,
                                              contextInfo: contextInfo)
            return
        }
        if let delegate = delegate as? NSObject, let shouldCloseSelector, delegate.responds(to: shouldCloseSelector) {
            typealias Answer = @convention(c) (NSObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
            let answer = unsafeBitCast(delegate.method(for: shouldCloseSelector), to: Answer.self)
            answer(delegate, shouldCloseSelector, self, false, contextInfo)
        }
        DispatchQueue.main.async { window.performClose(nil) }
    }

    /// Its tab goes first (the window with its last tab), then the
    /// document. `kiri -w` and the files `kiri` made are told.
    override func close() {
        largeViewer?.stop()
        mediaViewer?.stop()
        if let fileURL { (NSDocumentController.shared as? KiriDocumentController)?.endStream(fileURL) }
        DocumentWindow.documentWillClose(self)
        super.close()
        DispatchQueue.main.async {
            Waits.shared.check()
            NewFiles.shared.check()
        }
    }

    /// A window AppKit brings back at launch: a window of its own for the
    /// document that showed in it, never a tab of whichever window is in
    /// front. Its other tabs come back from the window's own state
    /// (`DocumentNSWindow.restoreState`).
    override func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                                completionHandler: @escaping (NSWindow?, (any Error)?) -> Void) {
        let window = DocumentWindow.makeWindow()
        window.identifier = identifier
        window.tabs.insert(DocumentWindow.tab(of: self) ?? DocumentTab(document: self, arriving: false))
        completionHandler(window, nil)
    }

    /// The window remembers its tabs' recovery copies for the next launch.
    @ObservationIgnored override nonisolated var autosavedContentsFileURL: URL? {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                DocumentWindow.window(of: self)?.invalidateRestorableState()
            }
        }
    }

    /// The Save panel takes any name: a text editor saves a `Makefile` and
    /// a `.rs` file as readily as a `.txt`. A document that has never been
    /// saved is offered as plain text.
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowedContentTypes = []
        savePanel.allowsOtherFileTypes = true
        savePanel.isExtensionHidden = false
        savePanel.canSelectHiddenExtension = false
        savePanel.nameFieldStringValue = fileURL?.lastPathComponent ?? displayName + ".txt"
        return true
    }

    /// No "File Format" pop-up: the format is the text's own.
    override var shouldRunSavePanelWithAccessoryView: Bool { false }
}

/// Where the recovery copies of documents that have a file are kept.
enum RecoveryCopies {
    /// The folder AppKit keeps the copies of untitled documents in:
    /// `~/Library/Autosave Information`, or, in a launch that leaves saved
    /// state alone (`-ApplePersistenceIgnoreState YES`: a run from Xcode
    /// set up that way, the self-tests), a folder of that name in the
    /// temporary directory. Such a launch must not write among the real
    /// copies, and AppKit reopens nothing from the other folder.
    static var folder: URL {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Autosave Information", isDirectory: true)
        if UserDefaults.standard.bool(forKey: "ApplePersistenceIgnoreState") { return temporary }
        return (try? FileManager.default.url(for: .autosavedInformationDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: true)) ?? temporary
    }

    /// A name no other copy has: "notes (Autosaved 3F9A61C2).md". Files of
    /// the same name in different folders each get their own.
    static func newURL(for file: URL) -> URL {
        let folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = file.deletingPathExtension().lastPathComponent, ext = file.pathExtension
        while true {
            let tagged = "\(name) (Autosaved \(UUID().uuidString.prefix(8)))"
            let url = folder.appendingPathComponent(ext.isEmpty ? tagged : tagged + "." + ext)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
    }
}
