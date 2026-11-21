import AppKit
import KiriKit
import QuartzCore

// Typing animations (plan step 5), as Core Animation layers over and under
// the TextKit 2 text; none of them touch text layout:
//
// - the current-line highlight eases from line to line,
// - the caret glides between positions with a soft honey glow and breathes
//   instead of blinking,
// - the matching bracket pulses when the caret lands next to a bracket.
//
// `EditorAnimation.full` moves things; `.fades` keeps the fades but nothing
// moves (Reduce Motion); `.none` removes every layer and gives the system
// caret and the drawn current line back.

@MainActor final class EditorEffects {
    private weak var textView: KiriTextView?
    let mode: EditorAnimation
    private let lineLayer = CALayer()
    private let caretLayer = CALayer()
    private var lastCaretRect: NSRect?
    private var lastLineRect: NSRect?

    /// Glide and ease durations (seconds).
    static let caretGlide = 0.09
    static let lineEase = 0.16
    static let pulse = 0.5

    init(textView: KiriTextView, mode: EditorAnimation) {
        self.textView = textView
        self.mode = mode
        textView.wantsLayer = true
        lineLayer.zPosition = -1
        lineLayer.actions = ["contents": NSNull()]
        caretLayer.cornerRadius = 1
        caretLayer.shadowOpacity = 0.55
        caretLayer.shadowRadius = 3.5
        caretLayer.shadowOffset = .zero
        caretLayer.zPosition = 10
        caretLayer.isHidden = true
        textView.layer?.insertSublayer(lineLayer, at: 0)
        textView.layer?.addSublayer(caretLayer)
        updateColors()
    }

    func remove() {
        lineLayer.removeFromSuperlayer()
        caretLayer.removeFromSuperlayer()
    }

    func updateColors() {
        guard let textView else { return }
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            lineLayer.backgroundColor = NSColor.honey(Honey.currentLine).cgColor
            caretLayer.backgroundColor = NSColor.honey(Honey.caret).cgColor
            caretLayer.shadowColor = NSColor.honey(Honey.focus).cgColor
        }
    }

    /// Call after the selection, the text or the layout changed.
    func update(animated: Bool = true) {
        guard let textView else { return }
        let lineRect = textView.highlightsCurrentLine ? textView.currentLineRect() : nil
        let caretRect = textView.caretRect()
        let showCaret = caretRect != nil && textView.isCaretActive

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Current line.
        if let lineRect {
            let moved = lastLineRect.map { abs($0.minY - lineRect.minY) > 0.5 } ?? false
            let wasHidden = lineLayer.isHidden || lastLineRect == nil
            lineLayer.isHidden = false
            if animated, moved, mode == .full {
                ease(lineLayer, key: "position", from: lineLayer.position,
                     to: CGPoint(x: lineRect.midX, y: lineRect.midY), duration: Self.lineEase)
            } else if animated, moved || wasHidden {
                fade(lineLayer, from: 0.35, duration: Self.lineEase)
            }
            lineLayer.frame = lineRect
        } else {
            lineLayer.isHidden = true
        }
        lastLineRect = lineRect

        // Caret.
        if let caretRect, showCaret {
            let ink = textView.caretInkGaps(at: caretRect)
            let r = Self.caretFrame(insertion: caretRect, inkBefore: ink.before, inkAfter: ink.after,
                                    scale: textView.window?.backingScaleFactor ?? 2)
            if animated, mode == .full, let last = lastCaretRect, !caretLayer.isHidden,
               hypot(last.midX - r.midX, last.midY - r.midY) > 0.5 {
                ease(caretLayer, key: "position", from: caretLayer.position, to: CGPoint(x: r.midX, y: r.midY),
                     duration: Self.caretGlide)
            }
            caretLayer.frame = r
            caretLayer.isHidden = false
            breathe()
            lastCaretRect = r
        } else {
            caretLayer.isHidden = true
            caretLayer.removeAnimation(forKey: "breathe")
            lastCaretRect = nil
        }
        CATransaction.commit()
    }

    /// The caret bar's width in points (DESIGN.md §6).
    static let caretWidth: CGFloat = 2
    /// The air the bar keeps to the letters beside it, where there is room.
    static let caretClearance: CGFloat = 0.5

    /// The bar for an insertion point at `insertion` (a zero-width rect).
    /// `inkBefore` and `inkAfter` say how far from the insertion point the
    /// ink of the letters on either side begins (their side bearings;
    /// `.infinity` without a letter). The bar is centred on the insertion
    /// point when that keeps it clear of both letters, moves away from a
    /// letter it would cut into, and sits in the middle of a gap that is
    /// narrower than itself. Snapped to whole pixels so its edges are crisp.
    static func caretFrame(insertion: NSRect, inkBefore: CGFloat, inkAfter: CGFloat, scale: CGFloat) -> NSRect {
        let x = insertion.minX, width = caretWidth
        let lowest = x - inkBefore + caretClearance, highest = x + inkAfter - caretClearance - width
        var left = lowest <= highest
            ? min(max(x - width / 2, lowest), highest)
            : x + (inkAfter - inkBefore) / 2 - width / 2
        if scale > 0 { left = (left * scale).rounded() / scale }
        return NSRect(x: left, y: insertion.minY, width: width, height: insertion.height)
    }

    /// Fully visible right after a move, then a slow, soft pulse instead of
    /// an on/off blink.
    private func breathe() {
        caretLayer.removeAnimation(forKey: "breathe")
        caretLayer.opacity = 1
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0.25
        a.duration = 0.55
        a.autoreverses = true
        a.repeatCount = .infinity
        a.beginTime = CACurrentMediaTime() + 0.6
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.fillMode = .backwards
        caretLayer.add(a, forKey: "breathe")
    }

    /// A short pulse over the bracket matching the one at the caret.
    func pulseMatchingBracket() {
        guard let textView, let rect = textView.matchingBracketRect() else { return }
        let layer = CALayer()
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.honey(Honey.accentSoft).cgColor
            layer.borderColor = NSColor.honey(Honey.accent).cgColor
        }
        layer.borderWidth = 1.5
        layer.cornerRadius = 4
        layer.frame = rect.insetBy(dx: -1.5, dy: 0)
        layer.zPosition = -0.5
        layer.opacity = 0
        textView.layer?.addSublayer(layer)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.18, 0.55, 1]
        var animations: [CAAnimation] = [fade]
        if mode == .full {
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.7, 1.12, 1, 1]
            scale.keyTimes = [0, 0.3, 0.55, 1]
            animations.append(scale)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = Self.pulse
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        layer.add(group, forKey: "pulse")
        CATransaction.commit()
    }

    private func ease(_ layer: CALayer, key: String, from: CGPoint, to: CGPoint, duration: Double) {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = NSValue(point: layer.presentation()?.position ?? from)
        a.toValue = NSValue(point: to)
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        layer.add(a, forKey: key)
    }

    private func fade(_ layer: CALayer, from: Float, duration: Double) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = 1
        a.duration = duration
        layer.add(a, forKey: "fade")
    }
}

extension KiriTextView {
    /// The caret's rect (zero width), or nil with a selection.
    func caretRect() -> NSRect? {
        guard selectedRange().length == 0, let tlm = textLayoutManager,
              let caret = tlm.textSelections.first?.textRanges.first?.location else { return nil }
        var rect: NSRect?
        tlm.enumerateTextSegments(in: NSTextRange(location: caret), type: .selection, options: [.rangeNotRequired]) {
            _, frame, _, _ in
            rect = frame
            return false
        }
        guard var r = rect else { return nil }
        if r.height < 1, let f = font { r.size.height = ceil(f.ascender - f.descender) }
        r.origin.x += textContainerOrigin.x
        r.origin.y += textContainerOrigin.y
        return r
    }

    /// How far the ink of the characters around the caret (at `rect`, from
    /// `caretRect()`) is from the insertion point: the right side bearing of
    /// the glyph before it and the left side bearing of the glyph after it.
    /// `.infinity` where nothing is drawn: a line's start or end, white space.
    func caretInkGaps(at rect: NSRect) -> (before: CGFloat, after: CGFloat) {
        guard let storage = textStorage, let font else { return (.infinity, .infinity) }
        let text = storage.string as NSString
        let index = selectedRange().location
        /// The glyph's bearings, nil for white space; a character its font
        /// doesn't draw (emoji, CJK) counts as ink right up to its edges.
        func bearings(_ i: Int) -> (left: CGFloat, right: CGFloat)? {
            guard i >= 0, i < text.length else { return nil }
            var ch = text.character(at: i)
            if let scalar = UnicodeScalar(ch), CharacterSet.whitespacesAndNewlines.contains(scalar) { return nil }
            // The highlighter sets bold and italic faces (Markdown headings, emphasis).
            let font = storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont ?? font
            var glyph = CGGlyph()
            guard CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1) else { return (0, 0) }
            var box = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &box, 1)
            let advance = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
            return (max(0, box.minX), max(0, advance - box.maxX))
        }
        // At the start of a visual line (also a wrapped one) nothing is drawn before the caret.
        let lineStart = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        let before = rect.minX <= lineStart + 0.01 ? nil : bearings(index - 1)
        return (before?.right ?? .infinity, bearings(index)?.left ?? .infinity)
    }

    /// The rect of the bracket matching the one just before or after the
    /// caret, if it's within reach.
    func matchingBracketRect() -> NSRect? {
        let sel = selectedRange()
        guard sel.length == 0, let tlm = textLayoutManager, let storage = textStorage else { return nil }
        let text = storage.string as NSString
        let pairs: [unichar: (unichar, Int)] = [0x28: (0x29, 1), 0x5B: (0x5D, 1), 0x7B: (0x7D, 1),
                                                0x29: (0x28, -1), 0x5D: (0x5B, -1), 0x7D: (0x7B, -1)]
        var found: (Int, unichar)?
        if sel.location > 0, pairs[text.character(at: sel.location - 1)] != nil {
            found = (sel.location - 1, text.character(at: sel.location - 1))
        } else if sel.location < text.length, pairs[text.character(at: sel.location)] != nil {
            found = (sel.location, text.character(at: sel.location))
        }
        guard let (start, ch) = found, let (target, dir) = pairs[ch] else { return nil }
        var depth = 0
        var i = start
        let limit = 20_000
        var steps = 0
        while i >= 0, i < text.length, steps < limit {
            let c = text.character(at: i)
            if c == ch { depth += 1 } else if c == target {
                depth -= 1
                if depth == 0 { break }
            }
            i += dir
            steps += 1
        }
        guard depth == 0, i >= 0, i < text.length, i != start,
              let caretLoc = tlm.textSelections.first?.textRanges.first?.location,
              let loc = tlm.location(caretLoc, offsetBy: i - sel.location),
              let end = tlm.location(loc, offsetBy: 1),
              let range = NSTextRange(location: loc, end: end) else { return nil }
        var rect: NSRect?
        tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            rect = frame
            return false
        }
        guard var r = rect, visibleRect.intersects(r.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
        else { return nil }
        r.origin.x += textContainerOrigin.x
        r.origin.y += textContainerOrigin.y
        return r
    }
}
