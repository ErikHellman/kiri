import AppKit
import KiriKit
import os

// The editor: an NSTextView on TextKit 2, with a line-number gutter beside
// it, on the solid Honey surface. Nothing here touches `layoutManager`, which
// would silently switch the text view back to TextKit 1.

/// The text view: Honey caret, selection and current-line colors.
final class KiriTextView: NSTextView {
    /// Paints the caret's line. Off while there is a selection.
    var highlightsCurrentLine = true {
        didSet { if oldValue != highlightsCurrentLine { effects?.update() } }
    }
    /// Typing animations (caret, current line, bracket pulse), or nil.
    private(set) var effects: EditorEffects?
    private var keyObservers: [NSObjectProtocol] = []

    /// Typed letters fade in (drawn by `FadingLayoutFragment`).
    private(set) lazy var typingFade = TypingFade(textView: self)

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        let length = (typed as NSString).length
        guard length > 0, !typed.contains("\n"), selectedRange().length == 0 else { return }
        typingFade.typed(NSRange(location: selectedRange().location - length, length: length))
    }

    func setAnimation(_ mode: EditorAnimation, letterFade: Bool = false) {
        typingFade.mode = letterFade ? mode : .none
        guard mode != (effects?.mode ?? .none) else { return }
        effects?.remove()
        effects = nil
        if mode == .none {
            insertionPointColor = .honey(Honey.caret)
        } else {
            effects = EditorEffects(textView: self, mode: mode)
            // The caret layer replaces the system caret.
            insertionPointColor = .clear
            effects?.update(animated: false)
        }
        needsDisplay = true
    }

    /// Whether the caret should show: this view has focus in the key window.
    var isCaretActive: Bool {
        (window?.isKeyWindow == true || Self.forceCaretActive) && window?.firstResponder === self
    }
    /// Self-test pictures are taken while the window may not be key.
    nonisolated(unsafe) static var forceCaretActive = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard let window else { return }
        // Type right away in a new window or tab.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window.firstResponder === window || window.firstResponder == nil else { return }
            window.makeFirstResponder(self)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.effects?.update(animated: false) }
            })
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        effects?.update(animated: false)
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.effects?.update(animated: false) }
        return ok
    }

    override func layout() {
        super.layout()
        effects?.update(animated: false)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard effects == nil, highlightsCurrentLine, let lineRect = currentLineRect(), lineRect.intersects(rect)
        else { return }
        NSColor.honey(Honey.currentLine).setFill()
        lineRect.fill()
    }

    /// The rect of the visual line holding the caret, full width.
    func currentLineRect() -> NSRect? {
        guard selectedRange().length == 0, let tlm = textLayoutManager,
              let caret = tlm.textSelections.first?.textRanges.first?.location else { return nil }
        let documentEnd = tlm.documentRange.endLocation
        var location = caret
        // At the very end the caret sits in the last fragment (or its extra line).
        if caret.compare(documentEnd) == .orderedSame, caret.compare(tlm.documentRange.location) != .orderedSame,
           let before = tlm.location(caret, offsetBy: -1) {
            location = before
        }
        guard let fragment = tlm.textLayoutFragment(for: location) else {
            // Empty document: one line at the top.
            let h = font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 16
            return NSRect(x: 0, y: textContainerOrigin.y, width: bounds.width, height: h)
        }
        let frame = fragment.layoutFragmentFrame
        let offsetInFragment = tlm.offset(from: fragment.rangeInElement.location, to: caret)
        let lines = fragment.textLineFragments
        var lineFragment = lines.last
        for line in lines {
            let r = line.characterRange
            if offsetInFragment >= r.location && offsetInFragment < r.location + r.length {
                lineFragment = line
                break
            }
        }
        guard let lineFragment else { return nil }
        let bounds = lineFragment.typographicBounds
        return NSRect(x: 0, y: frame.minY + bounds.minY + textContainerOrigin.y, width: self.bounds.width,
                      height: bounds.height)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        guard let effects else {
            let old = currentLineRect()
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
            if let old { setNeedsDisplay(old) }
            if let new = currentLineRect() { setNeedsDisplay(new) }
            return
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // After layout catches up with any edit that moved the caret.
        DispatchQueue.main.async { [weak self, weak effects] in
            guard self != nil else { return }
            effects?.update()
            if !stillSelecting { effects?.pulseMatchingBracket() }
        }
    }

    override func didChangeText() {
        super.didChangeText()
        if effects == nil { setNeedsDisplay(visibleRect) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effects?.updateColors()
        needsDisplay = true
    }
}

/// Line numbers for the visible part of a TextKit 2 text view.
final class LineNumberGutter: NSView {
    weak var textView: KiriTextView?
    var lineIndex = LineIndex()
    var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var currentLine = 0 {
        didSet { if currentLine != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// Wide enough for the largest line number, with room on both sides.
    var requiredWidth: CGFloat {
        let digits = max(3, String(lineIndex.lineCount).count)
        let w = (String(repeating: "8", count: digits) as NSString).size(withAttributes: [.font: font]).width
        return ceil(w) + 22
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let tlm = textView.textLayoutManager,
              let scrollView = textView.enclosingScrollView else { return }
        let visible = scrollView.contentView.bounds
        let originY = textView.textContainerOrigin.y - visible.minY
        let muted: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.honey(Honey.gutter)]
        let current: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.honey(Honey.fg)]
        let string = textView.string as NSString
        let length = string.length
        // Never draw from an index that doesn't match the text (mid-edit).
        guard lineIndex.length == length else { return }
        let endsWithNewline = length > 0 && string.character(at: length - 1) == 0x0A

        func drawNumber(_ n: Int, lineTop: CGFloat, lineHeight: CGFloat, baseline: CGFloat) {
            let s = String(n) as NSString
            let attrs = n - 1 == currentLine ? current : muted
            let size = s.size(withAttributes: attrs)
            // Align baselines with the text.
            let y = originY + lineTop + baseline - font.ascender
            guard y + size.height >= dirtyRect.minY, y <= dirtyRect.maxY else { return }
            s.draw(at: NSPoint(x: bounds.width - size.width - 12, y: y), withAttributes: attrs)
            _ = lineHeight
        }

        if length == 0 {
            let f = textView.font ?? font
            drawNumber(1, lineTop: 0, lineHeight: f.ascender - f.descender, baseline: f.ascender)
            return
        }

        // Start at the fragment at the top of the visible area.
        let topPoint = CGPoint(x: 0, y: max(0, visible.minY - textView.textContainerOrigin.y))
        let start = tlm.textLayoutFragment(for: topPoint)?.rangeInElement.location ?? tlm.documentRange.location
        let bottom = visible.maxY - textView.textContainerOrigin.y
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > bottom { return false }
            let offset = tlm.offset(from: tlm.documentRange.location, to: fragment.rangeInElement.location)
            let line = lineIndex.line(at: offset)
            let lines = fragment.textLineFragments
            if let first = lines.first {
                let b = first.typographicBounds
                drawNumber(line + 1, lineTop: frame.minY + b.minY, lineHeight: b.height,
                           baseline: first.glyphOrigin.y)
            }
            // The empty line after a final newline is an extra line fragment.
            let fragmentEnd = tlm.offset(from: tlm.documentRange.location, to: fragment.rangeInElement.endLocation)
            if fragmentEnd >= length, endsWithNewline, lines.count > 1, let extra = lines.last,
               extra.characterRange.length == 0 {
                let b = extra.typographicBounds
                drawNumber(lineIndex.lineCount, lineTop: frame.minY + b.minY, lineHeight: b.height,
                           baseline: extra.glyphOrigin.y)
            }
            return true
        }
    }
}

/// The gutter and the scrolling text view side by side.
final class EditorContainerView: NSView {
    let scrollView = NSScrollView()
    let textView: KiriTextView
    let gutter = LineNumberGutter()
    private var gutterWidth: NSLayoutConstraint!

    override init(frame: NSRect) {
        textView = KiriTextView(usingTextLayoutManager: true)
        super.init(frame: frame)
        assert(textView.textLayoutManager != nil, "the editor must run on TextKit 2")

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        // Room for the floating status bar below the last line.
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 44, right: 0)

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 6, height: 14)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        // Incremental search dims the whole text grey while searching; Kiri
        // finds on Return / ⌘G instead and keeps the text readable.
        textView.isIncrementalSearchingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFontPanel = false
        textView.insertionPointColor = .honey(Honey.caret)
        textView.selectedTextAttributes = [.backgroundColor: NSColor.honey(Honey.selection)]
        textView.setAccessibilityLabel("Editor")
        scrollView.documentView = textView

        gutter.textView = textView
        for v in [gutter, scrollView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        gutterWidth = gutter.widthAnchor.constraint(equalToConstant: gutter.requiredWidth)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterWidth,
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.frameDidChangeNotification,
                                               object: textView)
        #if DEBUG
        NotificationCenter.default.addObserver(forName: NSTextView.willSwitchToNSLayoutManagerNotification,
                                               object: textView, queue: nil) { _ in
            Logger(subsystem: "se.hellsoft.kiri", category: "editor").fault("Editor fell back to TextKit 1")
            assertionFailure("Editor fell back to TextKit 1")
        }
        #endif
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Called when the visible part of the text changes.
    var onScroll: (() -> Void)?

    @objc private func scrolled() {
        gutter.needsDisplay = true
        onScroll?()
    }

    /// Call after the line count or font changes.
    func updateGutterWidth() {
        let w = gutter.requiredWidth
        if gutterWidth.constant != w { gutterWidth.constant = w }
        gutter.needsDisplay = true
    }
}

