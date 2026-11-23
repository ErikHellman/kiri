import AppKit

/// A tab dragged out of its strip (`HoneyTabStrip`'s `onDragOut`): dropped
/// on another Kiri window it joins that window's tabs, after the tab that
/// shows there; dropped anywhere else it becomes a window of its own, its
/// top left where it was let go. A window's last tab doesn't come out of
/// it (it would only move the window), and a drop on its own window
/// changes nothing.
@MainActor enum TabDrag {
    static let type = NSPasteboard.PasteboardType("se.hellsoft.kiri.tab")

    /// The tab being dragged, while a drag is under way.
    private static weak var dragged: DocumentTab?

    /// Starts dragging `tab`, from the mouse event under way.
    static func begin(_ tab: DocumentTab) {
        guard let window = tab.window, window.tabs.list.count > 1 || DocumentWindow.all.count > 1,
              let event = NSApp.currentEvent, event.type == .leftMouseDragged || event.type == .leftMouseDown,
              let view = window.contentView else { return }
        dragged = tab
        let item = NSPasteboardItem()
        item.setString(String(tab.id), forType: type)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let point = view.convert(event.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(NSRect(x: point.x - 60, y: point.y - 14, width: 120, height: 28),
                                      contents: image(for: tab.document.displayName))
        view.beginDraggingSession(with: [draggingItem], event: event, source: Source.shared)
    }

    static func isTabDrag(_ info: any NSDraggingInfo) -> Bool {
        info.draggingPasteboard.availableType(from: [type]) != nil
    }

    private static func tab(in info: any NSDraggingInfo) -> DocumentTab? {
        guard let id = info.draggingPasteboard.string(forType: type).flatMap(Int.init), let tab = dragged, tab.id == id else {
            return nil
        }
        return tab
    }

    /// A move onto another window; nothing on the tab's own.
    static func operation(_ info: any NSDraggingInfo, in window: DocumentNSWindow) -> NSDragOperation {
        guard let tab = tab(in: info), tab.window !== window, !window.closing else { return [] }
        return .move
    }

    static func perform(_ info: any NSDraggingInfo, in window: DocumentNSWindow) -> Bool {
        guard let tab = tab(in: info), tab.window !== window, !window.closing else { return false }
        Source.shared.dropped = true
        window.tabs.insert(tab)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// What the pointer carries: the tab's title on a glass-like capsule.
    private static func image(for title: String) -> NSImage {
        let size = NSSize(width: 120, height: 28)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14).stroke()
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingMiddle
            let text = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ])
            text.draw(in: rect.insetBy(dx: 10, dy: 6))
            return true
        }
    }

    private final class Source: NSObject, NSDraggingSource {
        nonisolated(unsafe) static let shared = Source()
        /// A window took the tab.
        var dropped = false

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            dropped = false
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            MainActor.assumeIsolated {
                defer { TabDrag.dragged = nil }
                guard !dropped, operation.isEmpty, let tab = TabDrag.dragged, let window = tab.window else { return }
                // Let go over its own window: it stays.
                if window.frame.contains(screenPoint) { return }
                DocumentWindow.moveToNewWindow(tab, topLeft: NSPoint(x: screenPoint.x - 60, y: screenPoint.y + 20))
            }
        }
    }
}
