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
    let animation: EditorAnimation
    let letterFade: Bool

    func makeCoordinator() -> EditorController { EditorController(model: model) }

    func makeNSView(context: Context) -> EditorContainerView {
        let view = EditorContainerView(frame: .zero)
        context.coordinator.undoManager = context.environment.undoManager
        context.coordinator.attach(view)
        context.coordinator.load(document)
        context.coordinator.setLanguage(language)
        view.textView.setAnimation(animation, letterFade: letterFade)
        LaunchTimer.editorShown()
        #if DEBUG || KIRI_SELFTEST
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
        view.textView.setAnimation(animation, letterFade: letterFade)
        c.setCrossfade(animation != .none)
    }
}

/// Owns the text view's behaviour: loading text, tracking lines, the caret
/// position and the font.
@MainActor final class EditorController: NSObject, NSTextViewDelegate, NSTextStorageDelegate,
    NSTextLayoutManagerDelegate {
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
        assert(view.textView.textLayoutManager?.delegate == nil, "the text view already has a layout delegate")
        view.textView.textLayoutManager?.delegate = self
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
            textView?.typingFade.textEdited(range: editedRange, delta: delta)
            highlighter?.lastEdit = editedRange
        }
    }

    // MARK: Layout fragments

    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                                       textLayoutFragmentFor location: any NSTextLocation,
                                       in textElement: NSTextElement) -> NSTextLayoutFragment {
        nonisolated(unsafe) let fragment = FadingLayoutFragment(textElement: textElement, range: textElement.elementRange)
        nonisolated(unsafe) let tlm = textLayoutManager
        nonisolated(unsafe) let element = textElement
        MainActor.assumeIsolated {
            fragment.fade = textView?.typingFade.store
            if let start = element.elementRange?.location {
                // Measured from the caret (animating letters are next to it),
                // not from the start of a possibly huge document.
                fragment.offsetProvider = { [weak tlm, weak textView] in
                    MainActor.assumeIsolated {
                        guard let tlm, let textView,
                              let caret = tlm.textSelections.first?.textRanges.first?.location else { return 0 }
                        return textView.selectedRange().location + tlm.offset(from: caret, to: start)
                    }
                }
            }
        }
        return fragment
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
        let unit = indentUnit(ns)
        let width = unit == "\t" ? 4 : unit.count

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

    /// A tab, or the smallest run of leading spaces among the file's first
    /// indented lines (2 or 4, say).
    private func indentUnit(_ text: NSString) -> String {
        var smallest = Int.max
        var seen = 0
        let head = text.substring(to: min(text.length, 65_536)) as NSString
        head.enumerateLines { line, stop in
            if line.hasPrefix("\t") {
                if seen == 0 { smallest = 0 }
                stop.pointee = true
                return
            }
            let n = line.prefix { $0 == " " }.count
            if n > 0, n < line.count {
                smallest = min(smallest, n)
                seen += 1
                if seen >= 200 { stop.pointee = true }
            }
        }
        if smallest == 0 || smallest == .max { return "\t" }
        return String(repeating: " ", count: min(smallest, 8))
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }
}
