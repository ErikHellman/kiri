import Testing
@testable import KiriKit

@Suite struct SidebarLayoutTests {
    private let gap = Honey.gap

    @Test func aWishStaysWithinTheLimits() {
        #expect(SidebarLayout.clamped(100) == 180)
        #expect(SidebarLayout.clamped(180) == 180)
        #expect(SidebarLayout.clamped(312.5) == 312.5)
        #expect(SidebarLayout.clamped(900) == 400)
        #expect(SidebarLayout.widths.contains(SidebarLayout.defaultWidth))
    }

    @Test func aWideRowShowsThePreferredWidth() {
        // The default window: 900 wide, 10 pt of canvas on each side.
        for preferred in [180.0, 230, 300, 400] {
            #expect(SidebarLayout.shown(preferred: preferred, available: 880, gap: gap) == preferred)
        }
        #expect(SidebarLayout.shown(preferred: 1000, available: 880, gap: gap) == 400)
        #expect(SidebarLayout.shown(preferred: 0, available: 880, gap: gap) == 180)
    }

    @Test func aNarrowRowKeepsTheEditorsMinimum() {
        // 600 wide: the editor keeps 220, the edge 10, the sidebar gets 370 of the 400 asked for.
        #expect(SidebarLayout.shown(preferred: 400, available: 600, gap: gap) == 370)
        #expect(SidebarLayout.shown(preferred: 300, available: 600, gap: gap) == 300)
        // In every row a window can have, and for every preference, the editor has its minimum.
        let narrowestRow = SidebarLayout.narrowestWindow - 2 * gap
        for available in stride(from: narrowestRow, through: 1400, by: 7) {
            for preferred in stride(from: 150.0, through: 450, by: 10) {
                let shown = SidebarLayout.shown(preferred: preferred, available: available, gap: gap)
                #expect(SidebarLayout.widths.contains(shown))
                #expect(available - gap - shown >= SidebarLayout.editorMinimum)
            }
        }
    }

    @Test func theNarrowestWindowHoldsTheNarrowestSidebarAndTheEditor() {
        let needed = SidebarLayout.widths.lowerBound + gap + SidebarLayout.editorMinimum + 2 * gap
        #expect(needed <= SidebarLayout.narrowestWindow)
        // There, the sidebar is at most what it was when it couldn't be dragged.
        #expect(SidebarLayout.shown(preferred: 400, available: SidebarLayout.narrowestWindow - 2 * gap, gap: gap) == 230)
    }

    @Test func anUnmeasuredRowHoldsNothingBack() {
        #expect(SidebarLayout.shown(preferred: 320, available: 0, gap: gap) == 320)
    }

    @Test func aDragFollowsThePointerBetweenTheLimits() {
        #expect(SidebarLayout.dragged(from: 230, by: 70, widest: 400) == 300)
        #expect(SidebarLayout.dragged(from: 230, by: -20, widest: 400) == 210)
        #expect(SidebarLayout.dragged(from: 230, by: -500, widest: 400) == 180)
        #expect(SidebarLayout.dragged(from: 230, by: 500, widest: 400) == 400)
        // In a narrow window the edge stops where the editor's minimum begins.
        #expect(SidebarLayout.dragged(from: 230, by: 500, widest: 370) == 370)
        #expect(SidebarLayout.dragged(from: 230, by: 500, widest: 100) == 180)
    }
}
