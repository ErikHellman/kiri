import Foundation
import Testing
@testable import KiriKit

@Suite struct FuzzyMatchTests {
    private func match(_ query: String, _ text: String, path: Bool = false) -> FuzzyMatch? {
        FuzzyQuery(query).match(FuzzyCandidate(text, isPath: path))
    }

    private func score(_ query: String, _ text: String, path: Bool = false) -> Int {
        FuzzyQuery(query).score(FuzzyCandidate(text, isPath: path)) ?? Int.min
    }

    /// The letters a match marks, as text.
    private func marked(_ query: String, _ text: String, path: Bool = false) -> [String] {
        guard let match = match(query, text, path: path) else { return [] }
        let units = Array(text.utf16)
        return match.ranges.map { String(utf16CodeUnits: Array(units[$0]), count: $0.count) }
    }

    @Test func theLettersInOrderAreAMatchAndAnythingElseIsNot() {
        #expect(match("grsw", "Greeter.swift") != nil)
        #expect(match("swgr", "Greeter.swift") == nil)
        #expect(match("greeterx", "Greeter.swift") == nil)
        #expect(match("q", "Greeter.swift") == nil)
        #expect(match("toolongforit", "short") == nil)
        // Every letter there, but one of them not often enough.
        #expect(match("ee", "one") == nil)
    }

    @Test func nothingTypedMatchesEverythingAndMarksNothing() {
        #expect(FuzzyQuery("").isEmpty)
        #expect(FuzzyQuery("  ").isEmpty)
        #expect(match("", "anything") == FuzzyMatch(score: 0, ranges: []))
        #expect(match("", "") == FuzzyMatch(score: 0, ranges: []))
        #expect(match("a", "") == nil)
    }

    @Test func caseAndSpacesDoNotCount() {
        #expect(match("GREETER", "greeter.swift") != nil)
        #expect(match("greeter", "GREETER.SWIFT") != nil)
        #expect(marked("theme tide", "Theme: Tide") == ["Theme", "Tide"])
        #expect(marked("ÅNG", "ångström.txt") == ["ång"])
        #expect(marked("привет", "ПРИВЕТ.md") == ["ПРИВЕТ"])
    }

    @Test func theMatchSaysWhereTheLettersAre() {
        #expect(match("grsw", "Greeter.swift")?.ranges == [0..<2, 8..<10])
        #expect(marked("tc", "Toggle Comment") == ["T", "C"])
        #expect(marked("save", "Save As…") == ["Save"])
        // Offsets are UTF-16 units of the text itself, also after an emoji.
        #expect(match("b", "😀b")?.ranges == [2..<3])
        // One range for letters that stand together, in order.
        let ranges = match("edsc", "App/Kiri/EditorScreen.swift", path: true)?.ranges ?? []
        #expect(ranges == [9..<11, 15..<17])
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound < $1.lowerBound })
    }

    @Test func lettersThatStandTogetherBeatScatteredOnes() {
        #expect(score("find", "Find Next") > score("find", "File Index Node"))
        #expect(score("gree", "Greeter.swift") > score("gree", "Garbage/reader/e.e", path: true))
        // The best way through a text, not the first: "sw" at ".swift", not "S…w".
        #expect(marked("sw", "Sources/Tidepool/new.swift", path: true) == ["sw"])
        #expect(match("sw", "Sources/Tidepool/new.swift", path: true)?.ranges == [21..<23])
    }

    @Test func startsOfWordsCount() {
        #expect(score("tc", "Toggle Comment") > score("tc", "Text Encoding"))
        // Two words' first letters beat the same two letters met inside a word.
        #expect(score("tc", "Toggle Comment") > score("tc", "Theme: Matcha"))
        #expect(score("tc", "Toggle Comment") > score("tc", "Keyboard Shortcuts"))
        // And letters in a row from a word's start beat a row from inside one.
        #expect(score("lin", "Wrap Lines") > score("lin", "Smaller Inline"))
        #expect(marked("lin", "Go to Line…") == ["Lin"])
        #expect(score("es", "EditorScreen.swift") > score("es", "Greeters.swift"))
        #expect(score("rm", "read_me.txt") > score("rm", "format.txt"))
        #expect(marked("es", "EditorScreen.swift") == ["E", "S"])
        #expect(marked("wl", "Wrap Lines") == ["W", "L"])
    }

    @Test func aFilesNameCountsForMoreThanItsFolders() {
        let query = FuzzyQuery("main")
        let inName = FuzzyCandidate("src/app/main.swift", isPath: true)
        let inFolder = FuzzyCandidate("main/src/other.swift", isPath: true)
        #expect(query.score(inName)! > query.score(inFolder)!)
        #expect(inName.nameStart == 8 && inFolder.nameStart == 9)
        // The start of a folder's name still beats the middle of one.
        #expect(score("kit", "Sources/KiriKit/a.swift", path: true) > score("kit", "Sources/Biscuits/a.swift", path: true))
        // And a match's letters can be told apart: the folders', the name's.
        let match = FuzzyQuery("kirihon").match(FuzzyCandidate("Sources/KiriKit/Honey.swift", isPath: true))!
        #expect(match.ranges(in: 0..<16) == [8..<12])
        #expect(match.ranges(in: 16..<27) == [0..<3])
    }

    @Test func rankingPutsTheBestFirstAndKeepsTiesInOrder() {
        let paths = ["docs/DESIGN.md", "App/Kiri/EditorScreen.swift", "App/Kiri/EditorView.swift", "README.md",
                     "KiriKit/Sources/KiriKit/Honey.swift", "App/Kiri/SelfTest.swift"]
        let candidates = paths.map { FuzzyCandidate($0, isPath: true) }
        let ranked = FuzzyQuery("edi").rank(candidates, limit: 10)!
        #expect(ranked.map { paths[$0.index] }.prefix(2) == ["App/Kiri/EditorView.swift", "App/Kiri/EditorScreen.swift"])
        #expect(!ranked.contains { paths[$0.index] == "README.md" })
        #expect(ranked.allSatisfy { $0.match == FuzzyQuery("edi").match(candidates[$0.index]) })
        #expect(FuzzyQuery("e").rank(candidates, limit: 2)!.count == 2)
        // Nothing typed: everything, as it came.
        #expect(FuzzyQuery("").rank(candidates, limit: 4)!.map(\.index) == [0, 1, 2, 3])
        // Equal scores: the shorter text first, then the one that came first.
        let twins = ["b/notes.txt", "a/notes.txt", "notes.txt", "c/notes.txt"].map { FuzzyCandidate($0, isPath: true) }
        #expect(FuzzyQuery("notes").rank(twins, limit: 3)!.map(\.index) == [2, 0, 1])
        // The shorter name before the shorter path: the file that is all of what was typed.
        let names = ["Tests/GreeterTests.swift", "Sources/Tidepool/Greeter.swift"].map { FuzzyCandidate($0, isPath: true) }
        #expect(FuzzyQuery("gr").rank(names, limit: 2)!.map(\.index) == [1, 0])
        #expect(FuzzyQuery("zzz").rank(candidates, limit: 10)!.isEmpty)
        #expect(FuzzyQuery("e").rank(candidates, limit: 10, isCancelled: { true }) != nil) // too few to be asked
    }

    @Test func lettersPickedUpAcrossALongPathAreNotListed() {
        // Every letter of "greeter" is in this path, in order, and none of them was meant.
        let noise = FuzzyCandidate("/var/folders/zb/zp7xgnk57qg_z5jqct814fh00000gn/T/kiri-palette-test-96439/elsewhere.txt", isPath: true)
        let meant = FuzzyCandidate("Sources/App/Greeter.swift", isPath: true)
        let query = FuzzyQuery("greeter")
        #expect(query.match(noise) != nil)
        #expect(query.score(noise)! < query.weakest, "\(query.score(noise)!) of \(query.weakest)")
        #expect(query.rank([noise, meant], limit: 10)!.map(\.index) == [1])
        // What was meant stays, also when it is spread out: first letters, a path's parts.
        for (typed, text) in [("tc", "Toggle Comment"), ("grsw", "Greeter.swift"), ("sa", "Close All"), ("srcmain", "src/very/long/path/of/many/folders/main.swift"),
                              ("fnr", "Find and Replace…"), ("s", "Makefile.swift"), ("mkfl", "Makefile"), ("idx", "lib/index.js"), ("edscr", "App/Kiri/EditorScreen.swift")] {
            let q = FuzzyQuery(typed)
            #expect(q.rank([FuzzyCandidate(text, isPath: text.contains("/"))], limit: 1)!.count == 1, "\(typed) in \(text): \(q.score(FuzzyCandidate(text)) ?? -1) of \(q.weakest)")
        }
    }

    @Test func aScoreIsTheSameWithAndWithoutTheRanges() {
        let texts = ["App/Kiri/EditorScreen.swift", "Toggle Comment", "a/b/c/d/e/f/g.swift", "aaaaaaaaaaaaaaaa", "Sources/Tidepool/Greeter.swift"]
        for query in ["a", "es", "swift", "aaa", "gre", "abcdefg", "tc"] {
            for text in texts {
                let candidate = FuzzyCandidate(text, isPath: text.contains("/"))
                let q = FuzzyQuery(query)
                #expect(q.score(candidate) == q.match(candidate)?.score, "\(query) in \(text)")
                // The ranges hold exactly the query's letters, in order.
                if let match = q.match(candidate) {
                    let units = Array(text.utf16)
                    let found = match.ranges.flatMap { units[$0] }.map(Fuzzy.fold)
                    #expect(found == Array(query.utf16).map(Fuzzy.fold), "\(query) in \(text): \(match.ranges)")
                }
            }
        }
    }

    /// A folder as big as the index holds (20 000 files) is searched for
    /// six letters well within the time a key has before the next frame
    /// or two: the palette matches on the main thread, at every key.
    @Test func twentyThousandPathsAreSearchedInAFrameOrTwo() {
        let folders = ["Sources", "Tests", "App", "docs", "scripts", "KiriKit", "Fixtures", "Resources", "views", "models",
                       "controllers", "components", "utilities", "network", "storage", "widgets"]
        let names = ["Editor", "Greeter", "Document", "Window", "Sidebar", "Palette", "Status", "Theme", "Syntax", "Search",
                     "Layout", "Honey", "Glass", "Motion", "Command", "Session", "Preview", "Recent", "Format", "Folder"]
        let kinds = ["View", "Controller", "Model", "Tests", "Helper", "Store", "Style", "Item", "Screen", "Bar"]
        let extensions = ["swift", "md", "json", "ts", "py", "rs", "yaml", "txt"]
        var paths: [String] = []
        paths.reserveCapacity(20_000)
        for i in 0..<20_000 {
            let a = folders[i % folders.count], b = folders[(i / 16 + 3) % folders.count], c = names[(i / 7) % names.count]
            paths.append("\(a)/\(b)/\(c.lowercased())\(i % 97)/\(names[i % names.count])\(kinds[(i / 3) % kinds.count])\(i % 13).\(extensions[i % extensions.count])")
        }
        let candidates = paths.map { FuzzyCandidate($0, isPath: true) }
        let clock = ContinuousClock()
        /// The best of three: the other suites run at the same time.
        func time(_ query: String) -> (Duration, Int) {
            let q = FuzzyQuery(query)
            var best = Duration.seconds(1), rows = 0
            for _ in 0..<3 {
                let start = clock.now
                rows = q.rank(candidates, limit: 50)!.count
                best = min(best, clock.now - start)
            }
            return (best, rows)
        }
        var times: [Duration] = []
        for query in ["edview", "sidbar", "thstyl", "greetr", "docmod", "palscr", "srcedi"] {
            let (took, rows) = time(query)
            times.append(took)
            #expect(rows > 0, "\(query) finds something")
        }
        let worst = times.max()!, typical = times.sorted()[times.count / 2]
        // The first key, which nearly every path has, and letters no path has.
        let (one, _) = time("s"), (none, noRows) = time("qqqqqq")
        print("FUZZY 20 000 paths: six letters typical \(typical), worst \(worst); one letter \(one); no match \(none)")
        // A debug build, as `swift test` makes (a release build is several
        // times faster), on a Mac that may be saving power.
        #expect(worst < timeLimit(.milliseconds(33)), "six letters, worst \(worst)")
        #expect(one < timeLimit(.milliseconds(66)), "one letter \(one)")
        #expect(noRows == 0)
    }
}
