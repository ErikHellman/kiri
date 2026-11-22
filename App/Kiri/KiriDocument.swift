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
    override class var autosavesInPlace: Bool { false }
    /// No Versions browser: Revert goes back to the file.
    override class var preservesVersions: Bool { false }

    // Reading and writing stay on the main thread, where the text is.
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }
    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String,
                                         for saveOperation: NSDocument.SaveOperationType) -> Bool { false }

    // Kiri reads and writes any file that holds text, whatever the system
    // calls its type: a `.toml`, a `Makefile` or a dotfile saves in place
    // like a `.txt` does, instead of being sent to Save As as a type the
    // app "can't write".
    override class func isNativeType(_ type: String) -> Bool { true }
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

    /// Opens a new untitled document with `text` in it, in a window like
    /// any other. It is not edited: closing piped text asks nothing.
    static func openUntitled(text: String) -> KiriDocument {
        let document = KiriDocument(text: text)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        return document
    }

    // MARK: Reading

    override nonisolated func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        guard fileWrapper.isRegularFile, let data = fileWrapper.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let read: TextFile
        do { read = try TextFile(data: data) } catch { throw CocoaError(.fileReadUnknownStringEncoding) }
        MainActor.assumeIsolated { take(read) }
    }

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
        guard old != new else { return }
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

    // MARK: Windows and panels

    override func makeWindowControllers() {
        addWindowController(DocumentWindow.controller(for: self))
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
