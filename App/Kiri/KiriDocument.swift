import KiriKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let kiriMarkdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

/// A text document. The text itself lives in the editor's NSTextStorage while
/// a window is open (so typing never round-trips through SwiftUI); the
/// document reads it from there when it saves.
final class KiriDocument: ReferenceFileDocument, @unchecked Sendable {
    typealias Snapshot = TextFile

    /// Everything Kiri can open. `public.data` lets any file through the Open
    /// panel; reading rejects files that aren't text.
    static var readableContentTypes: [UTType] {
        [.plainText, .text, .sourceCode, .kiriMarkdown, .json, .yaml, .xml, .propertyList, .commaSeparatedText,
         .shellScript, .pythonScript, .swiftSource, .javaScript, .html, .data]
    }

    static var writableContentTypes: [UTType] {
        [.plainText, .text, .sourceCode, .kiriMarkdown, .json, .yaml, .xml, .propertyList, .commaSeparatedText,
         .shellScript, .pythonScript, .swiftSource, .javaScript, .html, .data]
    }

    // State is only touched on the main thread (SwiftUI reads the file on a
    // background thread, but before anyone else can see the document).
    /// The file as read.
    var file: TextFile
    /// Encoding and line ending to save with; the status bar changes them.
    @Published var encoding: TextEncoding
    @Published var lineEnding: LineEnding
    @Published var hasBOM: Bool
    /// The editor's current text, set while an editor shows this document.
    var currentText: (@MainActor () -> String)?

    init(text: String = "") {
        file = TextFile(text: text)
        encoding = file.encoding
        lineEnding = file.lineEnding
        hasBOM = file.hasBOM
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        do { file = try TextFile(data: data) } catch { throw CocoaError(.fileReadUnknownStringEncoding) }
        encoding = file.encoding
        lineEnding = file.lineEnding
        hasBOM = file.hasBOM
    }

    func snapshot(contentType: UTType) throws -> TextFile {
        var f = file
        if let currentText {
            f.text = Thread.isMainThread ? MainActor.assumeIsolated { currentText() }
                : DispatchQueue.main.sync { MainActor.assumeIsolated { currentText() } }
        }
        f.encoding = encoding
        f.lineEnding = lineEnding
        f.hasBOM = hasBOM && encoding.isUnicode
        _ = try f.data() // Fail the save now if the text doesn't fit the encoding.
        return f
    }

    func fileWrapper(snapshot: TextFile, configuration: WriteConfiguration) throws -> FileWrapper {
        do {
            return FileWrapper(regularFileWithContents: try snapshot.data())
        } catch {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
    }
}
