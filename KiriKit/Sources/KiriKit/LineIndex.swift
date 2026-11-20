import Foundation

/// Where every line starts in a text, as UTF-16 offsets (the unit NSString and
/// NSTextView use). Kept up to date edit by edit, so the gutter and the status
/// bar can map offsets to line numbers in O(log n) on large files.
public struct LineIndex: Equatable, Sendable {
    /// UTF-16 offset of the first character of each line. Always starts with 0.
    public private(set) var starts: [Int] = [0]
    /// Total UTF-16 length of the text.
    public private(set) var length = 0

    public init() {}

    public init(_ text: String) {
        self.init()
        replace(range: 0..<0, with: text)
    }

    public var lineCount: Int { starts.count }

    /// The 0-based line containing `offset` (offsets past the end clamp to the last line).
    public func line(at offset: Int) -> Int {
        // Last start <= offset.
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// UTF-16 range of `line` without its trailing "\n".
    public func range(ofLine line: Int) -> Range<Int> {
        let start = starts[line]
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : length
        return start..<end
    }

    /// Applies an edit: the UTF-16 `range` of the old text was replaced by `text`.
    public mutating func replace(range: Range<Int>, with text: String) {
        precondition(range.lowerBound >= 0 && range.upperBound <= length, "edit outside the text")
        let inserted = text.utf16.count
        let delta = inserted - range.count
        // Lines that start inside the replaced range (after its first character) go away.
        let first = line(at: range.lowerBound) + 1
        var last = first
        while last < starts.count, starts[last] <= range.upperBound { last += 1 }
        var newStarts: [Int] = []
        var offset = range.lowerBound
        for u in text.utf16 {
            offset += 1
            if u == 0x0A { newStarts.append(offset) }
        }
        starts.replaceSubrange(first..<last, with: newStarts)
        if delta != 0 {
            for i in (first + newStarts.count)..<starts.count { starts[i] += delta }
        }
        length += delta
    }
}
