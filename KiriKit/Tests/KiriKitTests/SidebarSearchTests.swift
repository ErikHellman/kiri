import Testing
@testable import KiriKit

@Suite struct SidebarSearchTests {
    private typealias Entry = SidebarSearch.Entry

    private func file(_ path: String) -> Entry { Entry(path: path, isFolder: false) }
    private func folder(_ path: String) -> Entry { Entry(path: path, isFolder: true) }

    /// A folder as the sidebar shows it, top to bottom, everything expanded.
    private var tree: [Entry] {
        [folder("docs"), folder("docs/notes"), file("docs/notes/idea.md"), file("docs/guide.md"),
         folder("Sources"), folder("Sources/Tidepool"), file("Sources/Tidepool/greet2.swift"), file("Sources/Tidepool/greet10.swift"),
         file("Sources/Tidepool/Greeter.swift"), file("Sources/main.swift"),
         file(".gitignore"), file("Greeting.txt"), file("README.md")]
    }

    @Test func aNameMatchesWithoutCaseOrAccents() {
        #expect(SidebarSearch.matches("Greeter.swift", query: "greet"))
        #expect(SidebarSearch.matches("Greeter.swift", query: "EETER.S"))
        #expect(SidebarSearch.matches("Café.md", query: "cafe"))
        #expect(SidebarSearch.matches("Cafe.md", query: "café"))
        // A name as an older Mac disk keeps it, the accent a mark of its own.
        #expect(SidebarSearch.matches("Cafe\u{301}.md", query: "café"))
        #expect(SidebarSearch.matches("Cafe\u{301}.md", query: "CAFE.MD"))
        #expect(SidebarSearch.matches("a.txt", query: "a.txt"))
        #expect(!SidebarSearch.matches("a.tx", query: "a.txt"))
        #expect(SidebarSearch.find("ÉE", in: [file("x/greet.swift")]).count == 1)
        #expect(!SidebarSearch.matches("Greeter.swift", query: "greets"))
        #expect(!SidebarSearch.matches("Greeter.swift", query: ""))
    }

    @Test func onlyTheNameIsSearchedNotTheFoldersAboveIt() {
        let found = SidebarSearch.find("tide", in: tree)
        #expect(found == [folder("Sources/Tidepool")])
        #expect(file("Sources/Tidepool/Greeter.swift").name == "Greeter.swift")
        #expect(folder("Sources").name == "Sources")
    }

    @Test func filesAndFoldersAreFoundInTheSidebarsOrder() {
        // Shuffled, with doubles: the sidebar's order, each once.
        let found = SidebarSearch.find("e", in: tree.reversed() + tree)
        #expect(found.map(\.path) == [
            "docs/notes", "docs/notes/idea.md", "docs/guide.md",
            "Sources", "Sources/Tidepool", "Sources/Tidepool/greet2.swift", "Sources/Tidepool/greet10.swift",
            "Sources/Tidepool/Greeter.swift",
            ".gitignore", "Greeting.txt", "README.md",
        ])
        #expect(SidebarSearch.find("", in: tree).isEmpty)
        #expect(SidebarSearch.find("nothing like it", in: tree).isEmpty)
    }

    @Test func theOrderIsTheSidebars() {
        // Shuffled in every way, sorting gives the tree back.
        #expect(tree.reversed().sorted(by: SidebarSearch.inTreeOrder) == tree)
        #expect(tree.shuffled().sorted(by: SidebarSearch.inTreeOrder) == tree)
        // A folder before what is in it, folders before files, numbers as
        // numbers and before letters.
        #expect(SidebarSearch.inTreeOrder(folder("a"), file("a/z.txt")))
        #expect(SidebarSearch.inTreeOrder(file("z/a.txt"), file("a.txt")))
        #expect(SidebarSearch.inTreeOrder(folder("zz"), file("aa")))
        #expect(SidebarSearch.inTreeOrder(file("f2.txt"), file("f10.txt")))
        #expect(SidebarSearch.inTreeOrder(file("greet10.swift"), file("Greeter.swift")))
        #expect(!SidebarSearch.inTreeOrder(file("a.txt"), file("a.txt")))
    }

    @Test func listsInTheSidebarsOrderMergeAsOne() {
        let all = SidebarSearch.ordered(tree.shuffled() + tree)
        #expect(all == tree)
        // The folder's files from the index, and the rows that show (which
        // have some of the same, and folders the index leaves out).
        let files = SidebarSearch.ordered(tree.filter { !$0.isFolder })
        let shown = SidebarSearch.ordered([folder("Sources"), folder("Sources/Tidepool"), file("Sources/main.swift"),
                                           folder("build"), file("README.md")])
        let merged = SidebarSearch.merged(files, shown)
        #expect(merged.map(\.path) == ["build"] + tree.filter { !$0.isFolder || $0.path.hasPrefix("Sources") }.map(\.path)
            .sorted { a, b in SidebarSearch.inTreeOrder(tree.first { $0.path == a }!, tree.first { $0.path == b }!) })
        #expect(SidebarSearch.find("e", inOrdered: all) == SidebarSearch.find("e", in: tree))
    }

    /// `ordered` sorts each folder on its own; that is the order one sort
    /// of every path by `inTreeOrder` gives, folders above files or not.
    @Test func orderingByFolderIsTheOrderOfOneBigSort() {
        let names = ["b", "A", "a", "file2", "file10", "Zed", "café", "cafe", "x.swift", "X.md"]
        var entries: [Entry] = []
        for (i, a) in names.enumerated() {
            entries.append(file(a))
            entries.append(file("\(a)dir/\(names[(i + 3) % names.count])"))
            entries.append(file("\(a)dir/\(names[(i + 5) % names.count])dir/\(names[(i + 7) % names.count])"))
            if i % 2 == 0 { entries.append(folder("\(a)dir")) }
            if i % 3 == 0 { entries.append(folder("empty\(a)")) }
        }
        var seen = Set<String>()
        let sorted = entries.filter { seen.insert($0.path).inserted }.sorted(by: SidebarSearch.inTreeOrder)
        #expect(SidebarSearch.ordered(entries.shuffled()).map(\.path) == sorted.map(\.path))
    }

    /// A folder as big as the index holds (20 000 files): put in order once
    /// when it has been read, then searched at every key on the main thread
    /// in a frame or two, even for one letter that most names have.
    @Test func twentyThousandPathsAreSearchedInAFrameOrTwo() {
        let folders = ["Sources", "Tests", "App", "docs", "scripts", "KiriKit", "Fixtures", "Resources", "views", "models",
                       "controllers", "components", "utilities", "network", "storage", "widgets"]
        let names = ["Editor", "Greeter", "Document", "Window", "Sidebar", "Palette", "Status", "Theme", "Syntax", "Search",
                     "Layout", "Honey", "Glass", "Motion", "Command", "Session", "Preview", "Recent", "Format", "Folder"]
        var paths: [String] = []
        for i in 0..<20_000 {
            let a = folders[i % folders.count], b = folders[(i / 16 + 3) % folders.count], c = names[(i / 7) % names.count]
            paths.append("\(a)/\(b)/\(c.lowercased())\(i % 97)/\(names[i % names.count])\(i % 13).swift")
        }
        let clock = ContinuousClock()
        let start = clock.now
        let entries = paths.map { file($0) } + SidebarSearch.folders(above: paths).map { folder($0) }
        let ordered = SidebarSearch.ordered(entries)
        let sorting = clock.now - start
        func time(_ query: String) -> (Duration, Int) {
            var best = Duration.seconds(1), count = 0
            for _ in 0..<3 {
                let start = clock.now
                count = SidebarSearch.find(query, inOrdered: ordered).count
                best = min(best, clock.now - start)
            }
            return (best, count)
        }
        let (one, many) = time("e"), (word, some) = time("greeter1"), (none, nothing) = time("qqqq")
        print("SIDEBAR SEARCH 20 000 files: ordered once in \(sorting); one letter \(one) (\(many) found), a word \(word) (\(some)), nothing \(none)")
        #expect(many > 10_000 && some > 0 && nothing == 0)
        // A debug build, as `swift test` makes, with the other suites running.
        #expect(one < .milliseconds(66), "one letter \(one)")
        #expect(sorting < .seconds(1), "ordering \(sorting)")
    }

    @Test func theFoldersAboveFilesAreThereEachOnce() {
        #expect(SidebarSearch.folders(above: ["a/b/c.txt", "a/b/d.txt", "a/e.txt", "f.txt"]) == ["a", "a/b"])
        #expect(SidebarSearch.folders(above: []).isEmpty)
    }

    @Test func typingGoesToTheFirstFoundFromTheRowItStartedOn() {
        let found = SidebarSearch.find("greet", in: tree) // greet2, greet10, Greeter, Greeting.txt
        #expect(found.count == 4)
        // From the top, from a row that is found, from one between, and from below the last: round to the first.
        #expect(SidebarSearch.index(in: found, from: nil, .atOrAfter) == 0)
        #expect(SidebarSearch.index(in: found, from: file("Sources/Tidepool/greet10.swift"), .atOrAfter) == 1)
        #expect(SidebarSearch.index(in: found, from: file("Sources/main.swift"), .atOrAfter) == 3)
        #expect(SidebarSearch.index(in: found, from: file("README.md"), .atOrAfter) == 0)
        // From a folder that holds them: the first inside it.
        #expect(SidebarSearch.index(in: found, from: folder("Sources"), .atOrAfter) == 0)
        #expect(SidebarSearch.index(in: [], from: nil, .atOrAfter) == nil)
    }

    @Test func nextAndPreviousGoRoundAtTheEnds() {
        let found = SidebarSearch.find("greet", in: tree)
        let last = found[3], first = found[0]
        #expect(SidebarSearch.index(in: found, from: first, .after) == 1)
        #expect(SidebarSearch.index(in: found, from: last, .after) == 0)
        #expect(SidebarSearch.index(in: found, from: first, .before) == 3)
        #expect(SidebarSearch.index(in: found, from: last, .before) == 2)
        // From a row that isn't found: the nearest one below, or above.
        #expect(SidebarSearch.index(in: found, from: file("Sources/main.swift"), .after) == 3)
        #expect(SidebarSearch.index(in: found, from: file("Sources/main.swift"), .before) == 2)
        #expect(SidebarSearch.index(in: found, from: folder("docs"), .before) == 3)
        // No row: from the top down, or from the bottom up.
        #expect(SidebarSearch.index(in: found, from: nil, .after) == 0)
        #expect(SidebarSearch.index(in: found, from: nil, .before) == 3)
        // One found: it, whichever way.
        let one = [first]
        #expect(SidebarSearch.index(in: one, from: first, .after) == 0)
        #expect(SidebarSearch.index(in: one, from: first, .before) == 0)
    }
}
