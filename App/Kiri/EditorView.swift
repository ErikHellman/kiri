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
    /// The room the status bar keeps for the position, so it doesn't change
    /// width as the caret moves.
    var positionReserve = StatusText.Reserve()
    /// What the file indents with (what Shift Left and Right use).
    var indent = IndentStyle.tabs
    /// The first-run hint shows: the document is untitled, was empty when
    /// it opened and has had nothing put in it since.
    var showsStartHint = false
    /// The status bar fades while the person types or scrolls.
    let statusRest = StatusBarRest()
    /// The folder sidebar has the keyboard (⇧⌘E moves it there and back).
    var sidebarHasFocus = false
    /// The sidebar shows the keyboard's row: it has the keyboard, in the
    /// key window.
    var sidebarShowsKeyboard = false
    /// Bumped to ask the sidebar to take the keyboard.
    var sidebarFocusRequest = 0
    /// Set by the editor once it exists.
    @ObservationIgnored weak var controller: EditorController?
    /// Find and replace (⌘F) and the command palette (⌘K): the glass bars
    /// that float over the top of the editor, one at a time (opening one
    /// closes the other). Go to Line (⌘L) is the palette's `:` mode, and
    /// `goToLine` what that mode does to the editor.
    let find = FindController()
    let palette = PaletteController()
    let goToLine = GoToLineController()

    init() {
        find.model = self
        goToLine.model = self
        palette.model = self
    }

    /// A bar opened, closed or changed height: the editor keeps what it
    /// scrolls to clear of it.
    func overlayChanged() {
        // (The palette covers some of the text while it lists files and
        // commands, and is gone again; while a line is typed, the line
        // shows below it.)
        controller?.setTopObstruction(find.isOpen ? FindBar.obstruction(replace: find.showsReplace)
                                      : goToLine.isOpen ? CommandPalette.lineObstruction : 0)
    }
}

/// The editor as a SwiftUI view.
struct EditorView: NSViewRepresentable {
    let document: KiriDocument
    let model: EditorModel
    let fontScale: Double
    let language: Language
    /// The document has no file yet.
    let isUntitled: Bool
    let wrapLines: Bool
    let animation: EditorAnimation

    func makeCoordinator() -> EditorController { EditorController(model: model) }

    func makeNSView(context: Context) -> EditorContainerView {
        let view = EditorContainerView(frame: .zero)
        // The document's own undo manager, handed over rather than found
        // in the environment: an edit registered there is what makes the
        // document dirty, and undoing back to the save cleans it.
        context.coordinator.undoManager = document.undoManager
        context.coordinator.attach(view)
        context.coordinator.setUntitled(isUntitled)
        context.coordinator.load(document)
        context.coordinator.setLanguage(language)
        view.textView.setAnimation(animation)
        LaunchTimer.editorShown()
        #if DEBUG || KIRI_SELFTEST
        SelfTest.run(textView: view.textView)
        #endif
        return view
    }

    func updateNSView(_ view: EditorContainerView, context: Context) {
        let c = context.coordinator
        c.undoManager = document.undoManager
        c.setUntitled(isUntitled)
        if c.document !== document { c.load(document) }
        c.setFontScale(fontScale)
        c.setLanguage(language)
        c.setWrap(wrapLines)
        view.textView.setAnimation(animation)
        c.setCrossfade(animation != .none)
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
    /// The longest line the document has had since it loaded (UTF-16
    /// units): it only grows, so the status bar's width does too.
    private var longestLine = 0
    private var indentWork: DispatchWorkItem?
    /// `load` is putting the document's text in.
    private var loading = false
    /// For the first-run hint: nothing has been put in a document that
    /// opened empty, and it has no file.
    private var untouched = false
    private var isUntitled = false
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
        view.onScroll = { [weak self, weak view] in
            self?.highlighter?.visibleRangeChanged()
            view?.textView.marksIfLoaded?.setNeedsUpdate()
        }
        view.onLiveScroll = { [weak self] in self?.model.statusRest.activity() }
        view.onPointer = { [weak self] point, size in self?.model.statusRest.pointerMoved(to: point, in: size) }
        applyFont()
    }

    /// Shows `document`'s text: in a new window, and when the document
    /// reads its file again (File ▸ Revert to Saved), which it says here.
    func load(_ document: KiriDocument) {
        guard let textView, let storage = textView.textStorage else { return }
        if let old = self.document, old !== document, old.editor === self { old.editor = nil }
        self.document = document
        document.editor = self
        let text = document.text
        // The storage delegate fills the index in from this edit: replacing
        // everything (old length) with `text`.
        lineIndex = LineIndex(storage.string)
        loading = true
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(string: text, attributes: textAttributes))
        storage.endEditing()
        loading = false
        longestLine = lineIndex.longestLine
        updateReserve()
        detectIndent()
        untouched = storage.length == 0
        updateStartHint()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        assert(lineIndex.length == storage.length, "line index out of sync")
        container?.gutter.lineIndex = lineIndex
        container?.updateGutterWidth()
        highlighter?.textReplaced()
        updateCaret()
    }

    /// Another document takes this editor (the preview tab going from
    /// file to file): what `EditorView` does for a new one, in its order,
    /// and from the file's first line.
    func show(_ document: KiriDocument) {
        guard self.document !== document else { return }
        // The line asked for was a line of the other file, and what the
        // palette listed was listed for it.
        model.goToLine.documentReplaced()
        model.palette.documentReplaced()
        undoManager = document.undoManager
        setUntitled(document.fileURL == nil)
        load(document)
        let language = document.detectedLanguage
        if model.language != language { model.language = language }
        setLanguage(language)
        if let scroll = textView?.enclosingScrollView {
            scrollOrigin = NSPoint(x: 0, y: -scroll.contentInsets.top)
        }
    }

    func setLanguage(_ language: Language) {
        highlighter?.setLanguage(language)
    }

    func setCrossfade(_ on: Bool) { highlighter?.crossfade = on }

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
        return [.font: font, .foregroundColor: SyntaxHighlighter.fgColor, .paragraphStyle: paragraph]
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
            if !loading { documentEdited(editedRange) }
            highlighter?.lastEdit = editedRange
            model.find.textEdited(old: old, newLength: editedRange.length)
        }
    }

    func textDidChange(_ notification: Notification) {
        if let textView { document?.text = textView.string }
        updateCaret()
        model.statusRest.activity()
    }

    // MARK: What the status bar and the first-run hint follow

    /// The document's text changed in `range` (of the new text), by typing,
    /// pasting, a drop, undo or a command.
    private func documentEdited(_ range: NSRange) {
        // An edit keeps a preview tab: it is the person's file now.
        PreviewTabs.keep(textView?.window)
        // The first-run hint goes with the first character and stays gone.
        if untouched {
            untouched = false
            updateStartHint()
        }
        for line in lineIndex.line(at: range.location)...lineIndex.line(at: NSMaxRange(range)) {
            longestLine = max(longestLine, lineIndex.range(ofLine: line).count)
        }
        updateReserve()
        // The indentation is read from the head of the text: once typing pauses.
        indentWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.detectIndent() }
        indentWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.indentPause, execute: work)
    }

    static let indentPause = 0.3

    /// The model hears of it only when a number of digits changes.
    private func updateReserve() {
        let reserve = StatusText.Reserve(lineCount: lineIndex.lineCount, longestLine: longestLine, length: lineIndex.length)
        if reserve != model.positionReserve { model.positionReserve = reserve }
    }

    private func detectIndent() {
        guard let storage = textView?.textStorage else { return }
        let indent = IndentStyle.detect(in: storage.string)
        if indent != model.indent { model.indent = indent }
    }

    func setUntitled(_ untitled: Bool) {
        guard untitled != isUntitled else { return }
        isUntitled = untitled
        updateStartHint()
    }

    private func updateStartHint() {
        let shows = untouched && isUntitled
        if shows != model.showsStartHint { model.showsStartHint = shows }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateCaret()
        model.find.selectionChanged()
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

    var lineCount: Int { lineIndex.lineCount }

    /// Where a 1-based line (and column) is in the text.
    private func caret(line: Int, column: Int) -> NSRange {
        let l = min(max(line, 1), lineIndex.lineCount) - 1
        let lineRange = lineIndex.range(ofLine: l)
        return NSRange(location: min(lineRange.lowerBound + max(0, column - 1), lineRange.upperBound), length: 0)
    }

    /// Moves the caret to a 1-based line (and column) and scrolls to it.
    func goTo(line: Int, column: Int = 1) {
        guard let textView else { return }
        let r = caret(line: line, column: column)
        textView.setSelectedRange(r)
        textView.scrollRangeToVisible(r)
        textView.window?.makeFirstResponder(textView)
    }

    /// Go to Line's preview: the caret on that line and the line in sight
    /// and marked (a pulse, or a steady band without motion), while the
    /// keyboard stays in the Go to Line field.
    func previewLine(_ line: Int, column: Int = 1) {
        guard let textView else { return }
        let r = caret(line: line, column: column)
        textView.setSelectedRange(r)
        reveal(r)
        textView.marks.showLine(true, pulse: textView.animation == .full)
    }

    /// Replaces `range` with `string` as one undoable edit (find and
    /// replace). False when the text view refuses the edit.
    func replaceText(in range: NSRange, with string: String, actionName: String) -> Bool {
        guard let textView, let storage = textView.textStorage, NSMaxRange(range) <= storage.length,
              textView.shouldChangeText(in: range, replacementString: string) else { return false }
        // Its own undo step, not part of the typing before it.
        textView.breakUndoCoalescing()
        storage.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: textAttributes))
        textView.didChangeText()
        textView.undoManager?.setActionName(actionName)
        return true
    }

    /// ⌘] / ⌘[: indents or outdents every line the selection touches, as
    /// one undoable edit, with the file's own indent (a tab, or its spaces).
    func shiftLines(right: Bool) {
        guard let textView, let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        // A selection that ends at a line start doesn't take that line along.
        var probe = sel
        if probe.length > 0, ns.character(at: NSMaxRange(probe) - 1) == 0x0A { probe.length -= 1 }
        let block = ns.lineRange(for: probe)
        let old = ns.substring(with: block)
        // The file's own indent, as the status bar names it.
        let style = IndentStyle.detect(in: storage.string)
        let unit = style.unit
        let width = style.width

        var lines = old.components(separatedBy: "\n")
        let endsWithNewline = old.hasSuffix("\n")
        if endsWithNewline { lines.removeLast() }
        var firstDelta = 0
        for i in lines.indices {
            let line = lines[i]
            var delta = 0
            if right {
                // Blank lines stay blank, unless the caret is on one.
                guard !line.isEmpty || lines.count == 1 else { continue }
                lines[i] = unit + line
                delta = (unit as NSString).length
            } else if line.hasPrefix("\t") {
                lines[i] = String(line.dropFirst())
                delta = -1
            } else {
                let spaces = min(width, line.prefix { $0 == " " }.count)
                lines[i] = String(line.dropFirst(spaces))
                delta = -spaces
            }
            if i == 0 { firstDelta = delta }
        }
        let new = lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        guard new != old, textView.shouldChangeText(in: block, replacementString: new) else { return }
        storage.replaceCharacters(in: block, with: NSAttributedString(string: new, attributes: textAttributes))
        textView.didChangeText()
        textView.undoManager?.setActionName(right ? "Shift Right" : "Shift Left")

        let newLength = (new as NSString).length
        if sel.length == 0 {
            textView.setSelectedRange(NSRange(location: max(block.location, sel.location + firstDelta), length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: block.location, length: newLength - (endsWithNewline ? 1 : 0)))
        }
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// ⌘/: comments the lines the selection touches (or the caret's), or
    /// uncomments them if every one that isn't blank is commented
    /// (`CommentToggle`), in the language's own way. One undoable edit;
    /// the selection stays on the text it was on.
    func toggleComment() {
        guard let textView, let storage = textView.textStorage, let syntax = model.language.comment else { return }
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        // A selection that ends at a line start doesn't take that line along.
        var probe = sel
        if probe.length > 0, ns.character(at: NSMaxRange(probe) - 1) == 0x0A { probe.length -= 1 }
        let block = ns.lineRange(for: probe)
        let old = ns.substring(with: block)
        let inBlock = (sel.location - block.location)..<(NSMaxRange(sel) - block.location)
        guard let result = CommentToggle.toggle(old, syntax: syntax, selection: inBlock), result.text != old,
              textView.shouldChangeText(in: block, replacementString: result.text) else { return }
        // Its own undo step, not part of the typing before it.
        textView.breakUndoCoalescing()
        storage.replaceCharacters(in: block, with: NSAttributedString(string: result.text, attributes: textAttributes))
        textView.didChangeText()
        textView.undoManager?.setActionName("Toggle Comment")
        textView.setSelectedRange(NSRange(location: block.location + result.selection.lowerBound, length: result.selection.count))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }
}
