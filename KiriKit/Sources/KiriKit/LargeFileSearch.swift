import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Search over a `LargeFile`: the bytes are read a block at a time on every
// core and searched as they are, without a String in between. Plain text
// (the fast path) is a byte search; Match Case off folds ASCII letters only,
// so "error" finds "ERROR" but "ö" does not find "Ö". A regular expression
// runs a block at a time, and a match can't run across the seam between two
// blocks (they end at a line's end, so it can't run across lines then
// either, unless it reaches past a line on purpose).
//
// Offsets are byte offsets into the file.

/// One query, ready to run on a large file.
public struct LargeFileSearch: @unchecked Sendable {
    public let query: String
    public let options: SearchOptions
    private let needle: [UInt8]
    /// Where in the needle to look for first: its rarest byte.
    private let anchor: Int
    // Immutable once made, and safe to match with from any thread.
    private let regex: NSRegularExpression?

    /// The most matches a search keeps (it counts on past them).
    public static let defaultLimit = 1_000_000

    /// Throws for a regular expression that doesn't compile. An empty
    /// query is valid and finds nothing.
    public init(_ query: String, options: SearchOptions = SearchOptions()) throws(TextSearch.InvalidPattern) {
        self.query = query
        self.options = options
        if options.regularExpression && !query.isEmpty {
            var flags: NSRegularExpression.Options = [.anchorsMatchLines]
            if !options.matchCase { flags.insert(.caseInsensitive) }
            do { regex = try NSRegularExpression(pattern: query, options: flags) } catch {
                throw TextSearch.InvalidPattern(message: error.localizedDescription)
            }
            needle = []
            anchor = 0
        } else {
            regex = nil
            let bytes = Array(query.utf8)
            let folded = options.matchCase ? bytes : bytes.map(Self.lower)
            needle = folded
            anchor = folded.indices.min { Self.commonness(folded[$0]) < Self.commonness(folded[$1]) } ?? 0
        }
    }

    /// What a search found.
    public struct Result: Equatable, Sendable {
        /// The matches, in the order they stand in the file, at most the
        /// limit asked for.
        public var ranges: [Range<Int>] = []
        /// Where the line of each of `ranges` starts (a byte offset): for
        /// showing only the lines that match.
        public var lineStarts: [Int] = []
        /// How many matches there are in all.
        public var count = 0
        /// The search was stopped before the end.
        public var cancelled = false

        public var truncated: Bool { count > ranges.count }

        public init(ranges: [Range<Int>] = [], lineStarts: [Int] = [], count: Int = 0, cancelled: Bool = false) {
            self.ranges = ranges
            self.lineStarts = lineStarts
            self.count = count
            self.cancelled = cancelled
        }
    }

    /// Searches `range` of `file` (the whole of what has been read, unless
    /// told otherwise), on every core, a batch of blocks at a time.
    /// `progress` gets the result so far after each batch, with how far the
    /// search has got. Stops when `isCancelled` says yes.
    public func run(in file: LargeFile, range: Range<Int>? = nil, limit: Int = LargeFileSearch.defaultLimit,
                    isCancelled: @Sendable () -> Bool = { false },
                    progress: (Result, Int) -> Void = { _, _ in }) -> Result {
        var result = Result()
        guard !query.isEmpty else { return result }
        let whole = range ?? 0..<file.size
        guard !whole.isEmpty else { return result }
        let blocks = self.blocks(of: whole, in: file)
        let batch = max(1, ProcessInfo.processInfo.activeProcessorCount) * 2
        var b = 0
        while b < blocks.count {
            if isCancelled() { result.cancelled = true; return result }
            let these = Array(blocks[b..<min(b + batch, blocks.count)])
            var found = [([Range<Int>], [Int])](repeating: ([], []), count: these.count)
            var counts = [Int](repeating: 0, count: these.count)
            let room = max(0, limit - result.ranges.count)
            found.withUnsafeMutableBufferPointer { f in
                counts.withUnsafeMutableBufferPointer { c in
                    let f = UnsafeSendable(f), c = UnsafeSendable(c)
                    DispatchQueue.concurrentPerform(iterations: these.count) { i in
                        let (ranges, starts, n) = self.search(these[i], of: whole, in: file, keep: room)
                        f.value[i] = (ranges, starts)
                        c.value[i] = n
                    }
                }
            }
            for i in found.indices {
                result.count += counts[i]
                let room = limit - result.ranges.count
                if room > 0 {
                    result.ranges.append(contentsOf: found[i].0.prefix(room))
                    result.lineStarts.append(contentsOf: found[i].1.prefix(room))
                }
            }
            b += these.count
            progress(result, these.last!.upperBound)
        }
        return result
    }

    /// Where the blocks of `range` start and end. For a regular expression
    /// they end at a line's end.
    private func blocks(of range: Range<Int>, in file: LargeFile) -> [Range<Int>] {
        let size = LargeFile.blockSize
        guard regex != nil else {
            return stride(from: range.lowerBound, to: range.upperBound, by: size).map {
                $0..<min($0 + size, range.upperBound)
            }
        }
        var out: [Range<Int>] = []
        var start = range.lowerBound
        while start < range.upperBound {
            var end = min(start + size, range.upperBound)
            // On to the next "\n".
            while end < range.upperBound {
                let probe = file.read(end..<min(end + 64 << 10, range.upperBound))
                if probe.isEmpty { end = range.upperBound; break }
                if let nl = probe.firstIndex(of: 0x0A) { end += nl + 1; break }
                end += probe.count
            }
            out.append(start..<end)
            start = end
        }
        return out
    }

    /// The matches that start in `block`: those kept (at most `keep`) and
    /// how many there are.
    private func search(_ block: Range<Int>, of whole: Range<Int>, in file: LargeFile,
                        keep: Int) -> ([Range<Int>], [Int], Int) {
        // A plain match that starts in the block may end past it.
        let over = regex == nil ? max(0, needle.count - 1) : 0
        let span = block.lowerBound..<min(block.upperBound + over, whole.upperBound)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: span.count, alignment: 64)
        defer { buffer.deallocate() }
        let got = file.read(into: buffer, at: span.lowerBound)
        let bytes = UnsafeMutableBufferPointer(start: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: got)
        let (ranges, count): ([Range<Int>], Int)
        if let regex {
            (ranges, count) = matches(of: regex, in: UnsafeBufferPointer(bytes), at: block.lowerBound, keep: keep)
        } else {
            if !options.matchCase { Self.lowercase(bytes) }
            (ranges, count) = find(in: UnsafeBufferPointer(bytes), startsBefore: block.count, at: block.lowerBound, keep: keep)
        }
        return (ranges, Self.lineStarts(of: ranges, in: UnsafeBufferPointer(bytes), at: block.lowerBound, file: file), count)
    }

    /// Where the line of each of `ranges` starts, looked for back from
    /// each in `bytes` (which start at `base` in the file): back to the
    /// match before it, which is on the same line when no "\n" is between.
    static func lineStarts(of ranges: [Range<Int>], in bytes: UnsafeBufferPointer<UInt8>, at base: Int,
                           file: LargeFile) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(ranges.count)
        var previous = 0, previousStart: Int?
        for r in ranges {
            var i = r.lowerBound - base
            var start: Int?
            while i > previous {
                if bytes[i - 1] == 0x0A { start = base + i; break }
                i -= 1
            }
            if start == nil { start = previousStart }
            if start == nil {
                // The line began before these bytes.
                start = base == 0 ? 0 : file.lineStart(before: base)
            }
            out.append(start!)
            previousStart = start
            previous = r.lowerBound - base
        }
        return out
    }

    /// Where the needle is in `bytes`, for matches that start before
    /// `startsBefore`.
    private func find(in bytes: UnsafeBufferPointer<UInt8>, startsBefore limit: Int, at base: Int,
                      keep: Int) -> ([Range<Int>], Int) {
        var out: [Range<Int>] = []
        var count = 0
        let n = needle.count
        guard n > 0, bytes.count >= n, let start = bytes.baseAddress else { return (out, 0) }
        let a = anchor, key = needle[a]
        needle.withUnsafeBufferPointer { needle in
            let np = needle.baseAddress!
            // A match at i has `key` at i + a; i runs 0 ... last.
            let last = min(limit - 1, bytes.count - n)
            var i = 0
            while i <= last {
                guard let hit = memchr(start + i + a, Int32(key), last - i + 1) else { break }
                let at = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)) - start - a
                if memcmp(start + at, np, n) == 0 {
                    count += 1
                    if out.count < keep { out.append((base + at)..<(base + at + n)) }
                    i = at + n // matches don't overlap
                } else {
                    i = at + 1
                }
            }
        }
        return (out, count)
    }

    /// The matches of `regex` in `bytes`.
    private func matches(of regex: NSRegularExpression, in bytes: UnsafeBufferPointer<UInt8>, at base: Int,
                         keep: Int) -> ([Range<Int>], Int) {
        // UTF-8 when the bytes are (offsets map back exactly); otherwise
        // Latin 1, a character a byte, so they do too.
        var out: [Range<Int>] = []
        var count = 0
        if let text = String(validating: bytes, as: UTF8.self) {
            let utf8 = text.utf8
            // Matches come in order: each offset is found from the last one.
            var index = utf8.startIndex, offset = 0
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: text.utf16.count)) { m, _, _ in
                guard let m, m.range.length > 0, let r = Range(m.range, in: text) else { return }
                count += 1
                guard out.count < keep else { return }
                offset += utf8.distance(from: index, to: r.lowerBound)
                index = r.lowerBound
                let length = utf8.distance(from: r.lowerBound, to: r.upperBound)
                out.append((base + offset)..<(base + offset + length))
            }
        } else {
            let text = String(decoding: bytes.map { UInt16($0) }, as: UTF16.self)
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: text.utf16.count)) { m, _, _ in
                guard let m, m.range.length > 0 else { return }
                count += 1
                if out.count < keep { out.append((base + m.range.location)..<(base + m.range.location + m.range.length)) }
            }
        }
        return (out, count)
    }

    // MARK: Bytes

    static func lower(_ b: UInt8) -> UInt8 { b &- 0x41 < 26 ? b | 0x20 : b }

    /// ASCII letters in `bytes` made lowercase, 8 at a time.
    static func lowercase(_ bytes: UnsafeMutableBufferPointer<UInt8>) {
        guard let base = bytes.baseAddress else { return }
        let raw = UnsafeMutableRawPointer(base)
        let ones: UInt64 = 0x0101_0101_0101_0101, high: UInt64 = 0x8080_8080_8080_8080
        var i = 0
        while i + 8 <= bytes.count {
            let x = raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)
            let seven = x & ~high
            // The high bit of each byte that is "A" ... "Z" (and ASCII).
            let atLeastA = seven &+ ones &* (0x80 - 0x41)
            let pastZ = seven &+ ones &* (0x80 - 0x5B)
            let upper = (atLeastA ^ pastZ) & ~x & high
            if upper != 0 { raw.storeBytes(of: x | (upper >> 2), toByteOffset: i, as: UInt64.self) }
            i += 8
        }
        while i < bytes.count { bytes[i] = lower(bytes[i]); i += 1 }
    }

    /// How common a byte is in text, roughly: the search looks for the
    /// needle's least common byte first, so that it stops less often.
    static func commonness(_ b: UInt8) -> Int {
        switch b {
        case 0x20: 100
        case UInt8(ascii: "e"): 90
        case UInt8(ascii: "t"), UInt8(ascii: "a"), UInt8(ascii: "o"), UInt8(ascii: "i"), UInt8(ascii: "n"): 80
        case UInt8(ascii: "s"), UInt8(ascii: "r"), UInt8(ascii: "h"), UInt8(ascii: "l"): 70
        case UInt8(ascii: "0")...UInt8(ascii: "9"): 65
        case UInt8(ascii: "d"), UInt8(ascii: "c"), UInt8(ascii: "u"), UInt8(ascii: "m"): 60
        case UInt8(ascii: "a")...UInt8(ascii: "z"): 45
        case UInt8(ascii: "."), UInt8(ascii: ":"), UInt8(ascii: "-"), UInt8(ascii: "/"), UInt8(ascii: "\n"): 50
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): 30
        case UInt8(ascii: ","), UInt8(ascii: "_"), UInt8(ascii: "="), UInt8(ascii: "\""), UInt8(ascii: "["),
             UInt8(ascii: "]"), UInt8(ascii: "("), UInt8(ascii: ")"): 25
        default: b >= 0x80 ? 20 : 10
        }
    }
}
