import Foundation

/// Where the person was in a file when they last had it open: the
/// selection (or the caret, an empty one) and the line at the top of the
/// editor. A file that opens again comes back there.
///
/// Kept as lines and columns (UTF-16 units into the line), not offsets
/// into the text: a file changed elsewhere in the meantime keeps its
/// place at least up to the change. And the scroll is the line at the top,
/// with how far into it, not points: the same place whatever the font,
/// the window's width and line wrapping.
public struct FilePosition: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        /// 0-based.
        public var line: Int
        /// UTF-16 units from the start of the line.
        public var column: Int

        public init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }
    }

    /// The selection: where it starts and where it ends (the same for a caret).
    public var start: Point
    public var end: Point
    /// The line at the top of the editor (0-based) and how far it is
    /// scrolled into it, in points. Line 0 and 0 points is the head of the
    /// file, with the room above its first line.
    public var topLine: Int
    public var topDelta: Double
    /// How far the editor is scrolled sideways (only without wrapping).
    public var scrollX: Double

    public init(start: Point, end: Point, topLine: Int = 0, topDelta: Double = 0, scrollX: Double = 0) {
        self.start = start
        self.end = end
        self.topLine = topLine
        self.topDelta = topDelta
        self.scrollX = scrollX
    }

    /// The position of `selection` (UTF-16 offsets) with `topLine` at the top.
    public init(selection: Range<Int>, topLine: Int, topDelta: Double = 0, scrollX: Double = 0, in index: LineIndex) {
        func point(_ offset: Int) -> Point {
            let offset = min(max(offset, 0), index.length)
            let line = index.line(at: offset)
            return Point(line: line, column: offset - index.starts[line])
        }
        self.init(start: point(selection.lowerBound), end: point(selection.upperBound),
                  topLine: min(max(topLine, 0), index.lineCount - 1), topDelta: topDelta, scrollX: scrollX)
    }

    /// The head of the file: the caret before the first character, nothing scrolled.
    public static let top = FilePosition(start: Point(line: 0, column: 0), end: Point(line: 0, column: 0))

    public var isTop: Bool { self == .top }

    /// The head of the file shows: nothing scrolled down or sideways.
    public var scrolledToTop: Bool { topLine == 0 && topDelta <= 0 && scrollX <= 0 }

    /// The UTF-16 offset of `point` in the text `index` is of, kept inside
    /// it: past the last line is the end of the text, past a line's end the
    /// end of that line.
    public static func offset(of point: Point, in index: LineIndex) -> Int {
        let line = min(max(point.line, 0), index.lineCount - 1)
        let range = index.range(ofLine: line)
        if point.line >= index.lineCount { return index.length }
        return min(range.lowerBound + max(0, point.column), range.upperBound)
    }

    /// The selection in the text `index` is of.
    public func selection(in index: LineIndex) -> Range<Int> {
        let a = Self.offset(of: start, in: index)
        let b = Self.offset(of: end, in: index)
        return min(a, b)..<max(a, b)
    }

    /// Where the line at the top starts in the text `index` is of.
    public func topOffset(in index: LineIndex) -> Int {
        index.starts[min(max(topLine, 0), index.lineCount - 1)]
    }
}

/// The positions of the files opened lately, by path, for the next time
/// each opens (also after a relaunch). Only so many are kept: the ones
/// used longest ago go first.
public struct FilePositionStore: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var position: FilePosition
        /// When it was last set, as a count that only goes up.
        var stamp: Int
    }

    public static let defaultLimit = 500

    private var entries: [String: Entry] = [:]
    private var clock = 0
    public var limit: Int

    public init(limit: Int = FilePositionStore.defaultLimit) {
        self.limit = limit
    }

    public var count: Int { entries.count }

    public func position(for path: String) -> FilePosition? { entries[path]?.position }

    /// Keeps `position` for `path`, as the latest used; the head of the
    /// file needs no keeping, so that forgets it. True if what is kept for
    /// `path` changed.
    @discardableResult
    public mutating func set(_ position: FilePosition, for path: String) -> Bool {
        let old = entries[path]?.position
        if position.isTop {
            entries[path] = nil
            return old != nil
        }
        clock += 1
        entries[path] = Entry(position: position, stamp: clock)
        if entries.count > limit {
            let oldest = entries.sorted { $0.value.stamp < $1.value.stamp }.prefix(entries.count - limit)
            for (path, _) in oldest { entries[path] = nil }
        }
        return old != position
    }

    public mutating func remove(_ path: String) { entries[path] = nil }

    /// As saved between launches.
    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    /// What `encoded` saved; empty if it can't be read.
    public static func decoded(_ data: Data?, limit: Int = FilePositionStore.defaultLimit) -> FilePositionStore {
        guard let data, var store = try? JSONDecoder().decode(FilePositionStore.self, from: data) else {
            return FilePositionStore(limit: limit)
        }
        store.limit = limit
        return store
    }
}
