import Foundation

/// The arithmetic of side-by-side editing, free of SwiftUI so it tests on
/// Linux: how wide each side of a split window is, where its edge can be
/// dragged, how much a window has to grow to hold two editors, where
/// something dragged over the editors would go, and which tab a side
/// shows when the keyboard leaves its tab.
///
/// A window shows up to two of its tabs, left and right, each on a panel
/// of its own with `gap` between them. The keyboard's side is the
/// selected tab; the other side's tab is "beside" it.
public enum SplitLayout {
    public enum Side: String, Sendable, Equatable, CaseIterable {
        case left, right

        public var other: Side { self == .left ? .right : .left }
    }

    /// The least either side keeps: what one editor keeps beside the sidebar.
    public static let editorMinimum = SidebarLayout.editorMinimum
    /// Half and half: where a split starts, and a double-click on its edge.
    public static let defaultFraction = 0.5
    /// One step of the edge for VoiceOver's "increment" and "decrement",
    /// as a share of the row.
    public static let step = 0.05

    /// How wide the row of editors has to be for two: both minimums and
    /// the gap between them.
    public static func minimumRow(gap: Double) -> Double { 2 * editorMinimum + gap }

    /// How much wider a window has to get for its editors' row, now
    /// `editorRow` wide, to hold two: 0 when it has room already.
    public static func growth(editorRow: Double, gap: Double) -> Double {
        max(minimumRow(gap: gap) - editorRow, 0)
    }

    /// `fraction` within what keeps each side its minimum in a row
    /// `available` wide (both panels and the gap).
    public static func clamped(_ fraction: Double, available: Double, gap: Double) -> Double {
        let shared = available - gap
        guard fraction.isFinite else { return defaultFraction }
        // Before the row is measured, or in one too narrow for two: half each.
        guard shared >= 2 * editorMinimum else { return defaultFraction }
        let least = editorMinimum / shared
        return min(max(fraction, least), 1 - least)
    }

    /// The left panel's width in a row `available` wide: `fraction` of
    /// what the two panels share, each keeping its minimum. (The right
    /// panel has the rest, after the gap.)
    public static func leftWidth(available: Double, fraction: Double, gap: Double) -> Double {
        let shared = max(available - gap, 0)
        return (shared * clamped(fraction, available: available, gap: gap)).rounded()
    }

    /// The right panel's width, beside `leftWidth`.
    public static func rightWidth(available: Double, fraction: Double, gap: Double) -> Double {
        max(available - gap - leftWidth(available: available, fraction: fraction, gap: gap), 0)
    }

    /// Where a drag of the edge that began with the left panel `start`
    /// wide and has moved `translation` leaves it, as a fraction.
    public static func dragged(from start: Double, by translation: Double, available: Double, gap: Double) -> Double {
        let shared = available - gap
        guard shared > 0 else { return defaultFraction }
        return clamped((start + translation) / shared, available: available, gap: gap)
    }

    // MARK: Dropping

    /// What something let go over the editors does.
    public enum Drop: Equatable, Sendable {
        /// It shows on that side, the keyboard with it.
        case side(Side)
        /// It opens as a tab, as a file dropped on the window always has.
        case tab
    }

    /// Where something let go at `x` (from the left edge of the editors'
    /// row, `width` wide) goes. A tab goes to the half it is over, or in a
    /// split window to the side whose panel it is over (left of
    /// `divider`). Files from Finder split the window only from its outer
    /// thirds: in the middle they open as tabs, as they always have.
    public static func drop(at x: Double, width: Double, divider: Double? = nil, files: Bool) -> Drop? {
        guard width > 0, x >= 0, x <= width else { return nil }
        if files {
            if x < width / 3 { return .side(.left) }
            if x > width * 2 / 3 { return .side(.right) }
            return .tab
        }
        return .side(x < (divider ?? width / 2) ? .left : .right)
    }

    // MARK: Which tab shows

    /// The tab a side shows when its tab `closing` closes (or leaves the
    /// window): the one after it, or the one before at the end, and never
    /// `beside`, the tab the other side shows. Nil when there is none: the
    /// split then ends, or the window closes.
    public static func neighbour<ID: Equatable>(of closing: ID, in tabs: [ID], beside: ID? = nil) -> ID? {
        guard let index = tabs.firstIndex(of: closing) else { return nil }
        let after = tabs[(index + 1)...].first { $0 != beside }
        let before = tabs[..<index].last { $0 != beside }
        return after ?? before
    }

    /// The next (`by` 1) or previous (-1) tab from `current`, round from
    /// the last to the first, passing over `beside`.
    public static func step<ID: Equatable>(from current: ID, by: Int, in tabs: [ID], beside: ID? = nil) -> ID? {
        guard let index = tabs.firstIndex(of: current) else { return nil }
        let count = tabs.count
        for k in 1..<max(count, 1) {
            let candidate = tabs[((index + by * k) % count + count) % count]
            if candidate != beside, candidate != current { return candidate }
        }
        return nil
    }

    /// The tab that showed before `current`, for Split Editor: the most
    /// recent of `recent` (newest first) that is still among `tabs`, or
    /// else `current`'s neighbour.
    public static func previous<ID: Equatable>(of current: ID, recent: [ID], tabs: [ID]) -> ID? {
        recent.first { $0 != current && tabs.contains($0) } ?? neighbour(of: current, in: tabs)
    }
}
