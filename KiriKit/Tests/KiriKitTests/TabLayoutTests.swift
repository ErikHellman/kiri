import Testing
@testable import KiriKit

@Suite struct TabTextTests {
    @Test func splitsNameAndExtension() {
        #expect(TabText.split("Greeter.swift") == ("Greeter", ".swift"))
        #expect(TabText.split("archive.tar.gz") == ("archive.tar", ".gz"))
        #expect(TabText.split("Makefile") == ("Makefile", ""))
        #expect(TabText.split(".gitignore") == (".gitignore", ""))
        #expect(TabText.split("notes.") == ("notes.", ""))
        #expect(TabText.split("Mr. Smith") == ("Mr. Smith", ""))
        #expect(TabText.split("App.entitlements") == ("App", ".entitlements"))
        #expect(TabText.split("a.thisisnotanextension") == ("a.thisisnotanextension", ""))
    }

    @Test func keepsWhatFits() {
        #expect(TabText.middleTruncated("README.md", maxCharacters: 9) == "README.md")
        #expect(TabText.middleTruncated("README.md", maxCharacters: 40) == "README.md")
    }

    @Test func theMiddleGoesFirstSoTheExtensionSurvives() {
        #expect(TabText.middleTruncated("Greeter.swift", maxCharacters: 12) == "Greet….swift")
        #expect(TabText.middleTruncated("README.md", maxCharacters: 8) == "READ….md")
        #expect(TabText.middleTruncated("AppDelegate+NotificationHandling.swift", maxCharacters: 20) == "AppDelegate+N….swift")
        #expect(TabText.middleTruncated("a-very-long-configuration-file-name.production.yaml", maxCharacters: 16)
            == "a-very-lon….yaml")
        // Down to two letters of the stem.
        #expect(TabText.middleTruncated("README.md", maxCharacters: 7) == "REA….md")
        #expect(TabText.middleTruncated("README.md", maxCharacters: 6) == "RE….md")
        #expect(TabText.middleTruncated("Greeter.swift", maxCharacters: 9) == "Gr….swift")
    }

    @Test func theEndGoesWhenTheExtensionWouldLeaveNoName() {
        #expect(TabText.middleTruncated("README.md", maxCharacters: 5) == "READ…")
        #expect(TabText.middleTruncated("Greeter.swift", maxCharacters: 8) == "Greeter…")
        #expect(TabText.middleTruncated("index.html", maxCharacters: 7) == "index…")
        #expect(TabText.middleTruncated("Greeter.swift", maxCharacters: 4) == "Gre…")
        #expect(TabText.middleTruncated("Makefile", maxCharacters: 5) == "Make…")
        #expect(TabText.middleTruncated(".gitignore", maxCharacters: 6) == ".giti…")
        // Never a piece of the extension: "ab.swi…" says less than "ab…".
        #expect(TabText.middleTruncated("ab.swift", maxCharacters: 7) == "ab…")
        #expect(TabText.middleTruncated("config.yaml", maxCharacters: 7) == "config…")
    }

    @Test func nothingFits() {
        #expect(TabText.middleTruncated("README.md", maxCharacters: 1) == "…")
        #expect(TabText.middleTruncated("README.md", maxCharacters: 0) == "…")
        #expect(TabText.middleTruncated("x", maxCharacters: 0) == "…")
        #expect(TabText.middleTruncated("", maxCharacters: 0).isEmpty)
    }

    @Test func countsWholeCharacters() {
        #expect(TabText.middleTruncated("🍯🍯🍯🍯🍯🍯.md", maxCharacters: 7) == "🍯🍯🍯….md")
        #expect(TabText.middleTruncated("anteckningar-för-mötet.txt", maxCharacters: 12) == "anteckn….txt")
        #expect(TabText.middleTruncated("anteckningar-för-mötet.txt", maxCharacters: 21) == "anteckningar-för….txt")
    }

    @Test func measuresWithTheWidthsItIsGiven() {
        // Wide letters: "W" counts 3, everything else 1.
        let wide: (String) -> Double = { $0.reduce(0) { $0 + ($1 == "W" ? 3 : 1) } }
        #expect(TabText.middleTruncated("WWWW.md", toFit: 13, measure: wide) == "WWW….md")
        #expect(TabText.middleTruncated("WWWW.md", toFit: 10, measure: wide) == "WW….md")
        #expect(TabText.middleTruncated("WWWW.md", toFit: 9, measure: wide) == "WW…")
        #expect(TabText.middleTruncated("WWWW.md", toFit: 6, measure: wide) == "W…")
    }

    private func fit(_ title: String, _ detail: String?, _ width: Double) -> String {
        let count: (String) -> Double = { Double($0.count) }
        let (t, d) = TabText.fit(title: title, detail: detail, width: width, measureTitle: count, measureDetail: count)
        return t + (d.map { TabText.detailSeparator + $0 } ?? "")
    }

    @Test func titleGivesWayBeforeItsFolder() {
        #expect(fit("index.ts", "api", 14) == "index.ts · api")
        #expect(fit("index.ts", "api", 13) == "ind….ts · api")
        #expect(fit("index.ts", "api", 12) == "in….ts · api")
        #expect(fit("index.ts", "api", 11) == "inde… · api")
        #expect(fit("index.ts", "api", 9) == "in… · api")
        // Not even two letters beside the folder: the folder goes.
        #expect(fit("index.ts", "api", 8) == "index.ts")
        #expect(fit("index.ts", "api", 5) == "inde…")
        #expect(fit("index.ts", nil, 7) == "ind….ts")
        #expect(fit("index.ts", "", 8) == "index.ts")
    }
}

@Suite struct TabWidthsTests {
    private func allocate(_ natural: [Double], selected: Int?, available: Double, minimum: Double = 56,
                          reserve: Double = 0) -> TabWidths.Result {
        TabWidths.allocate(natural: natural, minimum: natural.map { _ in minimum }, selected: selected,
                           available: available, spacing: 2, cap: 220, overflowReserve: reserve)
    }

    @Test func roomForEveryTitle() {
        let r = allocate([100, 80, 120], selected: 1, available: 400)
        #expect(r.widths == [100, 80, 120])
        #expect(!r.overflows && r.hidden == 0 && r.viewport == 400)
        #expect(r.contentWidth(spacing: 2) == 304)
        // Exactly enough.
        #expect(allocate([100, 80, 120], selected: 1, available: 304).widths == [100, 80, 120])
    }

    @Test func noTabIsWiderThanTheCap() {
        #expect(allocate([300], selected: 0, available: 900).widths == [220])
        #expect(allocate([300, 100], selected: 1, available: 900).widths == [220, 100])
    }

    @Test func selectedKeepsItsTitleAndTheOthersShare() {
        // 300 - 2 gaps = 296; selected 100 leaves 196 for two tabs of 120.
        let r = allocate([120, 100, 120], selected: 1, available: 300)
        #expect(r.widths == [98, 100, 98])
        #expect(!r.overflows)
    }

    @Test func widestGiveWayFirst() {
        // 396 - 100 (selected) = 296 for 60, 200 and 150: the short one is
        // whole, the other two level at 118.
        let r = allocate([60, 200, 100, 150], selected: 2, available: 402)
        #expect(r.widths == [60, 118, 100, 118])
        #expect(r.contentWidth(spacing: 2) == 402)
    }

    @Test func noneBelowItsMinimum() {
        // Tabs with titles shorter than the minimum keep their own width.
        let r = allocate([40, 200, 100, 200], selected: 2, available: 260)
        #expect(r.widths == [40, 57, 100, 57])
        #expect(!r.overflows)
        // A dirty tab's higher minimum holds while the others level below it.
        let held = TabWidths.allocate(natural: [200, 200, 200, 100], minimum: [56, 76, 56, 56], selected: 3,
                                      available: 306)
        #expect(held.widths == [62, 76, 62, 100])
        #expect(!held.overflows)
    }

    @Test func withoutASelection() {
        #expect(allocate([200, 200], selected: nil, available: 202).widths == [100, 100])
        #expect(allocate([200, 200], selected: 7, available: 202).widths == [100, 100])
    }

    @Test func overflowsBelowTheMinimum() {
        // 8 tabs: 7 × 56 + 100 + 7 × 2 = 506 is the least they need.
        let natural = [Double](repeating: 120, count: 7) + [100]
        #expect(!allocate(natural, selected: 7, available: 506, reserve: 46).overflows)
        let r = allocate(natural, selected: 7, available: 505, reserve: 46)
        #expect(r.overflows)
        #expect(r.widths == [Double](repeating: 56, count: 7) + [100])
        #expect(r.viewport == 459)
        // Beside the selected tab's 100, six more of 56 (and their gaps) fit in 459.
        #expect(r.hidden == 1)
    }

    @Test func selectedIsNeverWiderThanTheViewport() {
        // A 480 pt folder window leaves about 200 pt, less than the cap.
        let r = allocate([300, 120, 120, 120], selected: 0, available: 200, reserve: 46)
        #expect(r.overflows)
        #expect(r.viewport == 154)
        #expect(r.widths == [154, 56, 56, 56])
        #expect(r.hidden == 3)
        // Counted beside the selected tab, wherever it is in the strip.
        #expect(allocate([120, 120, 120, 125], selected: 3, available: 235, reserve: 46).hidden == 2)
        #expect(allocate([122, 120, 120, 120], selected: 0, available: 235, reserve: 46).hidden == 2)
    }

    @Test func neverWiderThanAvailableUnlessItOverflows() {
        // Every width from generous to nothing, a few shapes of strip.
        let shapes: [[Double]] = [[117], [97, 91, 111, 125], [300, 60, 140, 90, 200, 75, 180, 110],
                                  [Double](repeating: 110, count: 12), [Double](repeating: 95, count: 20)]
        for natural in shapes {
            for selected in [0, natural.count / 2, natural.count - 1] {
                for available in stride(from: 1000.0, through: 0, by: -7) {
                    let r = allocate(natural, selected: selected, available: available, reserve: 46)
                    #expect(r.widths.count == natural.count)
                    if r.overflows {
                        #expect(r.viewport == max(available - 46, 0))
                        #expect(r.widths[selected] <= max(r.viewport, min(56, natural[selected])))
                        #expect(r.hidden >= 1 || natural.count == 1)
                    } else {
                        #expect(r.contentWidth(spacing: 2) <= available + 0.0001, "\(natural) in \(available)")
                        #expect(r.widths[selected] == min(natural[selected], 220))
                        for (i, w) in r.widths.enumerated() { #expect(w >= min(56, natural[i]) - 0.0001 && w <= natural[i]) }
                    }
                }
            }
        }
    }

    @Test func scrollsNoFurtherThanItTakes() {
        // Ten tabs of 56 with gaps of 2 are 578 wide; 200 show at a time.
        let widths = [Double](repeating: 56, count: 10)
        func offset(_ index: Int?, from: Double) -> Double {
            TabWidths.offset(showing: index, widths: widths, spacing: 2, viewport: 200, from: from)
        }
        // In view already: nothing moves, so the tab stays under the pointer.
        #expect(offset(1, from: 0) == 0)
        #expect(offset(4, from: 150) == 150)
        // Off the trailing edge: its end comes to the viewport's end.
        #expect(offset(4, from: 0) == 88)
        #expect(offset(9, from: 0) == 378)
        // Off the leading edge: its start comes to the viewport's start.
        #expect(offset(2, from: 378) == 116)
        #expect(offset(0, from: 378) == 0)
        // Never past the ends, whatever it is told it came from.
        #expect(offset(9, from: 5000) == 378)
        #expect(offset(nil, from: 5000) == 378)
        #expect(offset(nil, from: -20) == 0)
        #expect(offset(42, from: 100) == 100)
        // Tabs that all fit don't scroll.
        #expect(TabWidths.offset(showing: 2, widths: [56, 56, 56], viewport: 400, from: 120) == 0)
        // A tab wider than the viewport: its end when coming from before
        // it, its start when coming from after.
        #expect(TabWidths.offset(showing: 1, widths: [56, 300, 56], viewport: 200, from: 0) == 158)
        #expect(TabWidths.offset(showing: 1, widths: [56, 300, 56], viewport: 200, from: 216) == 58)
    }

    @Test func emptyStrip() {
        let r = allocate([], selected: nil, available: 100)
        #expect(r.widths.isEmpty && !r.overflows)
        #expect(allocate([], selected: nil, available: -5).viewport == 0)
    }
}

@Suite struct TabNamesTests {
    @Test func uniqueTitlesNeedNoFolder() {
        #expect(TabNames.details(titles: ["a.txt", "b.txt"], paths: ["/p/x/a.txt", "/p/x/b.txt"]) == [nil, nil])
        #expect(TabNames.details(titles: [], paths: []) == [])
    }

    @Test func sameTitleShowsTheParentFolder() {
        #expect(TabNames.details(titles: ["index.ts", "README.md", "index.ts"],
                                 paths: ["/p/api/index.ts", "/p/README.md", "/p/web/index.ts"]) == ["api", nil, "web"])
    }

    @Test func sameParentsAddFoldersUntilTheyDiffer() {
        #expect(TabNames.details(titles: ["main.swift", "main.swift"],
                                 paths: ["/p/a/src/main.swift", "/p/b/src/main.swift"]) == ["a/src", "b/src"])
        // Each tab gets only as many folders as it needs.
        #expect(TabNames.details(titles: ["index.ts", "index.ts", "index.ts"],
                                 paths: ["/p/x/api/index.ts", "/p/y/api/index.ts", "/p/web/index.ts"])
            == ["x/api", "y/api", "web"])
    }

    @Test func oneInsideTheOther() {
        #expect(TabNames.details(titles: ["a.txt", "a.txt"], paths: ["/a.txt", "/x/a.txt"]) == [nil, "x"])
        #expect(TabNames.details(titles: ["a.txt", "a.txt"], paths: ["/x/a.txt", "/x/x/a.txt"]) == ["x", "x/x"])
    }

    @Test func untitledTabsHaveNoFolder() {
        #expect(TabNames.details(titles: ["Untitled", "Untitled"], paths: [nil, nil]) == [nil, nil])
        #expect(TabNames.details(titles: ["notes", "notes"], paths: [nil, "/p/docs/notes"]) == [nil, "docs"])
    }

    @Test func homeIsATilde() {
        #expect(TabNames.abbreviatingHome("/Users/kim/Sources/app/main.swift", home: "/Users/kim") == "~/Sources/app/main.swift")
        #expect(TabNames.abbreviatingHome("/Users/kim", home: "/Users/kim/") == "~")
        #expect(TabNames.abbreviatingHome("/Users/kimberly/x.txt", home: "/Users/kim") == "/Users/kimberly/x.txt")
        #expect(TabNames.abbreviatingHome("/etc/hosts", home: "/Users/kim") == "/etc/hosts")
        #expect(TabNames.abbreviatingHome("/etc/hosts", home: "/") == "/etc/hosts")
        #expect(TabNames.abbreviatingHome("/etc/hosts", home: "") == "/etc/hosts")
    }
}
