import AppKit
import KiriKit
import QuartzCore

// What the find bar and Go to Line point out in the text, as Core Animation
// layers under the glyphs: every match of the search in `accent-soft`, the
// current one in `selection` with an `accent` outline, and the line Go to
// Line is previewing. Like the typing effects, none of it touches the text
// storage (syntax highlighting owns its attributes), text layout or undo.
//
// Only the matches in the viewport get a layer, so a search with a hundred
// thousand matches costs the same to show as one with ten.

@MainActor final class EditorMarks {
    private weak var textView: KiriTextView?
    private var matches: [Range<Int>] = []
    private var current: Range<Int>?
    private var fills: [CALayer] = []
    private var currentFills: [CALayer] = []
    private var currentOutlines: [CALayer] = []
    private let lineBand = CALayer()
    private var lineShown = false
    private var scheduled = false
    private var colors = (match: CGColor.clear, current: CGColor.clear, outline: CGColor.clear)

    /// At most this many match rects are drawn at once (a screen of nothing
    /// but matches of one letter is far fewer).
    static let limit = 3000

    /// How many matches have a layer now (self-tests).
    private(set) var shownMatches = 0
    /// The current match's rects in the text view, when it is in sight.
    private(set) var currentRects: [NSRect] = []
    /// The line preview's band is showing (self-tests).
    var showsLine: Bool { lineShown && !lineBand.isHidden }

    init(textView: KiriTextView) {
        self.textView = textView
        textView.wantsLayer = true
        // Under the text and the selection; over the current-line highlight.
        lineBand.zPosition = -0.9
        lineBand.isHidden = true
        updateColors()
    }

    /// The find bar's matches (sorted) and which one is current.
    func show(matches: [Range<Int>], current: Range<Int>?) {
        self.matches = matches
        self.current = current
        setNeedsUpdate()
    }

    func clearMatches() {
        guard !matches.isEmpty || current != nil || !fills.isEmpty else { return }
        matches = []
        current = nil
        update()
    }

    /// Redraws after the layout, the viewport or the matches changed, once
    /// per turn of the run loop however often it is asked.
    func setNeedsUpdate() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                self?.update()
            }
        }
    }

    func updateColors() {
        guard let textView else { return }
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            colors = (NSColor.honey(Honey.accentSoft).cgColor, NSColor.honey(Honey.selection).cgColor,
                      NSColor.honey(Honey.accent).cgColor)
            lineBand.backgroundColor = NSColor.honey(Honey.accentSoft).cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fills.forEach { $0.backgroundColor = colors.match }
        currentFills.forEach { $0.backgroundColor = colors.current }
        currentOutlines.forEach { $0.borderColor = colors.outline }
        CATransaction.commit()
    }

    /// Lays the layers out now (also called by `setNeedsUpdate`).
    func update() {
        guard let textView, let host = textView.layer else { return }
        var rects: [NSRect] = []
        var currentRects: [NSRect] = []
        var shown = 0
        if !matches.isEmpty || current != nil, let visible = textView.visibleCharacters() {
            // The first match that ends inside the viewport.
            var lo = 0, hi = matches.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if matches[mid].upperBound <= visible.range.lowerBound { lo = mid + 1 } else { hi = mid }
            }
            var i = lo
            while i < matches.count, matches[i].lowerBound < visible.range.upperBound, rects.count < Self.limit {
                let match = matches[i]
                i += 1
                guard match != current else { continue }
                let r = textView.rects(for: match.clamped(to: visible.range), near: visible)
                if !r.isEmpty { shown += 1 }
                rects += r
            }
            if let current, current.overlaps(visible.range) {
                currentRects = textView.rects(for: current.clamped(to: visible.range), near: visible)
                if !currentRects.isEmpty { shown += 1 }
            }
        }
        shownMatches = shown
        self.currentRects = currentRects

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(&fills, rects, in: host) { layer in
            layer.backgroundColor = colors.match
            layer.cornerRadius = 3
            layer.zPosition = -0.8
        }
        place(&currentFills, currentRects, in: host) { layer in
            layer.backgroundColor = colors.current
            layer.cornerRadius = 3
            layer.zPosition = -0.7
        }
        // The outline goes over the text and the selection (which covers the
        // fill when the editor has the keyboard), just outside the letters.
        place(&currentOutlines, currentRects.map { $0.insetBy(dx: -1.5, dy: 0) }, in: host) { layer in
            layer.borderColor = colors.outline
            layer.borderWidth = 1.5
            layer.cornerRadius = 4
            layer.zPosition = 5
        }
        if lineShown, let rect = textView.currentLineRect() {
            if lineBand.superlayer == nil { Self.add(lineBand, to: host) }
            lineBand.frame = rect
            lineBand.isHidden = false
        } else {
            lineBand.isHidden = true
        }
        CATransaction.commit()
    }

    /// Makes `layers` one per rect, reusing what is there.
    private func place(_ layers: inout [CALayer], _ rects: [NSRect], in host: CALayer, style: (CALayer) -> Void) {
        while layers.count > rects.count { layers.removeLast().removeFromSuperlayer() }
        while layers.count < rects.count {
            let layer = CALayer()
            style(layer)
            Self.add(layer, to: host)
            layers.append(layer)
        }
        for (layer, rect) in zip(layers, rects) { layer.frame = rect }
    }

    /// Adds `layer` among the text view's layers where its `zPosition`
    /// puts it. The window server orders by `zPosition` anyway; a picture
    /// rendered from the layer tree (`-KiriEditorSnapshot`) goes by this
    /// order alone.
    private static func add(_ layer: CALayer, to host: CALayer) {
        let index = host.sublayers?.firstIndex { $0.zPosition > layer.zPosition } ?? host.sublayers?.count ?? 0
        host.insertSublayer(layer, at: UInt32(index))
    }

    // MARK: Go to Line's preview

    /// How long the line pulse takes (seconds).
    static let linePulse = 0.7

    /// Marks the caret's line while Go to Line previews it. With `pulse` the
    /// band comes and goes once (the current-line highlight is what stays);
    /// without, it is a steady band until `showLine(false)`.
    func showLine(_ show: Bool, pulse: Bool = false) {
        lineBand.removeAnimation(forKey: "pulse")
        lineShown = show
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lineBand.opacity = show && pulse ? 0 : 1
        CATransaction.commit()
        update()
        guard show, pulse else { return }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.55, 1]
        fade.duration = Self.linePulse
        lineBand.add(fade, forKey: "pulse")
    }
}

extension KiriTextView {
    /// The characters in the viewport as UTF-16 offsets, and where they
    /// start, to measure other offsets from (never from the start of a
    /// possibly huge document).
    func visibleCharacters() -> (range: Range<Int>, start: any NSTextLocation)? {
        guard let tlm = textLayoutManager, let viewport = tlm.textViewportLayoutController.viewportRange else { return nil }
        let lower = tlm.offset(from: tlm.documentRange.location, to: viewport.location)
        let upper = lower + tlm.offset(from: viewport.location, to: viewport.endLocation)
        return (lower..<upper, viewport.location)
    }

    /// The rects of `range` (one per visual line it is on), in the text
    /// view. An empty range gives where a caret there would be.
    func rects(for range: Range<Int>, near base: (range: Range<Int>, start: any NSTextLocation)) -> [NSRect] {
        guard let tlm = textLayoutManager,
              let start = tlm.location(base.start, offsetBy: range.lowerBound - base.range.lowerBound),
              let end = tlm.location(start, offsetBy: range.count),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        var rects: [NSRect] = []
        let origin = textContainerOrigin
        tlm.enumerateTextSegments(in: textRange, type: range.isEmpty ? .selection : .standard,
                                  options: range.isEmpty ? [.rangeNotRequired] : []) { _, frame, _, _ in
            var frame = frame
            if frame.height < 1, let font = self.font { frame.size.height = ceil(font.ascender - font.descender) }
            if !range.isEmpty, frame.width < 1 { return true }
            rects.append(frame.offsetBy(dx: origin.x, dy: origin.y))
            return true
        }
        return rects
    }
}

extension EditorController {
    /// Room the bar floating over the top of the editor takes (0 without
    /// one). It is room to scroll into, so the first lines can come out
    /// from under the bar; the text itself stays where it is.
    func setTopObstruction(_ height: CGFloat) {
        guard let scroll = textView?.enclosingScrollView, scroll.contentInsets.top != height else { return }
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        scroll.contentInsets.top = height
        // Setting the inset scrolls by it; go back.
        origin.y = max(origin.y, -height)
        if clip.bounds.origin != origin {
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
        }
    }

    /// Where the editor is scrolled to.
    var scrollOrigin: NSPoint {
        get { textView?.enclosingScrollView?.contentView.bounds.origin ?? .zero }
        set {
            guard let scroll = textView?.enclosingScrollView else { return }
            scroll.contentView.scroll(to: newValue)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// Scrolls so `range` is in the part of the editor nothing floats over:
    /// below the find bar or Go to Line and above the status capsule (the
    /// scroll view's insets). A range that is already there stays put; one
    /// that isn't comes to the middle.
    func reveal(_ range: NSRange) {
        guard let textView, let scroll = textView.enclosingScrollView else { return }
        let clip = scroll.contentView
        let insets = scroll.contentInsets
        let target = range.location..<(range.location + range.length)
        /// The range's rect, if it is laid out (in the viewport).
        func rect() -> NSRect? {
            guard let visible = textView.visibleCharacters(), visible.range.contains(target.lowerBound)
                    || visible.range.upperBound == target.lowerBound else { return nil }
            return textView.rects(for: target, near: visible).first
        }
        let wraps = textView.textContainer?.widthTracksTextView == true
        func clearAbove(_ r: NSRect) -> Bool { r.minY >= clip.bounds.minY + insets.top }
        func clearBelow(_ r: NSRect) -> Bool { r.maxY <= clip.bounds.maxY - insets.bottom }
        func clearBeside(_ r: NSRect) -> Bool { wraps || (r.minX >= clip.bounds.minX && r.maxX <= clip.bounds.maxX - 24) }
        let known = rect()
        if let known, clearAbove(known), clearBelow(known), clearBeside(known) { return }
        var origin = clip.bounds.origin
        if let known, clearAbove(known), clearBelow(known) {
            // Only off to the side (below).
        } else if let known, known.maxY > origin.y, clearBelow(known) {
            // In sight but for the bar over it: just out from under the
            // bar, with a line's air.
            origin.y = known.minY - insets.top - known.height
        } else {
            // Out of sight: let AppKit bring it into the viewport (which
            // lays it out), then put it in the middle of the clear part.
            textView.scrollRangeToVisible(range)
            textView.layoutSubtreeIfNeeded()
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            guard let r = rect() else { return }
            origin = clip.bounds.origin
            origin.y = r.midY - insets.top - (clip.bounds.height - insets.top - insets.bottom) / 2
        }
        guard let r = rect() else { return }
        let lowest = max(-insets.top, textView.frame.height - clip.bounds.height + insets.bottom)
        origin.y = min(max(origin.y, -insets.top), lowest)
        if !wraps, r.minX < origin.x || r.maxX > origin.x + clip.bounds.width - 24 {
            origin.x = min(max(0, r.minX - clip.bounds.width / 3), max(0, textView.frame.width - clip.bounds.width))
        }
        if origin != clip.bounds.origin {
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
        }
    }
}
