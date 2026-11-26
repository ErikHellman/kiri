import Testing
@testable import KiriKit

@Suite struct SplitLayoutTests {
    private let gap = Honey.gap

    @Test func halfAndHalfInTheDefaultWindow() {
        // The default window: 900 wide, 10 pt of canvas on each side.
        let left = SplitLayout.leftWidth(available: 880, fraction: 0.5, gap: gap)
        let right = SplitLayout.rightWidth(available: 880, fraction: 0.5, gap: gap)
        #expect(left == 435)
        #expect(right == 435)
        #expect(left + gap + right == 880)
    }

    @Test func eachSideKeepsItsMinimum() {
        for available in stride(from: SplitLayout.minimumRow(gap: gap), through: 1600, by: 13) {
            for fraction in stride(from: -0.5, through: 1.5, by: 0.05) {
                let left = SplitLayout.leftWidth(available: available, fraction: fraction, gap: gap)
                let right = SplitLayout.rightWidth(available: available, fraction: fraction, gap: gap)
                #expect(left >= SplitLayout.editorMinimum - 0.5)
                #expect(right >= SplitLayout.editorMinimum - 0.5)
                #expect(abs(left + gap + right - available) < 0.001)
            }
        }
    }

    @Test func aRowTooNarrowForTwoSharesItEvenly() {
        #expect(SplitLayout.clamped(0.8, available: 300, gap: gap) == 0.5)
        #expect(SplitLayout.clamped(0.8, available: 0, gap: gap) == 0.5)
        #expect(SplitLayout.clamped(.nan, available: 900, gap: gap) == 0.5)
    }

    @Test func theWindowGrowsByWhatTwoEditorsLack() {
        #expect(SplitLayout.minimumRow(gap: gap) == 450)
        #expect(SplitLayout.growth(editorRow: 880, gap: gap) == 0)
        #expect(SplitLayout.growth(editorRow: 450, gap: gap) == 0)
        // The narrowest folder window: 480 wide, a 180 pt sidebar and its edge.
        #expect(SplitLayout.growth(editorRow: 480 - 2 * gap - 180 - gap, gap: gap) == 180)
    }

    @Test func theSidebarLeavesRoomForTwoEditors() {
        let editors = SplitLayout.minimumRow(gap: gap)
        for available in stride(from: 700.0, through: 1400, by: 9) {
            let shown = SidebarLayout.shown(preferred: 400, available: available, gap: gap, editors: editors)
            #expect(SidebarLayout.widths.contains(shown))
            #expect(available - gap - shown >= editors)
        }
        // One editor, as before.
        #expect(SidebarLayout.shown(preferred: 400, available: 600, gap: gap) == 370)
    }

    @Test func draggingTheEdgeFollowsThePointerWithinTheLimits() {
        let start = SplitLayout.leftWidth(available: 880, fraction: 0.5, gap: gap)
        let wider = SplitLayout.dragged(from: start, by: 87, available: 880, gap: gap)
        #expect(abs(SplitLayout.leftWidth(available: 880, fraction: wider, gap: gap) - (start + 87)) <= 0.5)
        let far = SplitLayout.dragged(from: start, by: 2000, available: 880, gap: gap)
        #expect(SplitLayout.rightWidth(available: 880, fraction: far, gap: gap) == SplitLayout.editorMinimum)
        let back = SplitLayout.dragged(from: start, by: -2000, available: 880, gap: gap)
        #expect(SplitLayout.leftWidth(available: 880, fraction: back, gap: gap) == SplitLayout.editorMinimum)
    }

    @Test func aTabGoesToTheHalfItIsOver() {
        #expect(SplitLayout.drop(at: 10, width: 800, files: false) == .side(.left))
        #expect(SplitLayout.drop(at: 399, width: 800, files: false) == .side(.left))
        #expect(SplitLayout.drop(at: 401, width: 800, files: false) == .side(.right))
        // In a split window, the panel it is over.
        #expect(SplitLayout.drop(at: 500, width: 800, divider: 560, files: false) == .side(.left))
        #expect(SplitLayout.drop(at: 600, width: 800, divider: 560, files: false) == .side(.right))
        #expect(SplitLayout.drop(at: -1, width: 800, files: false) == nil)
        #expect(SplitLayout.drop(at: 900, width: 800, files: false) == nil)
    }

    @Test func filesSplitOnlyFromTheOuterThirds() {
        #expect(SplitLayout.drop(at: 100, width: 900, files: true) == .side(.left))
        #expect(SplitLayout.drop(at: 450, width: 900, files: true) == .tab)
        #expect(SplitLayout.drop(at: 800, width: 900, files: true) == .side(.right))
        #expect(SplitLayout.drop(at: 450, width: 900, divider: 300, files: true) == .tab)
    }

    @Test func aSideShowsItsNeighbourNeverTheBesideTab() {
        let tabs = [1, 2, 3, 4]
        #expect(SplitLayout.neighbour(of: 2, in: tabs) == 3)
        #expect(SplitLayout.neighbour(of: 2, in: tabs, beside: 3) == 4)
        #expect(SplitLayout.neighbour(of: 4, in: tabs, beside: 3) == 2)
        #expect(SplitLayout.neighbour(of: 4, in: tabs) == 3)
        // Only the beside tab is left: none, and the split ends.
        #expect(SplitLayout.neighbour(of: 1, in: [1, 2], beside: 2) == nil)
        #expect(SplitLayout.neighbour(of: 1, in: [1]) == nil)
        #expect(SplitLayout.neighbour(of: 9, in: tabs) == nil)
    }

    @Test func steppingPassesOverTheBesideTab() {
        let tabs = [1, 2, 3, 4]
        #expect(SplitLayout.step(from: 1, by: 1, in: tabs) == 2)
        #expect(SplitLayout.step(from: 1, by: 1, in: tabs, beside: 2) == 3)
        #expect(SplitLayout.step(from: 4, by: 1, in: tabs, beside: 1) == 2)
        #expect(SplitLayout.step(from: 1, by: -1, in: tabs, beside: 4) == 3)
        #expect(SplitLayout.step(from: 1, by: 1, in: [1, 2], beside: 2) == nil)
        #expect(SplitLayout.step(from: 1, by: 1, in: [1]) == nil)
    }

    @Test func splitEditorShowsTheTabThatShowedBefore() {
        #expect(SplitLayout.previous(of: 3, recent: [3, 1, 2], tabs: [1, 2, 3]) == 1)
        // A tab that has closed since is passed over.
        #expect(SplitLayout.previous(of: 3, recent: [3, 5, 2], tabs: [1, 2, 3]) == 2)
        // Nothing showed before: the neighbour.
        #expect(SplitLayout.previous(of: 1, recent: [1], tabs: [1, 2, 3]) == 2)
        #expect(SplitLayout.previous(of: 1, recent: [], tabs: [1]) == nil)
    }

    @Test func sidesAreEachOthersOther() {
        #expect(SplitLayout.Side.left.other == .right)
        #expect(SplitLayout.Side.right.other == .left)
        #expect(SplitLayout.Side(rawValue: "left") == .left)
    }
}
