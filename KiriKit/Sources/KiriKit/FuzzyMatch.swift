import Foundation

// Fuzzy matching for the command palette: the letters typed, in order but
// not necessarily together, found in a file's path or a command's name.
// "grsw" finds "Greeter.swift"; "tc" finds "Toggle Comment".
//
// A match is scored so that what a person most likely meant comes first:
// letters that stand together, letters that begin a word ("tc") or a path
// component, and for a path the file's own name over the folders it is in.
// The matcher also says where the letters were found, so a row can mark
// them.

/// Something a query can be matched against, prepared once (a folder's
/// files are prepared when the folder is read, not at every key).
public struct FuzzyCandidate: Sendable {
    // periphery:ignore - what the offsets are into
    public let text: String
    /// Where the file's name begins in a path (UTF-16 offset); 0 for
    /// anything that is not a path.
    public let nameStart: Int
    /// `text` in UTF-16 units with case folded away, as many units as
    /// `text` has, so a match's offsets are offsets into `text`.
    let units: [UInt16]
    /// What a match at each unit is worth beyond the letter itself.
    let bonus: [Int8]
    /// Which letters occur at all: a query with a letter that doesn't is
    /// turned away without a look at the text.
    let mask: UInt64

    /// - Parameter isPath: `text` is a path: its components begin words,
    ///   and matches in its last component (the file's name) count for more.
    public init(_ text: String, isPath: Bool = false) {
        self.text = text
        let original = Array(text.utf16)
        var units = original
        var bonus = [Int8](repeating: 0, count: original.count)
        var mask: UInt64 = 0
        var nameStart = 0
        if isPath, let slash = original.lastIndex(of: Fuzzy.slash) { nameStart = slash + 1 }
        var previous: UInt16 = Fuzzy.slash
        for i in original.indices {
            let unit = original[i]
            let folded = Fuzzy.fold(unit)
            units[i] = folded
            mask |= Fuzzy.bit(folded)
            var worth = 0
            if i == 0 || (isPath && previous == Fuzzy.slash) {
                worth = i == nameStart ? Fuzzy.nameStartBonus : Fuzzy.componentBonus
            } else if !Fuzzy.isWord(previous), Fuzzy.isWord(unit) {
                worth = Fuzzy.wordBonus
            } else if Fuzzy.isLower(previous), Fuzzy.isUpper(unit) {
                worth = Fuzzy.humpBonus
            }
            if isPath, i >= nameStart { worth += Fuzzy.nameBonus }
            bonus[i] = Int8(worth)
            previous = unit
        }
        self.units = units
        self.bonus = bonus
        self.mask = mask
        self.nameStart = nameStart
    }
}

/// Where a query was found in a candidate, and how good the match is.
public struct FuzzyMatch: Equatable, Sendable {
    /// Higher is better. Only comparable between matches of one query.
    public let score: Int
    /// The matched letters, as ranges of UTF-16 offsets into the
    /// candidate's text, in order; letters that stand together are one range.
    public let ranges: [Range<Int>]

    public init(score: Int, ranges: [Range<Int>]) {
        self.score = score
        self.ranges = ranges
    }
}

/// What was typed, prepared for matching. Case and spaces don't count:
/// "theme tide" finds "Theme: Tide".
public struct FuzzyQuery: Sendable {
    let units: [UInt16]
    let mask: UInt64

    /// A query longer than this is cut: nobody types a path that long,
    /// and the work grows with the length.
    public static let longest = 64

    public init(_ text: String) {
        var units: [UInt16] = []
        var mask: UInt64 = 0
        for unit in text.utf16 where !Fuzzy.isSpace(unit) && units.count < Self.longest {
            let folded = Fuzzy.fold(unit)
            units.append(folded)
            mask |= Fuzzy.bit(folded)
        }
        self.units = units
        self.mask = mask
    }

    /// Nothing to look for: everything matches, with nothing marked.
    public var isEmpty: Bool { units.isEmpty }

    /// The least a match must score to be listed (`rank`): what its
    /// letters alone are worth. Under that, the letters were picked up
    /// one here and one there across a long path, with more lost to the
    /// gaps than any start of a word gave back, and the row would only
    /// be noise among the ones that were meant.
    public var weakest: Int { Fuzzy.letter * units.count }

    /// The best way the query is found in `candidate`, or nil if its
    /// letters are not all there in order.
    public func match(_ candidate: FuzzyCandidate) -> FuzzyMatch? {
        var work = Fuzzy.Work()
        defer { work.free() }
        guard let score = work.score(self, in: candidate, tracing: true) else { return nil }
        return FuzzyMatch(score: score, ranges: work.ranges)
    }

    /// How good the best match in `candidate` is, without where it is.
    public func score(_ candidate: FuzzyCandidate) -> Int? {
        var work = Fuzzy.Work()
        defer { work.free() }
        return work.score(self, in: candidate, tracing: false)
    }

    /// The candidates the query is found in, best first, at most `limit`
    /// of them, without the matches too weak to mean anything (`weakest`).
    /// Equal scores keep the shorter name first ("Greeter.swift" before
    /// "GreeterTests.swift", wherever they are), then the shorter text,
    /// then the order they came in. With nothing typed: the first
    /// `limit`, as they came.
    ///
    /// - Parameter isCancelled: asked now and then; true gives up (nil).
    public func rank(_ candidates: [FuzzyCandidate], limit: Int,
                     isCancelled: () -> Bool = { false }) -> [(index: Int, match: FuzzyMatch)]? {
        let limit = max(0, limit)
        guard !isEmpty else {
            return candidates.indices.prefix(limit).map { ($0, FuzzyMatch(score: 0, ranges: [])) }
        }
        guard limit > 0 else { return [] }
        var work = Fuzzy.Work()
        defer { work.free() }
        // The best `limit` so far, best first: a folder's thousands of
        // matches are never sorted, only held against the last of these.
        var top: [(key: Int, index: Int)] = []
        top.reserveCapacity(limit + 1)
        let floor = weakest
        for index in candidates.indices {
            if index & 0x3FF == 0x3FF, isCancelled() { return nil }
            guard mask & ~candidates[index].mask == 0,
                  let score = work.score(self, in: candidates[index], tracing: false), score >= floor else { continue }
            // Score first, then the shorter name, then the shorter text;
            // earlier ones stay ahead of equals.
            let length = candidates[index].units.count, name = length - candidates[index].nameStart
            let key = score << 28 | (0xFFF - min(name, 0xFFF)) << 16 | (0xFFFF - min(length, 0xFFFF))
            if top.count == limit {
                guard key > top[limit - 1].key else { continue }
                top.removeLast()
            }
            var at = top.count
            while at > 0, top[at - 1].key < key { at -= 1 }
            top.insert((key, index), at: at)
        }
        // Where the letters are is worked out only for the rows that show.
        return top.map { entry in
            let score = work.score(self, in: candidates[entry.index], tracing: true) ?? 0
            return (entry.index, FuzzyMatch(score: score, ranges: work.ranges))
        }
    }
}

/// The matcher's arithmetic.
enum Fuzzy {
    static let slash: UInt16 = 0x2F

    /// A matched letter.
    static let letter = 16
    /// A letter right after the one matched before it is worth what the
    /// first letter of that run is (a run from the start of a word counts
    /// as the start of a word all along), and never less than this. Less
    /// than a word's start: "tc" is Toggle Comment before it is Matcha.
    static let consecutive = 5
    /// The first letter of the file's name in a path, or of the text.
    static let nameStartBonus = 12
    /// The first letter of a folder in a path.
    static let componentBonus = 9
    /// The first letter of a word ("Toggle Comment", "read_me", "a.swift").
    static let wordBonus = 8
    /// A capital inside a word ("EditorScreen").
    static let humpBonus = 6
    /// Any letter of the file's name in a path.
    static let nameBonus = 3
    /// Letters skipped between two matched ones: the first, and each more.
    static let gapOpen = 4
    static let gapExtend = 1

    /// Case folded away without changing the number of units, so offsets
    /// into the folded text are offsets into the original: ASCII, Latin 1,
    /// Latin Extended-A, Greek and Cyrillic capitals become their small
    /// letters. (Foundation's own lowercasing may change a string's length.)
    static func fold(_ u: UInt16) -> UInt16 {
        switch u {
        case 0x41...0x5A: return u + 0x20
        case 0xC0...0xD6, 0xD8...0xDE: return u + 0x20
        case 0x100...0x137, 0x14A...0x177: return u | 1
        case 0x139...0x148, 0x179...0x17E: return u & 1 == 1 ? u + 1 : u
        case 0x391...0x3A1, 0x3A3...0x3A9: return u + 0x20
        case 0x410...0x42F: return u + 0x20
        case 0x400...0x40F: return u + 0x50
        default: return u
        }
    }

    static func isUpper(_ u: UInt16) -> Bool { fold(u) != u }
    static func isLower(_ u: UInt16) -> Bool { u >= 0x61 && u <= 0x7A || u >= 0xDF && u != 0xF7 && !isUpper(u) }
    static func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
    static func isSpace(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 || u == 0xA0 }
    /// A letter or a digit: what words are made of.
    static func isWord(_ u: UInt16) -> Bool {
        isDigit(u) || u >= 0x41 && u <= 0x5A || u >= 0x61 && u <= 0x7A || u >= 0xC0 && u != 0xD7 && u != 0xF7
            && !(u >= 0x2000 && u <= 0x2BFF)
    }

    /// One of 64 bits for a folded unit: the ASCII letters and digits each
    /// have their own, everything else shares the rest.
    static func bit(_ u: UInt16) -> UInt64 {
        switch u {
        case 0x61...0x7A: return 1 << UInt64(u - 0x61)
        case 0x30...0x39: return 1 << UInt64(26 + u - 0x30)
        default: return 1 << UInt64(36 + u % 28)
        }
    }

    /// The tables one search works in, kept from candidate to candidate.
    ///
    /// For each letter of the query, at each place in the candidate where
    /// that letter stands, the best score of a match of the query so far
    /// that puts the letter there (`matched`), how many letters in a row
    /// that match ends with (`runs`), and where the letter before it then
    /// is (`back`, kept only when the match is to be marked). Only
    /// the places a letter can be are looked at: from where it is first
    /// possible (the letters before it found as early as they go) to
    /// where it is last possible.
    struct Work {
        private var matched: UnsafeMutablePointer<Int32>?
        private var runs: UnsafeMutablePointer<Int32>?
        private var back: UnsafeMutablePointer<Int32>?
        private var first: UnsafeMutablePointer<Int32>?
        private var last: UnsafeMutablePointer<Int32>?
        private var cells = 0
        private var letters = 0
        private(set) var ranges: [Range<Int>] = []

        private static let none = Int32.min / 2

        mutating func free() {
            matched?.deallocate()
            runs?.deallocate()
            back?.deallocate()
            first?.deallocate()
            last?.deallocate()
            matched = nil
            runs = nil
            back = nil
            first = nil
            last = nil
            cells = 0
            letters = 0
        }

        private mutating func reserve(cells wanted: Int, letters n: Int) {
            if wanted > cells {
                matched?.deallocate()
                runs?.deallocate()
                back?.deallocate()
                cells = max(wanted, cells * 2, 1024)
                matched = .allocate(capacity: cells)
                runs = .allocate(capacity: cells)
                back = .allocate(capacity: cells)
            }
            if n > letters {
                first?.deallocate()
                last?.deallocate()
                letters = max(n, FuzzyQuery.longest)
                first = .allocate(capacity: letters)
                last = .allocate(capacity: letters)
            }
        }

        /// The score of the best match, or nil for none. With `tracing`
        /// the whole table is kept and `ranges` says where the match is.
        mutating func score(_ query: FuzzyQuery, in candidate: FuzzyCandidate, tracing: Bool) -> Int? {
            let n = query.units.count, m = candidate.units.count
            if tracing { ranges = [] }
            guard n > 0 else { return 0 }
            guard n <= m, query.mask & ~candidate.mask == 0 else { return nil }
            reserve(cells: (tracing ? n : 2) * m, letters: n)
            guard let matched, let runs, let back, let first, let last else { return nil }
            let none = Self.none
            let letter = Int32(Fuzzy.letter), consecutive = Int32(Fuzzy.consecutive)
            let gapOpen = Int32(Fuzzy.gapOpen), gapExtend = Int32(Fuzzy.gapExtend)
            var best = none, bestAt = 0
            let found: Bool = query.units.withUnsafeBufferPointer { q in
                candidate.units.withUnsafeBufferPointer { c in
                    candidate.bonus.withUnsafeBufferPointer { bonus in
                        // Where each letter is first and last possible.
                        var j = 0
                        for i in 0..<n {
                            while j < m, c[j] != q[i] { j += 1 }
                            guard j < m else { return false }
                            first[i] = Int32(j)
                            j += 1
                        }
                        j = m - 1
                        for i in stride(from: n - 1, through: 0, by: -1) {
                            while c[j] != q[i] { j -= 1 }
                            last[i] = Int32(j)
                            j -= 1
                        }
                        for i in 0..<n {
                            let row = (tracing ? i : i & 1) * m, above = (tracing ? i - 1 : (i - 1) & 1) * m
                            let unit = q[i], to = Int(last[i])
                            var k = Int(first[i])
                            if i == 0 {
                                while k <= to {
                                    if c[k] == unit {
                                        let here = letter + Int32(bonus[k])
                                        matched[k] = here
                                        runs[k] = 1
                                        if n == 1, here > best {
                                            best = here
                                            bestAt = k
                                        }
                                    }
                                    k += 1
                                }
                                continue
                            }
                            // The letter before this one, wherever it can
                            // stand with letters skipped in between: a
                            // skipped stretch costs `gapOpen` and then
                            // `gapExtend` a letter, so of the places up to
                            // two back the best is the one with the most
                            // score plus `gapExtend` times its place.
                            let previous = q[i - 1], previousFrom = Int(first[i - 1]), previousTo = Int(last[i - 1])
                            var p = previousFrom, far = none, farAt = 0
                            while k <= to {
                                if c[k] == unit {
                                    while p <= k - 2, p <= previousTo {
                                        if c[p] == previous {
                                            let value = matched[above + p] + gapExtend * Int32(p)
                                            if value >= far {
                                                far = value
                                                farAt = p
                                            }
                                        }
                                        p += 1
                                    }
                                    let worth = letter + Int32(bonus[k])
                                    var here = none, from = 0, run: Int32 = 1
                                    if k - 1 >= previousFrom, k - 1 <= previousTo, c[k - 1] == previous {
                                        // In a row: worth what the run's first letter is.
                                        let before = runs[above + k - 1]
                                        let inherited = max(consecutive, Int32(bonus[k - Int(before)]), Int32(bonus[k]))
                                        here = matched[above + k - 1] + letter + inherited
                                        from = k - 1
                                        run = before + 1
                                    }
                                    if far > none {
                                        let skipping = far - gapOpen - gapExtend * Int32(k - 2) + worth
                                        if skipping > here {
                                            here = skipping
                                            from = farAt
                                            run = 1
                                        }
                                    }
                                    matched[row + k] = here
                                    runs[row + k] = run
                                    if tracing { back[row + k] = Int32(from) }
                                    if i == n - 1, here > best {
                                        best = here
                                        bestAt = k
                                    }
                                }
                                k += 1
                            }
                        }
                        return best > none
                    }
                }
            }
            guard found else { return nil }
            if tracing {
                // Back from the last letter's place to the first's.
                var places = [Int](repeating: 0, count: n)
                var k = bestAt
                for i in stride(from: n - 1, through: 0, by: -1) {
                    places[i] = k
                    if i > 0 { k = Int(back[i * m + k]) }
                }
                for place in places {
                    if let run = ranges.last, run.upperBound == place {
                        ranges[ranges.count - 1] = run.lowerBound..<(place + 1)
                    } else {
                        ranges.append(place..<(place + 1))
                    }
                }
            }
            return Int(best)
        }
    }
}

public extension FuzzyMatch {
    /// The ranges that fall in `part` of the candidate's text (a path's
    /// file name, say), as offsets from where the part begins.
    func ranges(in part: Range<Int>) -> [Range<Int>] {
        ranges.compactMap { range in
            let clamped = range.clamped(to: part)
            return clamped.isEmpty ? nil : (clamped.lowerBound - part.lowerBound)..<(clamped.upperBound - part.lowerBound)
        }
    }
}
