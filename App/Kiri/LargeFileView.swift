import AppKit
import CoreText
import KiriKit

// The read-only viewer of a large file (`KiriDocument.isLargeFile`): a log
// of many GB, for reading and searching, never for editing. It is not an
// NSTextView, which would want the whole text in memory: the lines come
// from `LargeFile` as they are drawn, and only the lines on screen are.
//
// It keeps its own scroll position, as a line number, instead of sitting in
// an NSScrollView: a file of 100 million lines would be a document view
// some 2·10⁹ points tall, more than the layer tree can place exactly. Lines
// don't wrap, and a very long line shows only its start
// (`LargeFile.displayLimit`). Nothing animates.

/// A place in the text: a line, and a UTF-16 offset in what shows of it.
struct LargePosition: Comparable, Hashable {
    var line: Int
    var column: Int

    static func < (a: Self, b: Self) -> Bool { a.line != b.line ? a.line < b.line : a.column < b.column }
}

@MainActor final class LargeFileView: NSView, NSMenuItemValidation {
    private(set) var file: LargeFile
    weak var model: EditorModel?

    // MARK: Looks

    private var font = EditorFont.font("", size: Honey.editorFontSize)
    private var gutterFont = EditorFont.gutterFont("", size: 11)
    private var lineHeight: CGFloat = 18
    private var ascent: CGFloat = 13
    /// Above the first line and to the left of the text, as in the editor.
    private let topInset: CGFloat = 14
    private let textInset: CGFloat = 6
    /// Room for the floating status bar under the last line.
    private let bottomInset: CGFloat = 44

    // MARK: State

    /// The line at the top, with how far it has scrolled out of sight.
    private(set) var topLine: Double = 0
    private var scrollX: CGFloat = 0
    /// The widest line seen so far: how far the text scrolls sideways.
    private var widest: CGFloat = 0
    private(set) var anchor = LargePosition(line: 0, column: 0)
    private(set) var caret = LargePosition(line: 0, column: 0)
    /// Matches to paint (byte ranges, in order) and the current one.
    private var matches: [Range<Int>] = []
    private var currentMatch: Range<Int>?
    /// A line Go to Line is showing.
    private var markedLine: Int?

    /// Lines as last read: their bytes in the file, their text and its layout.
    private struct Line {
        let bytes: Range<Int>
        let text: String
        var layout: CTLine?
    }
    private var cache: [Int: Line] = [:]
    private var cacheAttributes: [NSAttributedString.Key: Any] = [:]

    private var scrollerShown: CGFloat = 0
    private var scrollerFade: Timer?
    private var draggingScroller: (start: CGFloat, top: Double)?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(file: LargeFile) {
        self.file = file
        super.init(frame: .zero)
        setAccessibilityLabel("Read-only text")
        setAccessibilityRole(.textArea)
        registerForDraggedTypes(FileDrop.types)
        applyFont(family: "", scale: 1)
        observers.append(NotificationCenter.default.addObserver(forName: .honeyThemeDidChange, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.colorsChanged() }
        })
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    /// The file was opened again (it was truncated or rotated): from the top.
    func replaceFile(_ new: LargeFile) {
        file = new
        cache = [:]
        topLine = 0
        scrollX = 0
        anchor = LargePosition(line: 0, column: 0)
        caret = anchor
        matches = []
        currentMatch = nil
        needsDisplay = true
        caretMoved()
    }

    /// More lines were counted (the count is under way, or the file grew).
    /// At the end, the view stays at the end, as `tail -f` does.
    func linesAdded(previousCount: Int) {
        let wasAtEnd = topLine >= maxTop(lineCount: previousCount) - 0.5 && previousCount > visibleLineCount
        // The last line may have been cut short while it was being written.
        cache.removeValue(forKey: previousCount - 1)
        if wasAtEnd { topLine = maxTop() }
        model?.lineCount = file.lineCount
        needsDisplay = true
    }

    // MARK: Fonts and colors

    func applyFont(family: String, scale: Double) {
        font = EditorFont.font(family, size: Honey.editorFontSize * scale)
        gutterFont = EditorFont.gutterFont(family, size: max(9, 11 * scale))
        ascent = font.ascender
        lineHeight = ceil((font.ascender - font.descender + font.leading) * 1.18)
        cache = [:]
        widest = 0
        needsDisplay = true
    }

    private func colorsChanged() {
        cache = [:]
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colorsChanged()
    }

    // MARK: Geometry

    private var visibleLineCount: Int { max(1, Int((bounds.height - topInset - bottomInset) / lineHeight)) }

    /// The top line that shows the last line just above the status bar.
    private func maxTop(lineCount: Int? = nil) -> Double {
        let count = Double(lineCount ?? file.lineCount)
        return max(0, count - Double(bounds.height - topInset - bottomInset) / Double(lineHeight))
    }

    var gutterWidth: CGFloat {
        let digits = max(3, String(file.lineCount).count)
        let w = (String(repeating: "8", count: digits) as NSString).size(withAttributes: [.font: gutterFont]).width
        return ceil(w) + 22
    }

    private var textLeft: CGFloat { gutterWidth + textInset }

    /// The top of `line`, in this view.
    private func y(of line: Int) -> CGFloat { topInset + CGFloat(Double(line) - topLine) * lineHeight }

    private func line(atY y: CGFloat) -> Int {
        let line = Int(floor(Double((y - topInset) / lineHeight) + topLine))
        return min(max(0, line), file.lineCount - 1)
    }

    private func setTop(_ value: Double) {
        let clamped = min(max(0, value), maxTop())
        guard clamped != topLine else { return }
        topLine = clamped
        needsDisplay = true
        showScroller()
    }

    private func setScrollX(_ value: CGFloat) {
        let room = max(0, widest + textInset * 2 - (bounds.width - textLeft))
        let clamped = min(max(0, value), room)
        guard clamped != scrollX else { return }
        scrollX = clamped
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        topLine = min(topLine, maxTop())
    }

    // MARK: Lines

    /// The lines `range`, read now if they aren't at hand.
    private func lines(_ range: Range<Int>) -> [Int: Line] {
        let wanted = max(0, range.lowerBound)..<min(range.upperBound, file.lineCount)
        guard !wanted.isEmpty else { return [:] }
        if wanted.contains(where: { cache[$0] == nil }) {
            // Some to spare above and below, for scrolling.
            let read = max(0, wanted.lowerBound - 64)..<min(file.lineCount, wanted.upperBound + 64)
            if cache.count > 4000 { cache = [:] }
            for (i, l) in file.textLines(read).enumerated() where cache[read.lowerBound + i] == nil {
                cache[read.lowerBound + i] = Line(bytes: l.bytes, text: l.text)
            }
        }
        var out: [Int: Line] = [:]
        for i in wanted { out[i] = cache[i] }
        return out
    }

    private func line(_ i: Int) -> Line? { lines(i..<(i + 1))[i] }

    private var textAttributes: [NSAttributedString.Key: Any] {
        var color = CGColor(gray: 0, alpha: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.honey(Honey.fg).cgColor }
        return [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
    }

    /// The layout of line `i`, made once.
    private func layout(_ i: Int) -> CTLine? {
        guard var l = line(i) else { return nil }
        if let layout = l.layout { return layout }
        let layout = CTLineCreateWithAttributedString(NSAttributedString(string: l.text, attributes: textAttributes))
        l.layout = layout
        cache[i] = l
        return layout
    }

    private func x(ofColumn column: Int, in layout: CTLine) -> CGFloat {
        CTLineGetOffsetForStringIndex(layout, column, nil)
    }

    /// The UTF-16 column of byte `offset` (in the file) on line `i`.
    private func column(ofByte offset: Int, line i: Int) -> Int {
        guard let l = line(i) else { return 0 }
        let k = min(max(0, offset - l.bytes.lowerBound), l.text.utf8.count)
        let utf8 = l.text.utf8
        return utf8.index(utf8.startIndex, offsetBy: k).utf16Offset(in: l.text)
    }

    /// The byte offset (in the file) of `p`.
    private func byte(of p: LargePosition) -> Int {
        guard let l = line(p.line) else { return file.size }
        let utf16 = l.text.utf16
        let column = min(p.column, utf16.count)
        let index = utf16.index(utf16.startIndex, offsetBy: column)
        return l.bytes.lowerBound + l.text.utf8.distance(from: l.text.utf8.startIndex, to: index)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let first = max(0, Int(floor(topLine)))
        let count = Int(ceil(bounds.height / lineHeight)) + 2
        let shown = lines(first..<(first + count))
        let gutter = gutterWidth
        let selection = min(anchor, caret)..<max(anchor, caret)

        // The text, clipped to the right of the gutter.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: gutter, y: 0, width: bounds.width - gutter, height: bounds.height))
        for i in first..<(first + count) {
            guard let l = shown[i] else { continue }
            let top = y(of: i)
            guard top < dirtyRect.maxY, top + lineHeight > dirtyRect.minY else { continue }
            let band = CGRect(x: gutter, y: top, width: bounds.width - gutter, height: lineHeight)
            if i == markedLine {
                NSColor.honey(Honey.accentSoft).setFill()
                band.fill()
            } else if selection.isEmpty, i == caret.line {
                NSColor.honey(Honey.currentLine).setFill()
                band.fill()
            }
            guard let layout = layout(i) else { continue }
            let left = textLeft - scrollX
            let width = CTLineGetTypographicBounds(layout, nil, nil, nil)
            if CGFloat(width) > widest { widest = CGFloat(width) }
            // What is selected of this line.
            if !selection.isEmpty, i >= selection.lowerBound.line, i <= selection.upperBound.line {
                let from = i == selection.lowerBound.line ? x(ofColumn: selection.lowerBound.column, in: layout) : 0
                let to = i == selection.upperBound.line ? x(ofColumn: selection.upperBound.column, in: layout)
                    : CGFloat(width) + 6
                NSColor.honey(Honey.selection).setFill()
                CGRect(x: left + from, y: top, width: max(0, to - from), height: lineHeight).fill()
            }
            drawMatches(in: l, line: i, layout: layout, left: left, top: top)
            ctx.saveGState()
            // Core Text draws upward from its baseline.
            ctx.textMatrix = .identity
            ctx.translateBy(x: left, y: top + (lineHeight - (font.ascender - font.descender)) / 2 + ascent)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(layout, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // The line numbers.
        let muted: [NSAttributedString.Key: Any] = [.font: gutterFont, .foregroundColor: NSColor.honey(Honey.gutter)]
        let current: [NSAttributedString.Key: Any] = [.font: gutterFont, .foregroundColor: NSColor.honey(Honey.fg)]
        for i in first..<min(first + count, file.lineCount) {
            let s = String(i + 1) as NSString
            let attrs = i == caret.line ? current : muted
            let size = s.size(withAttributes: attrs)
            let baseline = y(of: i) + (lineHeight - (font.ascender - font.descender)) / 2 + ascent
            s.draw(at: NSPoint(x: gutter - size.width - 12, y: baseline - gutterFont.ascender), withAttributes: attrs)
        }

        drawScroller()
    }

    private func drawMatches(in l: Line, line i: Int, layout: CTLine, left: CGFloat, top: CGFloat) {
        guard !matches.isEmpty || currentMatch != nil else { return }
        var lo = 0, hi = matches.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if matches[mid].upperBound <= l.bytes.lowerBound { lo = mid + 1 } else { hi = mid }
        }
        var here: [Range<Int>] = []
        while lo < matches.count, matches[lo].lowerBound <= l.bytes.upperBound {
            here.append(matches[lo])
            lo += 1
        }
        if let currentMatch, currentMatch.overlaps(l.bytes) || currentMatch.lowerBound == l.bytes.lowerBound {
            here.append(currentMatch)
        }
        for m in here {
            let from = x(ofColumn: column(ofByte: m.lowerBound, line: i), in: layout)
            let to = x(ofColumn: column(ofByte: m.upperBound, line: i), in: layout)
            let rect = CGRect(x: left + from - 1, y: top + 1, width: max(4, to - from + 2), height: lineHeight - 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            if m == currentMatch {
                NSColor.honey(Honey.selection).setFill()
                path.fill()
                NSColor.honey(Honey.accent).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            } else {
                NSColor.honey(Honey.accentSoft).setFill()
                path.fill()
            }
        }
    }

    // MARK: The scroller

    private var scrollerTrack: CGRect {
        CGRect(x: bounds.width - 12, y: topInset / 2, width: 12, height: bounds.height - topInset / 2 - bottomInset)
    }

    private var scrollerKnob: CGRect? {
        let total = maxTop()
        guard total > 0 else { return nil }
        let track = scrollerTrack
        let visible = Double(visibleLineCount)
        let height = max(28, track.height * CGFloat(visible / (visible + total)))
        let y = track.minY + (track.height - height) * CGFloat(topLine / total)
        return CGRect(x: track.maxX - 9, y: y, width: 7, height: height)
    }

    private func drawScroller() {
        guard scrollerShown > 0, let knob = scrollerKnob else { return }
        NSColor.honey(Honey.gutter).withAlphaComponent(0.55 * scrollerShown).setFill()
        NSBezierPath(roundedRect: knob, xRadius: 3.5, yRadius: 3.5).fill()
    }

    private func showScroller() {
        scrollerShown = 1
        scrollerFade?.invalidate()
        scrollerFade = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.draggingScroller == nil else { return }
                self.scrollerShown = 0
                self.needsDisplay = true
            }
        }
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        let dy = precise ? event.scrollingDeltaY : event.scrollingDeltaY * lineHeight * 3
        let dx = precise ? event.scrollingDeltaX : event.scrollingDeltaX * lineHeight * 3
        if abs(dy) >= abs(dx) {
            setTop(topLine - Double(dy / lineHeight))
        } else {
            setScrollX(scrollX - dx)
        }
        model?.statusRest.activity()
    }

    /// Brings `line` into sight: in the middle when it is far off.
    func reveal(line: Int, column: Int? = nil) {
        let visible = Double(bounds.height - topInset - bottomInset) / Double(lineHeight)
        if Double(line) < topLine || Double(line) + 1 > topLine + visible {
            setTop(Double(line) - visible / 2)
        }
        if let column, let layout = layout(line) {
            let x = self.x(ofColumn: column, in: layout)
            let width = bounds.width - textLeft - 24
            if x < scrollX || x > scrollX + width { setScrollX(x - width / 3) }
        }
        needsDisplay = true
    }

    // MARK: The pointer

    private func position(at point: NSPoint) -> LargePosition {
        let i = line(atY: point.y)
        guard let layout = layout(i) else { return LargePosition(line: i, column: 0) }
        let x = point.x - textLeft + scrollX
        var column = CTLineGetStringIndexForPosition(layout, CGPoint(x: max(0, x), y: 0))
        if column == kCFNotFound { column = 0 }
        return LargePosition(line: i, column: column)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let knob = scrollerKnob, scrollerTrack.contains(point) {
            if knob.contains(point) {
                draggingScroller = (point.y, topLine)
            } else {
                // A click in the track pages there.
                setTop(topLine + (point.y < knob.minY ? -1 : 1) * Double(visibleLineCount))
            }
            showScroller()
            return
        }
        var p = position(at: point)
        switch event.clickCount {
        case 2:
            // The word.
            if let l = line(p.line) {
                let (from, to) = Self.word(in: l.text, at: p.column)
                setSelection(anchor: LargePosition(line: p.line, column: from), caret: LargePosition(line: p.line, column: to))
            }
            return
        case 3:
            let length = line(p.line)?.text.utf16.count ?? 0
            setSelection(anchor: LargePosition(line: p.line, column: 0), caret: LargePosition(line: p.line, column: length))
            return
        default: break
        }
        if event.modifierFlags.contains(.shift) {
            setSelection(anchor: anchor, caret: p)
        } else {
            setSelection(anchor: p, caret: p)
        }
        p = caret
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let drag = draggingScroller, let knob = scrollerKnob {
            let room = scrollerTrack.height - knob.height
            guard room > 0 else { return }
            setTop(drag.top + Double((point.y - drag.start) / room) * maxTop())
            showScroller()
            return
        }
        // Past the top or the bottom, the text scrolls along.
        if point.y < 0 { setTop(topLine - max(1, Double(-point.y / lineHeight))) }
        if point.y > bounds.height - bottomInset / 2 { setTop(topLine + max(1, Double((point.y - bounds.height) / lineHeight))) }
        if point.x > bounds.width { setScrollX(scrollX + 20) }
        if point.x < textLeft { setScrollX(scrollX - 20) }
        setSelection(anchor: anchor, caret: position(at: point))
    }

    override func mouseUp(with event: NSEvent) {
        if draggingScroller != nil {
            draggingScroller = nil
            showScroller()
        }
    }

    override func resetCursorRects() {
        let track = scrollerTrack
        addCursorRect(CGRect(x: gutterWidth, y: 0, width: track.minX - gutterWidth, height: bounds.height), cursor: .iBeam)
    }

    /// The word at `column`: letters, digits and underscores, or the one
    /// character there.
    static func word(in text: String, at column: Int) -> (Int, Int) {
        let units = Array(text.utf16)
        guard column < units.count else { return (units.count, units.count) }
        func isWord(_ u: UInt16) -> Bool {
            guard let s = Unicode.Scalar(u) else { return false }
            return CharacterSet.alphanumerics.contains(s) || u == 0x5F
        }
        guard isWord(units[column]) else { return (column, column + 1) }
        var from = column, to = column
        while from > 0, isWord(units[from - 1]) { from -= 1 }
        while to < units.count, isWord(units[to]) { to += 1 }
        return (from, to)
    }

    // MARK: Selection

    func setSelection(anchor: LargePosition, caret: LargePosition) {
        self.anchor = anchor
        self.caret = caret
        needsDisplay = true
        caretMoved()
        model?.find.selectionChanged()
    }

    /// The selection as byte offsets in the file.
    var selectedBytes: Range<Int> {
        let a = byte(of: anchor), b = byte(of: caret)
        return min(a, b)..<max(a, b)
    }

    /// Selects the bytes `range` (a match) and brings it into sight.
    func select(bytes range: Range<Int>, caretOnly: Bool = false) {
        let line = file.line(containing: range.lowerBound)
        let from = LargePosition(line: line, column: column(ofByte: range.lowerBound, line: line))
        let endLine = file.line(containing: range.upperBound)
        let to = caretOnly ? from : LargePosition(line: endLine, column: column(ofByte: range.upperBound, line: endLine))
        self.anchor = from
        self.caret = to
        reveal(line: line, column: from.column)
        caretMoved()
    }

    private func caretMoved() {
        guard let model else { return }
        model.line = caret.line + 1
        model.column = caret.column + 1
        let selected = anchor == caret ? 0 : selectedBytes.count
        model.selectedLength = selected
        model.lineCount = file.lineCount
    }

    /// The selected text, or nil (with a beep) for more than copying should take.
    private var selectedText: String? {
        let range = selectedBytes
        guard !range.isEmpty else { return nil }
        guard range.count <= Self.copyLimit else {
            NSSound.beep()
            return nil
        }
        return String(decoding: file.read(range), as: UTF8.self)
    }

    /// The most a copy takes.
    static let copyLimit = 256 << 20

    /// The caret to 0-based `line` and `column`, in sight.
    func goTo(line: Int, column: Int) {
        let i = min(max(0, line), file.lineCount - 1)
        let p = LargePosition(line: i, column: min(max(0, column), self.line(i)?.text.utf16.count ?? 0))
        setSelection(anchor: p, caret: p)
        reveal(line: i, column: p.column)
    }

    /// Where the view is: for Go to Line to go back to.
    var place: (anchor: LargePosition, caret: LargePosition, top: Double) { (anchor, caret, topLine) }

    func restore(_ place: (anchor: LargePosition, caret: LargePosition, top: Double)) {
        setSelection(anchor: place.anchor, caret: place.caret)
        setTop(place.top)
    }

    // MARK: Lines marked by Go to Line

    func mark(line: Int?) {
        markedLine = line
        if let line { reveal(line: line) }
        needsDisplay = true
    }

    var scrollState: Double {
        get { topLine }
        set { setTop(newValue) }
    }

    // MARK: Matches

    func show(matches: [Range<Int>], current: Range<Int>?) {
        self.matches = matches
        currentMatch = current
        needsDisplay = true
    }

    // MARK: Keys and commands

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    // Typing does nothing: the file is read-only.
    override func insertText(_ insertString: Any) { NSSound.beep() }
    override func doCommand(by selector: Selector) {
        if responds(to: selector) { perform(selector, with: nil) }
    }

    private func moveCaret(lines: Int, extend: Bool) {
        let target = min(max(0, caret.line + lines), file.lineCount - 1)
        let p = LargePosition(line: target, column: min(caret.column, line(target)?.text.utf16.count ?? 0))
        setSelection(anchor: extend ? anchor : p, caret: p)
        reveal(line: target)
    }

    private func moveCaret(columns: Int, extend: Bool) {
        let length = line(caret.line)?.text.utf16.count ?? 0
        var p = caret
        p.column += columns
        if p.column < 0 {
            if p.line > 0 { p.line -= 1; p.column = line(p.line)?.text.utf16.count ?? 0 } else { p.column = 0 }
        } else if p.column > length {
            if p.line < file.lineCount - 1 { p.line += 1; p.column = 0 } else { p.column = length }
        }
        setSelection(anchor: extend ? anchor : p, caret: p)
        reveal(line: p.line, column: p.column)
    }

    override func moveUp(_ sender: Any?) { moveCaret(lines: -1, extend: false) }
    override func moveDown(_ sender: Any?) { moveCaret(lines: 1, extend: false) }
    override func moveUpAndModifySelection(_ sender: Any?) { moveCaret(lines: -1, extend: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { moveCaret(lines: 1, extend: true) }
    override func moveLeft(_ sender: Any?) { moveCaret(columns: -1, extend: false) }
    override func moveRight(_ sender: Any?) { moveCaret(columns: 1, extend: false) }
    override func moveLeftAndModifySelection(_ sender: Any?) { moveCaret(columns: -1, extend: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { moveCaret(columns: 1, extend: true) }
    override func pageDown(_ sender: Any?) { moveCaret(lines: visibleLineCount - 1, extend: false) }
    override func pageUp(_ sender: Any?) { moveCaret(lines: -(visibleLineCount - 1), extend: false) }
    override func scrollPageDown(_ sender: Any?) { setTop(topLine + Double(visibleLineCount - 1)) }
    override func scrollPageUp(_ sender: Any?) { setTop(topLine - Double(visibleLineCount - 1)) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { setTop(0) }
    override func scrollToEndOfDocument(_ sender: Any?) { setTop(maxTop()) }
    override func scrollLineUp(_ sender: Any?) { setTop(topLine - 1) }
    override func scrollLineDown(_ sender: Any?) { setTop(topLine + 1) }
    override func moveToBeginningOfDocument(_ sender: Any?) { moveCaret(lines: -file.lineCount, extend: false) }
    override func moveToEndOfDocument(_ sender: Any?) { moveCaret(lines: file.lineCount, extend: false) }
    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { moveCaret(lines: -file.lineCount, extend: true) }
    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { moveCaret(lines: file.lineCount, extend: true) }
    override func moveToBeginningOfLine(_ sender: Any?) {
        let p = LargePosition(line: caret.line, column: 0)
        setSelection(anchor: p, caret: p)
        reveal(line: p.line, column: 0)
    }
    override func moveToEndOfLine(_ sender: Any?) {
        let p = LargePosition(line: caret.line, column: line(caret.line)?.text.utf16.count ?? 0)
        setSelection(anchor: p, caret: p)
        reveal(line: p.line, column: p.column)
    }
    override func moveToLeftEndOfLine(_ sender: Any?) { moveToBeginningOfLine(sender) }
    override func moveToRightEndOfLine(_ sender: Any?) { moveToEndOfLine(sender) }

    override func selectAll(_ sender: Any?) {
        let last = file.lineCount - 1
        setSelection(anchor: LargePosition(line: 0, column: 0),
                     caret: LargePosition(line: last, column: line(last)?.text.utf16.count ?? 0))
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return anchor != caret
        case #selector(selectAll(_:)): return true
        case #selector(performFindPanelAction(_:)), #selector(performTextFinderAction(_:)): return true
        default: return responds(to: item.action)
        }
    }

    // Find is Kiri's own bar, as in the editor (`KiriTextView`).
    @objc func performFindPanelAction(_ sender: Any?) { performTextFinderAction(sender) }

    override func performTextFinderAction(_ sender: Any?) {
        guard let find = model?.find, let tag = (sender as? NSValidatedUserInterfaceItem)?.tag,
              let action = NSTextFinder.Action(rawValue: tag) else { return }
        switch action {
        case .showFindInterface: find.perform(.show)
        case .nextMatch: find.perform(.next)
        case .previousMatch: find.perform(.previous)
        case .setSearchString: find.perform(.useSelection)
        case .hideFindInterface: find.perform(.close)
        default: NSSound.beep()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if let model, model.find.isOpen {
            model.find.close()
        } else if let model, model.palette.isOpen {
            model.palette.cancel()
        } else if let model, model.goToLine.isOpen {
            model.goToLine.cancel()
        } else if let model, WhatsNew.shared.shows(in: model) {
            WhatsNew.shared.close()
        }
    }

    override func becomeFirstResponder() -> Bool {
        model?.find.editorFocusChanged(hasFocus: true)
        model?.palette.editorTookKeyboard()
        return true
    }

    override func resignFirstResponder() -> Bool {
        model?.find.editorFocusChanged(hasFocus: false)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            let responder = window.firstResponder
            if responder === window || responder == nil { window.makeFirstResponder(self) }
        }
    }

    // MARK: Drops

    // Files dropped on the text open, as anywhere else on the window.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { FileDrop.operation(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { FileDrop.operation(sender) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !FileDrop.operation(sender).isEmpty }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let window else { return false }
        return FileDrop.perform(sender, in: window)
    }
}
