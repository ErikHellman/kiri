import Foundation

/// The arithmetic of the folder sidebar's width: what the person may drag
/// its edge to, and what shows of that in a window too narrow for it.
public enum SidebarLayout {
    /// The width it has until its edge is dragged, and after a double-click
    /// on the edge.
    public static let defaultWidth = 230.0
    /// How narrow and how wide the edge can be dragged.
    public static let widths = 180.0...400.0
    /// The least the editor panel keeps beside the sidebar.
    public static let editorMinimum = 220.0
    /// The narrowest a document window gets: it holds the narrowest
    /// sidebar, the gaps and the editor's minimum, with room to spare.
    public static let narrowestWindow = 480.0
    /// One step of the edge for VoiceOver's and Voice Control's
    /// "increment" and "decrement".
    public static let step = 10.0

    /// `width` brought within `widths`.
    public static func clamped(_ width: Double) -> Double {
        min(max(width, widths.lowerBound), widths.upperBound)
    }

    /// The widest the sidebar can show in a row `available` wide (the
    /// sidebar, the `gap` its edge is, the editor): what leaves the editor
    /// its minimum, never under the sidebar's own. Two editors side by side
    /// (`SplitLayout`) keep `editors`, both minimums and their gap.
    public static func widest(in available: Double, gap: Double, editors: Double = editorMinimum) -> Double {
        // Before the row has been measured there is nothing to hold back for.
        guard available > 0 else { return widths.upperBound }
        return clamped(available - gap - editors)
    }

    /// The width that shows: the preferred one, or as much of it as the
    /// row has room for. (The preference itself is kept, and shows again
    /// when the window is widened.)
    public static func shown(preferred: Double, available: Double, gap: Double, editors: Double = editorMinimum) -> Double {
        min(clamped(preferred), widest(in: available, gap: gap, editors: editors))
    }

    /// Where a drag that began at `start` and has moved `translation`
    /// leaves the edge: no further than `widest`.
    public static func dragged(from start: Double, by translation: Double, widest: Double) -> Double {
        min(clamped(start + translation), max(widest, widths.lowerBound))
    }
}
