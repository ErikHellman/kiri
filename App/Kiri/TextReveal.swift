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
// now is; later, they stop it.

@MainActor final class TextReveal {
    private weak var container: EditorContainerView?
    private let textMask = CALayer()
    private let gutterMask = CALayer()
    private(set) var active = false
    /// The words have their timings (`play`), at this media time.
    private var playedAt: CFTimeInterval?
    private var tries = 0
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var ending: DispatchWorkItem?
    private var width: CGFloat = 0
    private var replaying = false

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
        DispatchQueue.main.async { [weak self] in self?.play() }
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

    /// One visual line on screen: where it is in the text view, and where
    /// its words begin (each runs to where the next begins, the last to the
    /// line's end, so glyphs that grow mid-reveal, as a bold heading does
    /// when its colors land, stay inside).
    private struct Line {
        var top: CGFloat
        var height: CGFloat
        var wordStarts: [CGFloat]
    }

    private func play() {
        guard active, let container else { return }
        let textView = container.textView
        let visible = textView.visibleRect
        guard textView.textLayoutManager != nil, visible.width > 1, visible.height > 1 else {
            // No size yet (a window still being laid out): try again shortly.
            tries += 1
            if tries < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in self?.play() }
            } else {
                finish()
            }
            return
        }
        var lines = measure(visible)
        if lines.reduce(0, { $0 + $1.wordStarts.count }) > Self.wordCap {
            lines = lines.map { Line(top: $0.top, height: $0.height, wordStarts: Array($0.wordStarts.prefix(1))) }
        }
        // Rows of the same line meet, so nothing peeks between them.
        for i in lines.indices.dropLast() where lines[i + 1].top > lines[i].top {
            lines[i].height = max(lines[i].height, lines[i + 1].top - lines[i].top)
        }
        guard !lines.isEmpty else { return finish() }
        let schedule = RevealSchedule(wordCounts: lines.map(\.wordStarts.count))
        build(lines, schedule, visible: visible)
    }

    private func measure(_ visible: NSRect) -> [Line] {
        guard let container, let tlm = container.textView.textLayoutManager else { return [] }
        let textView = container.textView
        let origin = textView.textContainerOrigin
        let top = CGPoint(x: 0, y: max(0, visible.minY - origin.y))
        let start = tlm.textLayoutFragment(for: top)?.rangeInElement.location ?? tlm.documentRange.location
        var lines: [Line] = []
        // Only the fragments on screen are laid out here.
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > visible.maxY { return false }
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
                lines.append(Line(top: y, height: bounds.height, wordStarts: starts))
            }
            return true
        }
        return lines
    }

    private func build(_ lines: [Line], _ schedule: RevealSchedule, visible: NSRect) {
        guard let container, let textLayer = container.textView.layer else { return }
        let textView = container.textView
        let base = CACurrentMediaTime()
        playedAt = base
        width = textView.bounds.width
        let right = max(textView.bounds.maxX, visible.maxX)
        let gutterShift = container.scrollView.contentView.bounds.minY
        let gutterWidth = container.gutter.bounds.width
        let caretLine = textView.currentLineRect()

        func piece(_ rect: CGRect, at begin: Double, for duration: Double) -> CALayer {
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

        var words: [CALayer] = [], numbers: [CALayer] = []
        var bandAt = schedule.total
        for (i, line) in lines.enumerated() {
            for (w, x) in line.wordStarts.enumerated() {
                let end = w + 1 < line.wordStarts.count ? line.wordStarts[w + 1] : right
                words.append(piece(CGRect(x: x, y: line.top, width: max(0, end - x), height: line.height),
                                   at: schedule.wordBegin(line: i, word: w), for: schedule.fade))
            }
            numbers.append(piece(CGRect(x: 0, y: line.top - gutterShift, width: gutterWidth, height: line.height),
                                 at: schedule.lineStarts[i], for: schedule.fade))
            if let caretLine, abs(caretLine.minY - line.top) < 1 {
                bandAt = schedule.lineStarts[i] + schedule.lineDuration(i)
            }
        }
        // The current-line band and the caret, as their line is in.
        if let caretLine {
            words.append(piece(caretLine, at: max(0, bandAt - schedule.fade / 2), for: schedule.fade))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textMask.frame = textLayer.bounds
        textMask.sublayers = words
        gutterMask.frame = container.gutter.layer?.bounds ?? container.gutter.bounds
        gutterMask.sublayers = numbers
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
        lastSchedule = schedule
        if Self.frozenAt != nil { return }
        #endif

        ending?.cancel()
        let ending = DispatchWorkItem { [weak self] in self?.finish() }
        self.ending = ending
        DispatchQueue.main.asyncAfter(deadline: .now() + schedule.total + 0.05, execute: ending)
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

    private func scrolled() { layoutChanged() }

    private func resized() {
        guard active, let container, let textLayer = container.textView.layer else { return }
        // The text growing taller as it is laid out is no change; a new
        // width moves the words.
        if playedAt != nil, abs(container.textView.bounds.width - width) > 0.5 { return layoutChanged() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textMask.frame = textLayer.bounds
        CATransaction.commit()
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
