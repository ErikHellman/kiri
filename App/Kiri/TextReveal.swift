import AppKit
import KiriKit
import QuartzCore

// A file that opens comes into view line by line, one word at a time: each
// line starts when the one before it is a fifth of the way in
// (`RevealSchedule`). Only what shows is revealed.
//
// The text is never copied or redrawn for it. A Core Animation mask on the
// text view's layer starts empty (nothing shows) and gets one opaque
// rectangle per visible word, each fading in at its time; the line numbers
// have a mask of their own, a rectangle per line. The real text draws
// underneath all along, so syntax colors that land mid-reveal, clicks and
// drops all work as ever, and the render server plays the whole thing
// without TextKit drawing a frame of it (TextKit 2 wouldn't redraw a
// fragment every frame: that is why the letter fade was retired).
//
// The current-line band and the caret, layers inside the text view's
// layer, come in as their line finishes.
//
// Any key in the editor, a click or scroll on it, an edit or another tab
// showing stops it and shows everything at once. A programmatic scroll, a
// new width, font or wrapping just after it starts (a remembered position,
// `kiri file:12`, the tab's first settings) plays it again where the text
// now is; later, a new width, font or wrapping stops it, and a scroll or
// TextKit settling the height of the text above (it places it by estimate
// until it lays it out) moves the pieces with their lines, and lines new on
// screen come in from then on.

@MainActor final class TextReveal {
    private weak var container: EditorContainerView?
    private let textMask = CALayer()
    private let gutterMask = CALayer()
    private(set) var active = false
    /// The words first had their timings (`play`), at this media time.
    private var playedAt: CFTimeInterval?
    private var tries = 0
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var ending: DispatchWorkItem?
    private var width: CGFloat = 0
    private var replaying = false
    private var relocating = false

    /// Past this many words on screen, each line comes in as one piece.
    static let wordCap = 1500
    /// A programmatic scroll this soon after the start replays the reveal
    /// where the text now is.
    static let replayWindow = 0.15

    init(container: EditorContainerView) {
        self.container = container
        for mask in [textMask, gutterMask] {
            mask.actions = ["sublayers": NSNull(), "bounds": NSNull(), "position": NSNull()]
        }
    }

    /// Hides the text at once, before anything draws, and plays the reveal
    /// a turn later, when the editor has its size and the text its layout.
    func start() {
        guard let container else { return }
        container.textView.wantsLayer = true
        container.gutter.wantsLayer = true
        guard let textLayer = container.textView.layer, let gutterLayer = container.gutter.layer else { return }
        active = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textMask.frame = textLayer.bounds
        textMask.sublayers = nil
        textLayer.mask = textMask
        gutterMask.frame = gutterLayer.bounds
        gutterMask.sublayers = nil
        gutterLayer.mask = gutterMask
        CATransaction.commit()
        watch()
        // (Strong: the reveal always gets to play or finish, so its event
        // monitor and observers never outlive it, even if its tab closes.)
        DispatchQueue.main.async { self.play() }
    }

    /// Everything shows, now.
    func finish() {
        guard active else { return }
        active = false
        ending?.cancel()
        ending = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let container {
            if container.textView.layer?.mask === textMask { container.textView.layer?.mask = nil }
            if container.gutter.layer?.mask === gutterMask { container.gutter.layer?.mask = nil }
        }
        textMask.sublayers = nil
        gutterMask.sublayers = nil
        CATransaction.commit()
        if container?.reveal === self { container?.reveal = nil }
    }

    // MARK: Playing

    /// One visual line on screen: which text it holds (from its first
    /// character's offset in the document), where it is in the text view,
    /// and where its words begin (each runs to where the next begins, the
    /// last to the line's end, so glyphs that grow mid-reveal, as a bold
    /// heading does when its colors land, stay inside).
    private struct Line {
        var offset: Int
        var top: CGFloat
        var height: CGFloat
        var wordStarts: [CGFloat]
    }

    /// The pieces of the masks that uncover one line.
    private struct Pieces {
        var words: [CALayer]
        var number: CALayer
    }

    /// The timeline the pieces' times count from.
    private var base: CFTimeInterval = 0
    /// The lines with pieces, by `Line.offset`.
    private var shown: [Int: Pieces] = [:]
    private var band: CALayer?
    /// When the last piece is in, on `base`'s timeline.
    private var total: Double = 0

    private func play() {
        guard active, let container else { return }
        guard let measured = measure() else {
            // No size yet (a window still being laid out): try again shortly.
            tries += 1
            if tries < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { self.play() }
            } else {
                finish()
            }
            return
        }
        let (lines, visible) = measured
        guard !lines.isEmpty else { return finish() }
        base = CACurrentMediaTime()
        // Replays don't move the start: a run of scrolls can't keep it going.
        if playedAt == nil { playedAt = base }
        width = container.textView.bounds.width
        shown = [:]
        band = nil
        total = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textMask.sublayers = nil
        gutterMask.sublayers = nil
        add(lines, from: 0, visible: visible)
        #if DEBUG || KIRI_SELFTEST
        if let frozen = Self.frozenAt {
            // A still of the reveal this far in, for screenshots.
            for mask in [textMask, gutterMask] {
                mask.speed = 0
                mask.timeOffset = base + frozen
            }
        }
        #endif
        CATransaction.commit()
        #if DEBUG || KIRI_SELFTEST
        plays += 1
        #endif
        scheduleEnd()
    }

    /// The text moved under the reveal without anyone touching it: TextKit 2
    /// settling the height of text above the screen (it places it by
    /// estimate until it lays it out), or a command scrolling. The pieces
    /// follow their lines; lines that came on screen come in from now on.
    private func relocate() {
        guard active, playedAt != nil, !relocating, let container else { return }
        // (Laying the screen out can resize the text view, which asks again.)
        relocating = true
        defer { relocating = false }
        guard let measured = measure() else { return }
        let (lines, visible) = measured
        let now = elapsed
        var fresh: [Line] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameMasks()
        for line in lines {
            guard let pieces = shown[line.offset] else {
                fresh.append(line)
                continue
            }
            let rects = wordRects(line, visible: visible)
            for (layer, rect) in zip(pieces.words, rects) { layer.frame = rect }
            pieces.number.frame = numberRect(line)
        }
        if let band, let caretLine = container.textView.currentLineRect() { band.frame = caretLine }
        add(fresh, from: now, visible: visible)
        CATransaction.commit()
        scheduleEnd()
    }

    /// The masks cover the text view and the gutter as they are now.
    private func frameMasks() {
        guard let container else { return }
        if let layer = container.textView.layer { textMask.frame = layer.bounds }
        if let layer = container.gutter.layer { gutterMask.frame = layer.bounds }
    }

    /// Pieces for `lines`, coming in from `start` on the timeline.
    private func add(_ lines: [Line], from start: Double, visible: NSRect) {
        guard !lines.isEmpty, let container else { return }
        frameMasks()
        var lines = lines
        if lines.reduce(0, { $0 + $1.wordStarts.count }) > Self.wordCap {
            lines = lines.map { Line(offset: $0.offset, top: $0.top, height: $0.height,
                                     wordStarts: Array($0.wordStarts.prefix(1))) }
        }
        let schedule = RevealSchedule(wordCounts: lines.map(\.wordStarts.count))
        let caretLine = band == nil ? container.textView.currentLineRect() : nil
        var bandAt = schedule.total
        for (i, line) in lines.enumerated() {
            let rects = wordRects(line, visible: visible)
            let words = rects.enumerated().map { w, rect in
                piece(rect, at: start + schedule.wordBegin(line: i, word: w), for: schedule.fade)
            }
            let number = piece(numberRect(line), at: start + schedule.lineStarts[i], for: schedule.fade)
            words.forEach(textMask.addSublayer)
            gutterMask.addSublayer(number)
            shown[line.offset] = Pieces(words: words, number: number)
            if let caretLine, abs(caretLine.minY - line.top) < 1 {
                bandAt = schedule.lineStarts[i] + schedule.lineDuration(i)
            }
        }
        // The current-line band and the caret, as their line is in.
        if let caretLine {
            let layer = piece(caretLine, at: start + max(0, bandAt - schedule.fade / 2), for: schedule.fade)
            textMask.addSublayer(layer)
            band = layer
        }
        total = max(total, start + schedule.total)
        #if DEBUG || KIRI_SELFTEST
        lastSchedule = schedule
        #endif
    }

    private func piece(_ rect: CGRect, at begin: Double, for duration: Double) -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.frame = rect
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        // (A begin time of 0 would mean "now", whatever the timeline.)
        fade.beginTime = base + max(begin, 1e-4)
        fade.duration = duration
        fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "reveal")
        return layer
    }

    private func wordRects(_ line: Line, visible: NSRect) -> [CGRect] {
        guard let textView = container?.textView else { return [] }
        let right = max(textView.bounds.maxX, visible.maxX)
        return line.wordStarts.indices.map { w in
            let x = line.wordStarts[w]
            let end = w + 1 < line.wordStarts.count ? line.wordStarts[w + 1] : right
            return CGRect(x: x, y: line.top, width: max(0, end - x), height: line.height)
        }
    }

    private func numberRect(_ line: Line) -> CGRect {
        guard let container else { return .zero }
        let shift = container.scrollView.contentView.bounds.minY
        return CGRect(x: 0, y: line.top - shift, width: container.gutter.bounds.width, height: line.height)
    }

    /// How far into the timeline the reveal is.
    private var elapsed: Double {
        #if DEBUG || KIRI_SELFTEST
        if let frozen = Self.frozenAt { return frozen }
        #endif
        return CACurrentMediaTime() - base
    }

    /// Everything shows once the last piece is in.
    private func scheduleEnd() {
        #if DEBUG || KIRI_SELFTEST
        if Self.frozenAt != nil { return }
        #endif
        ending?.cancel()
        let ending = DispatchWorkItem { self.finish() }
        self.ending = ending
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, total - elapsed) + 0.05, execute: ending)
    }

    /// The visual lines on screen, laid out as they will draw, or nil
    /// while the editor has no size.
    private func measure() -> (lines: [Line], visible: NSRect)? {
        guard let container, let tlm = container.textView.textLayoutManager else { return nil }
        let textView = container.textView
        // Lay the screen out as it will draw first.
        tlm.textViewportLayoutController.layoutViewport()
        let visible = textView.visibleRect
        guard visible.width > 1, visible.height > 1 else { return nil }
        let origin = textView.textContainerOrigin
        let top = CGPoint(x: 0, y: max(0, visible.minY - origin.y))
        let start = tlm.textLayoutFragment(for: top)?.rangeInElement.location ?? tlm.documentRange.location
        var lines: [Line] = []
        // Only the fragments on screen are laid out here.
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > visible.maxY { return false }
            let fragmentOffset = tlm.offset(from: tlm.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds
                let y = origin.y + frame.minY + bounds.minY
                guard y + bounds.height > visible.minY, y < visible.maxY else { continue }
                let range = line.characterRange
                let string = line.attributedString.string as NSString
                var starts: [CGFloat] = []
                if range.length > 0, range.location + range.length <= string.length {
                    let text = string.substring(with: range)
                    for word in RevealSchedule.words(in: text) {
                        let x = line.locationForCharacter(at: range.location + word.lowerBound).x
                        // A point to the left for the ink of a slanted letter.
                        starts.append(origin.x + frame.minX + bounds.minX + x - 1)
                    }
                }
                lines.append(Line(offset: fragmentOffset + range.location, top: y, height: bounds.height,
                                  wordStarts: starts))
            }
            return true
        }
        // Rows meet, so nothing peeks between them.
        for i in lines.indices.dropLast() where lines[i + 1].top > lines[i].top {
            lines[i].height = max(lines[i].height, lines[i + 1].top - lines[i].top)
        }
        return (lines, visible)
    }

    // MARK: Stopping

    private func watch() {
        guard let container else { return }
        let center = NotificationCenter.default
        // A key in the editor, or a click, scroll or pinch on it.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                              .scrollWheel, .magnify, .swipe]) { [weak self] event in
            MainActor.assumeIsolated { self?.consider(event) }
            return event
        }
        // Scrolled: by a command just after the start, it plays again there.
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                            object: container.scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        })
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: container.textView,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resized() }
        })
        if let storage = container.textView.textStorage {
            observers.append(center.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage,
                                                queue: .main) { [weak self] note in
                nonisolated(unsafe) let storage = note.object as? NSTextStorage
                MainActor.assumeIsolated {
                    if storage?.editedMask.contains(.editedCharacters) == true { self?.finish() }
                }
            })
        }
    }

    private func consider(_ event: NSEvent) {
        guard active, let container, let window = container.window, event.window === window else { return }
        if event.type == .keyDown {
            if window.firstResponder === container.textView { finish() }
            return
        }
        let point = container.convert(event.locationInWindow, from: nil)
        if container.bounds.contains(point) { finish() }
    }

    /// The words moved (a scroll, a new font, wrapping, a new width): just
    /// after the start (a tab's first settings, a remembered position) the
    /// reveal plays again where they are now; later everything shows. Before
    /// it has played there is nothing to do: it measures when it plays.
    func layoutChanged() {
        guard active, let playedAt else { return }
        if CACurrentMediaTime() - playedAt < Self.replayWindow {
            // Once the change has settled (layout, the rest of a scroll).
            guard !replaying else { return }
            replaying = true
            DispatchQueue.main.async { [weak self] in
                self?.replaying = false
                self?.play()
            }
        } else {
            finish()
        }
    }

    /// A scroll no event in the editor started (one that did has stopped
    /// the reveal already): a command, or a remembered position.
    private func scrolled() {
        guard active, let playedAt else { return }
        if CACurrentMediaTime() - playedAt < Self.replayWindow {
            layoutChanged()
        } else {
            relocate()
        }
    }

    private func resized() {
        guard active, let container else { return }
        // A new width moves the words; the text growing taller or shorter as
        // TextKit lays it out can move it up or down.
        if playedAt != nil, abs(container.textView.bounds.width - width) > 0.5 { return layoutChanged() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameMasks()
        CATransaction.commit()
        if playedAt != nil { relocate() }
    }

    #if DEBUG || KIRI_SELFTEST
    /// -KiriRevealFreeze <seconds>: the reveal holds still this far in.
    static var frozenAt: Double? {
        UserDefaults.standard.object(forKey: "KiriRevealFreeze") == nil
            ? nil : UserDefaults.standard.double(forKey: "KiriRevealFreeze")
    }
    /// How many times the words were given their timings, for the self-test.
    private(set) var plays = 0
    private(set) var lastSchedule: RevealSchedule?
    #endif
}

extension EditorContainerView {
    /// The text comes in word by word (`TextReveal`).
    func beginReveal() {
        reveal?.finish()
        let reveal = TextReveal(container: self)
        self.reveal = reveal
        reveal.start()
    }

    /// Whatever is still coming in shows now.
    func finishReveal() { reveal?.finish() }

    /// The font or the wrapping changed (`TextReveal.layoutChanged`).
    func revealLayoutChanged() { reveal?.layoutChanged() }
}
