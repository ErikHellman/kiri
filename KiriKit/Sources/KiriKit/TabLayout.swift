import Foundation

// The tab strip's arithmetic, free of SwiftUI so it tests on Linux: how a
// file name shortens, how the tabs share the strip's width, what tells two
// tabs with the same name apart, and how a path reads in a tooltip.

/// Shortening a tab's title.
public enum TabText {
    /// What stands for the letters left out.
    public static let ellipsis = "…"
    /// Between a title and the folder that tells it apart: "index.ts · api".
    public static let detailSeparator = " · "

    /// A file name as its stem and its extension with the dot:
    /// "Greeter.swift" is ("Greeter", ".swift"). Dotfiles (".gitignore"),
    /// names without a dot and endings too long or too odd to be an
    /// extension have none.
    public static func split(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = name[dot...]
        let letters = ext.dropFirst()
        guard (1...12).contains(letters.count), !letters.contains(where: \.isWhitespace) else { return (name, "") }
        return (String(name[..<dot]), String(ext))
    }

    /// `name` shortened to fit `width`, as `measure` counts widths. The
    /// middle goes first, so the extension survives ("Greet….swift"). When
    /// that would leave fewer than three letters of the stem, the extension
    /// goes instead ("Gre…"): the start of a name says more than its type.
    public static func middleTruncated(_ name: String, toFit width: Double, measure: (String) -> Double) -> String {
        if measure(name) <= width { return name }
        let (stem, ext) = split(name)
        let letters = Array(stem)
        if !ext.isEmpty, letters.count > 3,
           let kept = longest(3...(letters.count - 1), where: { measure(String(letters[..<$0]) + ellipsis + ext) <= width }) {
            return String(letters[..<kept]) + ellipsis + ext
        }
        // Without its extension a whole stem may stay: "Greeter…".
        let most = ext.isEmpty ? letters.count - 1 : letters.count
        if most >= 1, let kept = longest(1...most, where: { measure(String(letters[..<$0]) + ellipsis) <= width }) {
            return String(letters[..<kept]) + ellipsis
        }
        return ellipsis
    }

    /// `name` in at most `maxCharacters` characters, the ellipsis included.
    public static func middleTruncated(_ name: String, maxCharacters: Int) -> String {
        middleTruncated(name, toFit: Double(maxCharacters)) { Double($0.count) }
    }

    /// A title and the folder that tells it apart, shortened to fit `width`.
    /// The title gives way first, since the tabs that carry a folder all
    /// have the same title; when even two letters of it don't fit beside
    /// the folder, the folder goes.
    public static func fit(title: String, detail: String?, width: Double,
                           measureTitle: (String) -> Double,
                           measureDetail: (String) -> Double) -> (title: String, detail: String?) {
        guard let detail, !detail.isEmpty else {
            return (middleTruncated(title, toFit: width, measure: measureTitle), nil)
        }
        let left = width - measureDetail(detailSeparator + detail)
        let least = title.count <= 3 ? title : String(title.prefix(2)) + ellipsis
        if measureTitle(least) <= left {
            return (middleTruncated(title, toFit: left, measure: measureTitle), detail)
        }
        return (middleTruncated(title, toFit: width, measure: measureTitle), nil)
    }

    /// The largest count in `range` that `fits`, when every smaller one fits too.
    private static func longest(_ range: ClosedRange<Int>, where fits: (Int) -> Bool) -> Int? {
        guard fits(range.lowerBound) else { return nil }
        var low = range.lowerBound, high = range.upperBound
        while low < high {
            let mid = (low + high + 1) / 2
            if fits(mid) { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// How the tabs share the strip.
public enum TabWidths {
    public struct Result: Equatable, Sendable {
        /// Each tab's width, in order.
        public var widths: [Double]
        /// The tabs don't fit even at their narrowest: the strip scrolls,
        /// and shows the button that lists every tab.
        public var overflows: Bool
        /// The width the tabs show in: all of it, or what the button leaves.
        public var viewport: Double
        /// How many tabs are out of view at any time in a strip that scrolls.
        public var hidden: Int

        /// The tabs and the gaps between them.
        public func contentWidth(spacing: Double) -> Double {
            widths.reduce(0, +) + spacing * Double(max(widths.count - 1, 0))
        }
    }

    /// Widths for the tabs in `available` points (the gaps of `spacing`
    /// between them included).
    ///
    /// - With room for every whole title, each tab is as wide as its title
    ///   (`natural`), up to `cap`.
    /// - Otherwise the selected tab keeps its whole title (up to `cap`) and
    ///   the others share what is left: the widest give way first, none
    ///   below its `minimum`.
    /// - When that isn't enough either, every other tab is at its minimum
    ///   and the strip scrolls in what `overflowReserve` (the "more" button)
    ///   leaves; the selected tab is never wider than that.
    public static func allocate(natural: [Double], minimum: [Double], selected: Int?, available: Double,
                                spacing: Double = 2, cap: Double = 220, overflowReserve: Double = 0) -> Result {
        let count = natural.count
        guard count > 0 else { return Result(widths: [], overflows: false, viewport: max(available, 0), hidden: 0) }
        let want = natural.map { min($0, cap) }
        let floors = (0..<count).map { min($0 < minimum.count ? minimum[$0] : 0, want[$0]) }
        let room = available - spacing * Double(count - 1)
        if want.reduce(0, +) <= room {
            return Result(widths: want, overflows: false, viewport: available, hidden: 0)
        }
        let selected = selected.flatMap { (0..<count).contains($0) ? $0 : nil }
        let others = (0..<count).filter { $0 != selected }
        let rest = room - (selected.map { want[$0] } ?? 0)
        if rest >= others.reduce(0, { $0 + floors[$1] }) {
            var widths = want
            // Level the widest down until the others fit; a tab that would
            // drop below its minimum stays there and the rest level again.
            var held = Set<Int>()
            while true {
                let free = others.filter { !held.contains($0) }
                let level = level(free.map { want[$0] }, toFit: rest - held.reduce(0) { $0 + floors[$1] })
                let low = free.filter { min(want[$0], level) < floors[$0] }
                for i in free { widths[i] = min(want[i], level) }
                if low.isEmpty { break }
                for i in low { widths[i] = floors[i]; held.insert(i) }
            }
            return Result(widths: widths, overflows: false, viewport: available, hidden: 0)
        }
        let viewport = max(available - overflowReserve, 0)
        var widths = floors
        if let selected { widths[selected] = max(min(want[selected], viewport), floors[selected]) }
        // Beside the selected tab, as many of the others as could show at once.
        var left = viewport - (selected.map { widths[$0] } ?? -spacing)
        var shown = selected == nil ? 0 : 1
        for width in others.map({ widths[$0] }).sorted() {
            left -= width + spacing
            if left < 0 { break }
            shown += 1
        }
        return Result(widths: widths, overflows: true, viewport: viewport, hidden: max(count - shown, 1))
    }

    /// The width `L` at which `widths`, each cut to `L` at most, add up to `total`.
    private static func level(_ widths: [Double], toFit total: Double) -> Double {
        var left = total
        let sorted = widths.sorted()
        for (i, width) in sorted.enumerated() {
            let share = left / Double(sorted.count - i)
            if width >= share { return max(share, 0) }
            left -= width
        }
        return sorted.last ?? 0
    }
}

/// Telling tabs apart, and saying where their files are.
public enum TabNames {
    /// For each tab, the folder to show after its title, or nil when the
    /// title is enough. Tabs that share a title get their parent folder
    /// ("api", "web"); where the parents are the same too, as many folders
    /// as it takes ("a/src", "b/src"). Tabs without a path (untitled) get none.
    public static func details(titles: [String], paths: [String?]) -> [String?] {
        var details = [String?](repeating: nil, count: titles.count)
        var groups: [String: [Int]] = [:]
        for (i, title) in titles.enumerated() { groups[title, default: []].append(i) }
        for members in groups.values where members.count > 1 {
            // Each member's folders, nearest first.
            var folders: [Int: [String]] = [:]
            for i in members where i < paths.count {
                guard let path = paths[i] else { continue }
                folders[i] = Array(path.split(separator: "/").dropLast().reversed().map(String.init))
            }
            for (i, own) in folders where !own.isEmpty {
                let depth = (1...own.count).first { d in
                    !folders.contains { $0.key != i && Array($0.value.prefix(d)) == Array(own.prefix(d)) }
                } ?? own.count
                details[i] = own.prefix(depth).reversed().joined(separator: "/")
            }
        }
        return details
    }

    /// `path` with the home folder written as `~`, as in a shell.
    public static func abbreviatingHome(_ path: String, home: String) -> String {
        var home = home
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
