import AppKit
import KiriKit
import KiriSyntax
import SwiftUI

/// What the status bar shows and the menus act on, for one window.
@MainActor @Observable final class EditorModel {
    var line = 1
    var column = 1
    var selectedLength = 0
    var lineCount = 1
    var language = Language.plainText
    /// Go to Line (⌘L) is showing.
    var showGoToLine = false
    /// Set by the editor once it exists.
    @ObservationIgnored weak var controller: EditorController?
}

/// The editor as a SwiftUI view.
struct EditorView: NSViewRepresentable {
    let document: KiriDocument
    let model: EditorModel
    let fontScale: Double
    let language: Language
    let wrapLines: Bool

    func makeCoordinator() -> EditorController { EditorController(model: model) }

    func makeNSView(context: Context) -> EditorContainerView {
        let view = EditorContainerView(frame: .zero)
        context.coordinator.undoManager = context.environment.undoManager
        context.coordinator.attach(view)
        context.coordinator.load(document)
        context.coordinator.setLanguage(language)
        LaunchTimer.editorShown()
        #if DEBUG
        SelfTest.run(textView: view.textView)
        #endif
        return view
    }

    func updateNSView(_ view: EditorContainerView, context: Context) {
        let c = context.coordinator
        c.undoManager = context.environment.undoManager
        if c.document !== document { c.load(document) }
        c.setFontScale(fontScale)
        c.setLanguage(language)
        c.setWrap(wrapLines)
    }
}

/// Owns the text view's behaviour: loading text, tracking lines, the caret
/// position and the font.
@MainActor final class EditorController: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    let model: EditorModel
    private(set) weak var document: KiriDocument?
    private weak var container: EditorContainerView?
    private var fontScale = 1.0
    private var lineIndex = LineIndex()
    private var highlighter: SyntaxHighlighter?
    /// The document's undo manager: text edits registered here make the
    /// document dirty, and File ▸ Save cleans it.
    weak var undoManager: UndoManager?

    init(model: EditorModel) {
        self.model = model
        super.init()
        model.controller = self
    }

    var textView: KiriTextView? { container?.textView }

    func attach(_ view: EditorContainerView) {
        container = view
        view.textView.delegate = self
        view.textView.textStorage?.delegate = self
        highlighter = SyntaxHighlighter(textView: view.textView)
        view.onScroll = { [weak self] in self?.highlighter?.visibleRangeChanged() }
        applyFont()
    }

    /// Shows `document`'s text (a new window, or after File ▸ Revert).
    func load(_ document: KiriDocument) {
        guard let textView, let storage = textView.textStorage else { return }
        self.document = document
        let text = document.text
        // The storage delegate fills the index in from this edit: replacing
        // everything (old length) with `text`.
        lineIndex = LineIndex(storage.string)
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(string: text, attributes: textAttributes))
        storage.endEditing()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        assert(lineIndex.length == storage.length, "line index out of sync")
        container?.gutter.lineIndex = lineIndex
        container?.updateGutterWidth()
        highlighter?.textReplaced()
        updateCaret()
    }

    func setLanguage(_ language: Language) {
        highlighter?.setLanguage(language)
    }

    // MARK: Font

    func setFontScale(_ scale: Double) {
        guard scale != fontScale else { return }
        fontScale = scale
        applyFont()
    }

    private var font: NSFont { .monospacedSystemFont(ofSize: Honey.editorFontSize * fontScale, weight: .regular) }

    private var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.18
        return [.font: font, .foregroundColor: NSColor.honey(Honey.fg), .paragraphStyle: paragraph]
    }

    private func applyFont() {
        guard let textView, let storage = textView.textStorage else { return }
        let attrs = textAttributes
        textView.font = font
        textView.typingAttributes = attrs
        textView.defaultParagraphStyle = attrs[.paragraphStyle] as? NSParagraphStyle
        if storage.length > 0 {
            storage.beginEditing()
            storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        highlighter?.baseFont = font
        highlighter?.invalidateColors()
        container?.gutter.font = .monospacedDigitSystemFont(ofSize: max(9, 11 * fontScale), weight: .regular)
        container?.updateGutterWidth()
    }

    // MARK: Edits and the caret

    func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        nonisolated(unsafe) let textStorage = textStorage
        MainActor.assumeIsolated {
            let old = editedRange.location..<(editedRange.location + editedRange.length - delta)
            let inserted = (textStorage.string as NSString).substring(with: editedRange)
            let before = lineIndex
            if old.upperBound <= lineIndex.length {
                lineIndex.replace(range: old, with: inserted)
                highlighter?.didEdit(SyntaxEdit(old: old, newLength: editedRange.length, before: before,
                                                after: lineIndex))
            } else {
                lineIndex = LineIndex(textStorage.string)
                highlighter?.textReplaced()
            }
            container?.gutter.lineIndex = lineIndex
            container?.updateGutterWidth()
        }
    }

    func textDidChange(_ notification: Notification) {
        if let textView { document?.text = textView.string }
        updateCaret()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateCaret()
    }

    private func updateCaret() {
        guard let textView else { return }
        let sel = textView.selectedRange()
        let line = lineIndex.line(at: sel.location)
        let lineStart = lineIndex.starts[line]
        // Columns count characters, not UTF-16 units.
        let prefix = (textView.string as NSString).substring(with: NSRange(location: lineStart,
                                                                          length: sel.location - lineStart))
        model.line = line + 1
        model.column = prefix.count + 1
        model.selectedLength = sel.length
        model.lineCount = lineIndex.lineCount
        container?.gutter.currentLine = line
        textView.highlightsCurrentLine = sel.length == 0
    }

    // MARK: Commands

    /// Wraps long lines at the editor's edge, or scrolls sideways.
    func setWrap(_ wrap: Bool) {
        guard let textView, let container = textView.textContainer, let scroll = textView.enclosingScrollView,
              container.widthTracksTextView != wrap else { return }
        container.widthTracksTextView = wrap
        textView.isHorizontallyResizable = !wrap
        scroll.hasHorizontalScroller = !wrap
        if wrap {
            container.size = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
            textView.frame.size.width = scroll.contentSize.width
        } else {
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        highlighter?.visibleRangeChanged()
    }

    /// Moves the caret to a 1-based line (and column) and scrolls to it.
    func goTo(line: Int, column: Int = 1) {
        guard let textView else { return }
        let l = min(max(line, 1), lineIndex.lineCount) - 1
        let lineRange = lineIndex.range(ofLine: l)
        let r = NSRange(location: min(lineRange.lowerBound + max(0, column - 1), lineRange.upperBound), length: 0)
        textView.setSelectedRange(r)
        textView.scrollRangeToVisible(r)
        textView.window?.makeFirstResponder(textView)
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }
}
