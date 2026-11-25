import AppKit
import KiriKit

/// Where each file was when it was last open (`FilePositionStore`): the
/// selection and the scroll. A file that opens again, in a tab or the
/// folder sidebar's preview tab, also after a relaunch, comes back there
/// (`EditorController.restorePosition`). Kept in the preferences.
///
/// A tab notes its position a moment after the selection or the scroll
/// changes, when it closes or takes another file, and when Kiri quits.
@MainActor enum FilePositions {
    static let key = "KiriFilePositions"

    private static var store: FilePositionStore = {
        #if DEBUG || KIRI_SELFTEST
        // A test launch of Kiri itself keeps its own, in memory: the
        // person's stay as they are. (A copy under another identifier has
        // preferences of its own: the relaunch test keeps them there.)
        if SelfTest.isTestLaunch, SelfTest.isKiriItself { return FilePositionStore() }
        #endif
        return FilePositionStore.decoded(UserDefaults.standard.data(forKey: key))
    }()

    /// The key a file's position is kept under: its path, the same however
    /// it was reached.
    static func path(of url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    static func position(for url: URL) -> FilePosition? { store.position(for: path(of: url)) }

    static func set(_ position: FilePosition, for url: URL) {
        start()
        if store.set(position, for: path(of: url)) { save() }
    }

    private static func save() {
        #if DEBUG || KIRI_SELFTEST
        if SelfTest.isTestLaunch, SelfTest.isKiriItself { return }
        #endif
        UserDefaults.standard.set(store.encoded(), forKey: key)
    }

    private static var started = false

    /// At quit every tab notes where it is: AppKit doesn't close the
    /// documents of windows it restores at the next launch.
    private static func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                for window in DocumentWindow.all {
                    for tab in window.tabs.list { tab.controller.rememberPosition() }
                }
                save()
            }
        }
    }

    #if DEBUG || KIRI_SELFTEST
    /// For the self-test: forgets every position.
    static func forgetAll() { store = FilePositionStore() }
    #endif
}

extension EditorController {
    /// The position to keep for the document: the one still waiting to be
    /// put back if the editor hasn't been laid out since, or where it is.
    func currentPosition() -> FilePosition? {
        if let pendingPosition { return pendingPosition }
        guard let textView, let scroll = textView.enclosingScrollView, let tlm = textView.textLayoutManager,
              scroll.contentView.bounds.height > 0 else { return nil }
        let index = currentLineIndex
        let sel = textView.selectedRange()
        let clip = scroll.contentView.bounds
        let insets = scroll.contentInsets
        // The line at the top of what shows, below whatever floats over it.
        let top = clip.minY + insets.top
        var topLine = 0
        var topDelta = 0.0
        if top > 0 {
            let origin = textView.textContainerOrigin
            if let visible = textView.visibleCharacters(),
               // (Half a point in: a line put exactly at the top is that line,
               // not the one whose bottom edge is there too.)
               let fragment = tlm.textLayoutFragment(for: CGPoint(x: 0, y: top - origin.y + 0.5)) {
                let offset = visible.range.lowerBound + tlm.offset(from: visible.start, to: fragment.rangeInElement.location)
                topLine = index.line(at: offset)
                let lineStart = index.starts[topLine]
                if lineStart == offset {
                    topDelta = max(0, top - (fragment.layoutFragmentFrame.minY + origin.y))
                }
            }
        }
        let wraps = textView.textContainer?.widthTracksTextView == true
        return FilePosition(selection: sel.location..<NSMaxRange(sel), topLine: topLine, topDelta: topDelta,
                            scrollX: wraps ? 0 : max(0, clip.minX), in: index)
    }

    /// Notes where the document is, for the next time it opens.
    func rememberPosition() {
        guard let url = document?.fileURL, let position = currentPosition() else { return }
        FilePositions.set(position, for: url)
    }

    /// The document opened (in a new tab, or the preview tab took it): the
    /// selection goes back where it was the last time it was open, now,
    /// and the scroll once the editor has its size (`applyPendingPosition`).
    func restorePosition() {
        guard let url = document?.fileURL, let position = FilePositions.position(for: url),
              let textView else { return }
        let index = currentLineIndex
        let sel = position.selection(in: index)
        textView.setSelectedRange(NSRange(location: sel.lowerBound, length: sel.count))
        pendingPosition = position.scrolledToTop ? nil : position
        applyPendingPosition()
    }

    /// Puts the scroll back where `restorePosition` found it, if the editor
    /// is in a window with a size by now. Before the tab's text fades in
    /// (`TabEditorSlot.show`), so what fades in is what stays.
    func applyPendingPosition() {
        guard let position = pendingPosition, configured, let textView, let scroll = textView.enclosingScrollView,
              textView.window != nil, scroll.contentView.bounds.height > 0 else { return }
        pendingPosition = nil
        let index = currentLineIndex
        let clip = scroll.contentView
        let insets = scroll.contentInsets
        let start = position.topOffset(in: index)
        // Let AppKit lay the line out (it is out of sight), then put it at
        // the top of what shows.
        textView.scrollRangeToVisible(NSRange(location: start, length: 0))
        textView.layoutSubtreeIfNeeded()
        guard let tlm = textView.textLayoutManager else { return }
        tlm.textViewportLayoutController.layoutViewport()
        // (Measured from the viewport, never from the head of a possibly
        // huge document.)
        guard let visible = textView.visibleCharacters(),
              let location = tlm.location(visible.start, offsetBy: start - visible.range.lowerBound),
              let fragment = tlm.textLayoutFragment(for: location) else { return }
        var origin = clip.bounds.origin
        origin.y = fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y + position.topDelta - insets.top
        let lowest = max(-insets.top, textView.frame.height - clip.bounds.height + insets.bottom)
        origin.y = min(max(origin.y, -insets.top), lowest)
        if textView.textContainer?.widthTracksTextView == true {
            origin.x = 0
        } else {
            origin.x = min(max(0, position.scrollX), max(0, textView.frame.width - clip.bounds.width))
        }
        if origin != clip.bounds.origin {
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
        }
    }
}
