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

    /// What find and Go to Line point out in the text, once either has.
    private(set) var marksIfLoaded: EditorMarks?
    var marks: EditorMarks {
        if let marksIfLoaded { return marksIfLoaded }
        let marks = EditorMarks(textView: self)
        marksIfLoaded = marks
        return marks
    }
    /// How the editor animates now (`setAnimation`).
    private(set) var animation = EditorAnimation.none

    private var model: EditorModel? { (delegate as? EditorController)?.model }

    // MARK: Find

    // Find is Kiri's own bar (`FindBar`), so the standard find actions,
    // wherever they come from, go to it and never to AppKit's find bar or
    // find panel. (The two families of actions number theirs alike.)
    override func performFindPanelAction(_ sender: Any?) { performTextFinderAction(sender) }

    override func performTextFinderAction(_ sender: Any?) {
        guard let find = model?.find, let tag = (sender as? NSValidatedUserInterfaceItem)?.tag,
              let action = NSTextFinder.Action(rawValue: tag) else { return }
        switch action {
        case .showFindInterface: find.perform(.show)
        case .showReplaceInterface: find.perform(.showReplace)
        case .nextMatch: find.perform(.next)
        case .previousMatch: find.perform(.previous)
        case .setSearchString: find.perform(.useSelection)
        case .replace, .replaceAndFind: find.perform(.replace)
        case .replaceAll: find.perform(.replaceAll)
        case .hideReplaceInterface: find.perform(.hideReplace)
        case .hideFindInterface: find.perform(.close)
        default: break
        }
    }

    /// Escape in the editor closes the bar over it, as it does in the bar.
    /// With none open it does what it always did.
    override func cancelOperation(_ sender: Any?) {
        if let model, model.find.isOpen {
            model.find.close()
        } else if let model, model.palette.isOpen {
            model.palette.cancel()
        } else if let model, model.goToLine.isOpen {
            model.goToLine.cancel()
        } else {
            super.cancelOperation(sender)
        }
    }

    // MARK: Drops

    // Files and folders dropped on the text open (`FileDrop`), as they do
    // anywhere else on the window; left to the text view, their paths
    // would be typed into the document. Anything else that is dragged
    // here (text) drops into the text as it always did.

    private func carriesFiles(_ sender: any NSDraggingInfo) -> Bool { !FileDrop.urls(sender.draggingPasteboard).isEmpty }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        carriesFiles(sender) ? FileDrop.operation(sender) : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        carriesFiles(sender) ? FileDrop.operation(sender) : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if let sender, carriesFiles(sender) { return }
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        carriesFiles(sender) ? !FileDrop.operation(sender).isEmpty : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard carriesFiles(sender), let window else { return super.performDragOperation(sender) }
        return FileDrop.perform(sender, in: window)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        if let sender, carriesFiles(sender) { return }
        super.concludeDragOperation(sender)
    }

    func setAnimation(_ mode: EditorAnimation) {
        animation = mode
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
        // Type right away in a new window or tab. In a folder window the
        // sidebar is the first thing that can take the keyboard, and
        // AppKit gives it to it: with a file showing, the editor takes
        // it from there, unless the sidebar was asked to have it (Space
        // on a row, which shows a file and stays in the sidebar).
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            let responder = window.firstResponder
            let nobody = responder === window || responder == nil
            let controller = self.delegate as? EditorController
            // (Told by the responder itself, a control of SwiftUI's and no
            // text field: the model hears of the sidebar's focus a turn later.)
            let sidebarByDefault = !(responder is NSText) && controller?.model.sidebarFocusRequest == 0
                && controller?.document?.fileURL != nil
            guard nobody || sidebarByDefault else { return }
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
        if ok {
            model?.find.editorFocusChanged(hasFocus: true)
            model?.palette.editorTookKeyboard()
        }
        effects?.update(animated: false)
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { model?.find.editorFocusChanged(hasFocus: false) }
        DispatchQueue.main.async { [weak self] in self?.effects?.update(animated: false) }
        return ok
    }

    override func layout() {
        super.layout()
        effects?.update(animated: false)
        marksIfLoaded?.setNeedsUpdate()
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
        marksIfLoaded?.updateColors()
        needsDisplay = true
    }

    /// Settings ▸ Theme changed: the colors are dynamic, but layers and the
    /// rendered text fragments hold the old ones until redrawn.
    func themeDidChange() {
        effects?.updateColors()
        marksIfLoaded?.updateColors()
        if let tlm = textLayoutManager { tlm.invalidateLayout(for: tlm.documentRange) }
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
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?

    deinit { themeObserver.map(NotificationCenter.default.removeObserver) }

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
        // No `usesFindBar`: find is Kiri's own glass bar over the editor
        // (`FindBar`), which `KiriTextView` sends the find actions to.
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

        themeObserver = NotificationCenter.default.addObserver(forName: .honeyThemeDidChange, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.textView.themeDidChange()
                self?.gutter.needsDisplay = true
            }
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.frameDidChangeNotification,
                                               object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrolled), name: NSScrollView.didLiveScrollNotification,
                                               object: scrollView)
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
    /// Called after a layout that left the editor in a window with a size.
    var onSized: (() -> Void)?
    /// Called while the person scrolls (a gesture, the wheel or a scroller),
    /// not when a command moves the text.
    var onLiveScroll: (() -> Void)?
    /// The pointer moved over the editor: where, from this view's bottom
    /// left corner, and this view's size.
    var onPointer: ((NSPoint, NSSize) -> Void)?
    private var pointerArea: NSTrackingArea?

    @objc private func liveScrolled() { onLiveScroll?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        pointerArea.map(removeTrackingArea)
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        pointerArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    /// `point` is in this view's coordinates.
    func pointerMoved(to point: NSPoint) {
        onPointer?(NSPoint(x: point.x, y: isFlipped ? bounds.height - point.y : point.y), bounds.size)
    }

    override func layout() {
        super.layout()
        guard onSized != nil, window != nil, bounds.height > 0 else { return }
        // (After this pass: the scroll view and the text in it take their
        // sizes from this view's in it.)
        DispatchQueue.main.async { [weak self] in self?.onSized?() }
    }

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

