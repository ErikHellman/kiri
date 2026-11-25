import Testing
@testable import KiriKit

@Suite struct ReleaseNotesTests {
    @Test func bulletsBecomeItemsAndOtherLinesParagraphs() {
        let notes = ReleaseNotes(version: "0.3.2", markdown: """
            Kiri finds files now.

            - **Find in the sidebar**: type to filter the tree.
            - Settings scrolls
              on short screens.
            * A star works too.
            """)
        #expect(notes.blocks == [
            .paragraph("Kiri finds files now."),
            .item("**Find in the sidebar**: type to filter the tree."),
            .item("Settings scrolls on short screens."),
            .item("A star works too."),
        ])
        #expect(!notes.isEmpty)
    }

    @Test func aBlankLineEndsAnItemAndHeadingsAreDropped() {
        let notes = ReleaseNotes(version: "1.0.0", markdown: "# Kiri 1.0\n\n- One\n\nAfter the list\nsame paragraph\n")
        #expect(notes.blocks == [.item("One"), .paragraph("After the list same paragraph")])
        #expect(ReleaseNotes(version: "1.0.0", markdown: "# Only a heading\n\n").isEmpty)
    }

    @Test func versionsCompareNumberByNumber() {
        let v = { (s: String) in ReleaseVersion(s)! }
        #expect(v("0.10.0") > v("0.9.0"))
        #expect(v("0.3.2") > v("0.3.1"))
        #expect(v("1.0") == v("1.0.0"))
        #expect(v("2-beta") == v("2"))
        #expect(ReleaseVersion("README") == nil)
        #expect(ReleaseVersion("") == nil)
    }

    private let files = ["0.2.0", "0.3.0", "0.3.1", "0.3.2", "README"]

    @Test func aFreshInstallShowsNothing() {
        #expect(WhatsNewPlan.versions(current: "0.3.2", lastSeen: nil, ranBefore: false, available: files) == [])
    }

    @Test func anUpdateFromBeforeWhatsNewShowsThisVersion() {
        #expect(WhatsNewPlan.versions(current: "0.3.2", lastSeen: nil, ranBefore: true, available: files) == ["0.3.2"])
    }

    @Test func anUpdateShowsEveryVersionSinceTheLastSeenNewestFirst() {
        #expect(WhatsNewPlan.versions(current: "0.3.2", lastSeen: "0.3.1", ranBefore: true, available: files) == ["0.3.2"])
        #expect(WhatsNewPlan.versions(current: "0.3.2", lastSeen: "0.2.0", ranBefore: true, available: files)
            == ["0.3.2", "0.3.1", "0.3.0"])
    }

    @Test func atMostThreeVersions() {
        let many = (0...9).map { "0.\($0).0" }
        #expect(WhatsNewPlan.versions(current: "0.9.0", lastSeen: "0.1.0", ranBefore: true, available: many)
            == ["0.9.0", "0.8.0", "0.7.0"])
    }

    @Test func theSameVersionOrAnOlderOneShowsNothing() {
        #expect(WhatsNewPlan.versions(current: "0.3.2", lastSeen: "0.3.2", ranBefore: true, available: files) == [])
        #expect(WhatsNewPlan.versions(current: "0.3.1", lastSeen: "0.3.2", ranBefore: true, available: files) == [])
    }

    @Test func aVersionWithoutNotesShowsNothing() {
        // A local build is 0.1.0, and has no notes of its own.
        #expect(WhatsNewPlan.versions(current: "0.1.0", lastSeen: nil, ranBefore: true, available: files) == [])
        #expect(WhatsNewPlan.versions(current: "0.4.0", lastSeen: "0.3.2", ranBefore: true, available: files) == [])
    }

    @Test func anUnreadableLastSeenCountsAsNone() {
        #expect(WhatsNewPlan.versions(current: "0.3.1", lastSeen: "junk", ranBefore: true, available: files) == ["0.3.1"])
    }
}
