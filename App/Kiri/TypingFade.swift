import AppKit
import KiriKit
import QuartzCore

// Typed letters fade in and settle a few points into place (plan step 5).
//
// TextKit 2 draws each paragraph through an NSTextLayoutFragment; Kiri's
// fragments draw normally except where a just-typed character is still
// animating: that character is clipped out of the normal pass and drawn again
// with the fade's alpha, shifted down by the remaining settle distance. The
// animation state lives here, keyed by text offset, so it survives the
// highlighter rebuilding fragments right after each keystroke.

/// What fragments read while drawing; TextKit may draw off the main thread.
final class FadeStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [TypingFade.Item] = []
    private var _mode = EditorAnimation.none

    func set(_ items: [TypingFade.Item], mode: EditorAnimation) {
        lock.withLock { _items = items; _mode = mode }
    }

    func read() -> ([TypingFade.Item], EditorAnimation) { lock.withLock { (_items, _mode) } }

    /// Fade progress 0…1 for each animating range intersecting `range`.
    func active(in range: NSRange, now: CFTimeInterval) -> (EditorAnimation, [(range: NSRange, progress: CGFloat)]) {
        let (items, mode) = read()
        let a: [(range: NSRange, progress: CGFloat)] = items.compactMap { item in
            let t = (now - item.start) / TypingFade.duration
            guard t < 1, NSIntersectionRange(item.range, range).length > 0 else { return nil }
            // Ease out.
            return (item.range, CGFloat(1 - pow(1 - max(0, t), 3)))
        }
        return (mode, a)
    }
}

@MainActor final class TypingFade {
    struct Item: Sendable {
        var range: NSRange
        let start: CFTimeInterval
    }

    /// Shared with the layout fragments.
    nonisolated let store = FadeStore()

    nonisolated static let duration = 0.16
    /// How far (points) a letter settles in full motion.
    nonisolated static let settle: CGFloat = 3

    private(set) var items: [Item] = [] {
        didSet { store.set(items, mode: mode) }
    }
    var mode: EditorAnimation = .none {
        didSet {
            if mode == .none { items = [] }
            store.set(items, mode: mode)
        }
    }
    private weak var textView: NSTextView?
    private var displayLink: CADisplayLink?

    init(textView: NSTextView) {
        self.textView = textView
    }

    /// A character (or a few) the person just typed at `range`.
    func typed(_ range: NSRange) {
        guard mode != .none, range.length > 0, range.length <= 4 else { return }
        items.append(Item(range: range, start: CACurrentMediaTime()))
        startTicking()
        // Even if the display link doesn't tick (display asleep), make sure
        // the letter is redrawn settled once its fade is over.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration + 0.03) { [weak self] in
            self?.tick()
        }
    }

    /// Keeps offsets right when text changes before an animating letter;
    /// letters the edit itself touched stop animating.
    func textEdited(range: NSRange, delta: Int) {
        guard !items.isEmpty else { return }
        let old = NSRange(location: range.location, length: range.length - delta)
        items = items.compactMap { item in
            var item = item
            if item.range.location >= NSMaxRange(old) {
                item.range.location += delta
                return item
            }
            return NSIntersectionRange(item.range, old).length > 0 ? nil : item
        }
    }

    private func startTicking() {
        // The edit itself redraws the new letter's fragment; the display link
        // takes over from the next frame.
        guard displayLink == nil, let textView else { return }
        let link = textView.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc func tick() {
        let now = CACurrentMediaTime()
        let finished = items.filter { now - $0.start >= Self.duration }
        items.removeAll { now - $0.start >= Self.duration }
        redraw(extra: finished.map(\.range))
        if items.isEmpty {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    /// Asks TextKit to redraw the fragments of animating letters.
    private func redraw(extra: [NSRange] = [], only: [NSRange]? = nil) {
        guard let textView, let tlm = textView.textLayoutManager,
              let caret = tlm.textSelections.first?.textRanges.first?.location else { return }
        // Letters are near the caret: step from there, not from the start of
        // a possibly huge document.
        let caretOffset = textView.selectedRange().location
        for r in only ?? (items.map(\.range) + extra) {
            guard let start = tlm.location(caret, offsetBy: r.location - caretOffset),
                  let end = tlm.location(start, offsetBy: r.length),
                  let range = NSTextRange(location: start, end: end) else { continue }
            // Invalidating the paragraph's layout is what reliably makes
            // TextKit 2 draw its fragment again (rendering attributes don't).
            tlm.invalidateLayout(for: range)
            textView.needsDisplay = true
        }
    }
}

/// A layout fragment that draws fading letters (see `TypingFade`).
final class FadingLayoutFragment: NSTextLayoutFragment {
    nonisolated(unsafe) var fade: FadeStore?
    #if DEBUG || KIRI_SELFTEST
    /// Self-test: how many times a fragment drew a fading letter.
    nonisolated(unsafe) static var animatedDraws = 0
    #endif
    /// Finds the fragment's start as a document offset, only when a letter
    /// is animating (it costs a walk through the document).
    nonisolated(unsafe) var offsetProvider: (() -> Int)?

    override func draw(at point: CGPoint, in context: CGContext) {
        guard let fade, Thread.isMainThread, !fade.read().0.isEmpty, let offsetProvider else {
            return super.draw(at: point, in: context)
        }
        let documentOffset = offsetProvider()
        let length = textLineFragments.reduce(0) { max($0, NSMaxRange($1.characterRange)) }
        let (mode, active) = fade.active(in: NSRange(location: documentOffset, length: length),
                                         now: CACurrentMediaTime())
        guard !active.isEmpty else { return super.draw(at: point, in: context) }

        // Rects (fragment coordinates) of the animating letters.
        var letters: [(rect: CGRect, progress: CGFloat)] = []
        for (range, progress) in active {
            let local = NSRange(location: range.location - documentOffset, length: range.length)
            for line in textLineFragments {
                let lr = line.characterRange
                let start = max(local.location, lr.location), end = min(NSMaxRange(local), NSMaxRange(lr))
                guard start < end else { continue }
                let x0 = line.locationForCharacter(at: start).x
                let x1 = end < NSMaxRange(lr) ? line.locationForCharacter(at: end).x : line.typographicBounds.maxX
                let b = line.typographicBounds
                letters.append((CGRect(x: x0, y: b.minY, width: max(1, x1 - x0), height: b.height)
                    .offsetBy(dx: point.x, dy: point.y), progress))
            }
        }
        guard !letters.isEmpty else { return super.draw(at: point, in: context) }
        #if DEBUG || KIRI_SELFTEST
        nonisolated(unsafe) var n = FadingLayoutFragment.animatedDraws
        n += 1
        FadingLayoutFragment.animatedDraws = n
        #endif

        // Everything but the letters.
        context.saveGState()
        context.addRect(renderingSurfaceBounds.offsetBy(dx: point.x, dy: point.y).insetBy(dx: -50, dy: -50))
        for l in letters { context.addRect(l.rect) }
        context.clip(using: .evenOdd)
        super.draw(at: point, in: context)
        context.restoreGState()

        // The letters, fading in and settling up into place.
        for l in letters {
            context.saveGState()
            let dy = mode == .full ? TypingFade.settle * (1 - l.progress) : 0
            context.translateBy(x: 0, y: dy)
            context.clip(to: l.rect)
            context.setAlpha(max(0.05, l.progress))
            super.draw(at: point, in: context)
            context.restoreGState()
        }
    }
}
