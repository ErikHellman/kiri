import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// A text file too large for the editor (a log of many GB), read from disk as
// it is needed and never as a whole. Plain Foundation and POSIX so it tests
// on Linux too.
//
// The file is read with `pread`, never mapped: a log that is truncated or
// rotated while it is open makes a mapped page fault (SIGBUS) and the app
// would crash, where a read just comes back short.
//
// Lines are counted once, in the background and on every core, into a sparse
// index: where every few hundredth line starts. A line is found from the
// checkpoint before it by reading on to it, so the index of a file of 100
// million lines takes a few MB rather than the 800 MB one offset per line
// would. Offsets are byte offsets into the file; a line ends at "\n", and a
// "\r" before it is not shown.

/// A large text file, read-only, that may be read from any thread.
public final class LargeFile: @unchecked Sendable {
    /// Lines between checkpoints, at most (one more at the seam between
    /// two blocks counted apart).
    public static let checkpointSpacing = 256
    /// The bytes one block of the count reads, and one search worker.
    static let blockSize = 8 << 20
    /// A line longer than this shows only its start.
    public static let displayLimit = 10_000

    public let url: URL
    private let fd: Int32
    private let lock = NSLock()

    // Guarded by `lock`.
    /// Bytes counted so far: the index covers `0..<indexedLength`.
    private var indexed = 0
    /// Newlines in `0..<indexed`.
    private var newlines = 0
    /// Checkpoint i: line `checkLines[i]` starts at byte `checkOffsets[i]`.
    private var checkLines: [Int] = [0]
    private var checkOffsets: [Int] = [0]
    /// The file's size when it was last looked at.
    private var knownSize = 0

    /// Opens `url` for reading. Nothing is counted yet (`index`).
    public init(url: URL) throws {
        self.url = url
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]) }
        self.fd = fd
        knownSize = Self.size(of: fd)
    }

    deinit { close(fd) }

    private static func size(of fd: Int32) -> Int {
        var st = stat()
        return fstat(fd, &st) == 0 ? Int(st.st_size) : 0
    }

    /// The size of the file on disk now.
    public var currentSize: Int { Self.size(of: fd) }

    /// The file's size as last seen (when it opened, or by `index`).
    public var size: Int { lock.withLock { knownSize } }
    /// How much of the file the line count has covered.
    public var indexedLength: Int { lock.withLock { indexed } }
    /// Lines in the counted part: one more than its newlines (a file that
    /// ends in "\n" has an empty last line, as in the editor).
    public var lineCount: Int { lock.withLock { newlines + 1 } }
    /// The count has covered the whole file as last seen.
    public var isIndexed: Bool { lock.withLock { indexed >= knownSize } }

    // MARK: Reading

    /// The bytes of `range`, fewer when the file has become shorter.
    public func read(_ range: Range<Int>) -> [UInt8] {
        guard !range.isEmpty, range.lowerBound >= 0 else { return [] }
        var out = [UInt8](repeating: 0, count: range.count)
        let got = out.withUnsafeMutableBytes { read(into: $0, at: range.lowerBound) }
        if got < out.count { out.removeSubrange(got...) }
        return out
    }

    /// Fills `buffer` from `offset` on; how many bytes there were.
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: Int) -> Int {
        var done = 0
        while done < buffer.count {
            let n = pread(fd, buffer.baseAddress! + done, buffer.count - done, off_t(offset + done))
            if n > 0 { done += n } else if n < 0 && errno == EINTR { continue } else { break }
        }
        return done
    }

    // MARK: Counting lines

    /// What `index` reports as it goes.
    public struct Progress: Sendable {
        public let indexedLength: Int
        public let size: Int
        public let lineCount: Int
    }

    /// Counts the lines of the file from where the count has got to up to
    /// its size now, block by block on every core. Lines are usable as
    /// soon as each batch of blocks is in, and `progress` is told then.
    /// Returns false when `isCancelled` said yes. Called again on a file
    /// that has grown, it counts what was added.
    @discardableResult
    public func index(isCancelled: @Sendable () -> Bool = { false },
                      progress: (Progress) -> Void = { _ in }) -> Bool {
        let end = currentSize
        var start: Int = lock.withLock {
            if end > knownSize { knownSize = end }
            return indexed
        }
        let batch = max(1, ProcessInfo.processInfo.activeProcessorCount) * 2
        while start < end {
            if isCancelled() { return false }
            let blocks = stride(from: start, to: end, by: Self.blockSize).prefix(batch).map {
                $0..<min($0 + Self.blockSize, end)
            }
            var counts = [BlockCount?](repeating: nil, count: blocks.count)
            counts.withUnsafeMutableBufferPointer { out in
                let out = UnsafeSendable(out)
                DispatchQueue.concurrentPerform(iterations: blocks.count) { i in
                    out.value[i] = self.count(blocks[i])
                }
            }
            let reached = blocks.last!.upperBound
            let lines: Int = lock.withLock {
                for c in counts {
                    guard let c else { continue }
                    for (local, offset) in c.checkpoints {
                        checkLines.append(newlines + local)
                        checkOffsets.append(offset)
                    }
                    newlines += c.newlines
                }
                indexed = reached
                return newlines + 1
            }
            progress(Progress(indexedLength: reached, size: end, lineCount: lines))
            start = reached
        }
        return true
    }

    private struct BlockCount {
        var newlines = 0
        /// (lines in the block before it, offset) for each line that starts
        /// a checkpoint: after every `checkpointSpacing`th newline.
        var checkpoints: [(Int, Int)] = []
    }

    private func count(_ range: Range<Int>) -> BlockCount {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: range.count, alignment: 64)
        defer { buffer.deallocate() }
        let got = read(into: buffer, at: range.lowerBound)
        var result = BlockCount()
        let spacing = Self.checkpointSpacing
        var next = spacing // the newline count that makes the next checkpoint
        let base = range.lowerBound
        let bytes = UnsafeRawPointer(buffer.baseAddress!)
        var i = 0
        while i < got {
            // 8 bytes at a time, while no checkpoint falls inside them.
            if i + 8 <= got {
                let n = Self.newlines(in: bytes.loadUnaligned(fromByteOffset: i, as: UInt64.self))
                if result.newlines + n < next {
                    result.newlines += n
                    i += 8
                    continue
                }
            }
            if bytes.load(fromByteOffset: i, as: UInt8.self) == 0x0A {
                result.newlines += 1
                if result.newlines == next {
                    result.checkpoints.append((result.newlines, base + i + 1))
                    next += spacing
                }
            }
            i += 1
        }
        return result
    }

    /// How many of the 8 bytes in `word` are "\n".
    @inline(__always) static func newlines(in word: UInt64) -> Int {
        let low: UInt64 = 0x7F7F_7F7F_7F7F_7F7F
        let t = word ^ 0x0A0A_0A0A_0A0A_0A0A // a "\n" is a zero byte now
        // The high bit of each byte that is zero, exactly.
        let zero = ~(((t & low) &+ low) | t | low)
        return zero.nonzeroBitCount
    }

    // MARK: Lines

    /// The checkpoint at or before `line`.
    private func checkpoint(before line: Int) -> (line: Int, offset: Int) {
        lock.withLock {
            var lo = 0, hi = checkLines.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if checkLines[mid] <= line { lo = mid } else { hi = mid - 1 }
            }
            return (checkLines[lo], checkOffsets[lo])
        }
    }

    /// The checkpoint at or before byte `offset`.
    private func checkpoint(beforeOffset offset: Int) -> (line: Int, offset: Int) {
        lock.withLock {
            var lo = 0, hi = checkOffsets.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if checkOffsets[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return (checkLines[lo], checkOffsets[lo])
        }
    }

    /// The byte ranges of lines `lines` (0-based, clamped to the counted
    /// lines), each without its "\n" and a "\r" before it.
    public func lineRanges(_ lines: Range<Int>) -> [Range<Int>] {
        let (count, end) = lock.withLock { (newlines + 1, indexed) }
        let wanted = max(0, min(lines.lowerBound, count))..<max(0, min(lines.upperBound, count))
        guard !wanted.isEmpty else { return [] }
        var (line, offset) = checkpoint(before: wanted.lowerBound)
        var out: [Range<Int>] = []
        out.reserveCapacity(wanted.count)
        var lineStart = offset
        var lastByte: UInt8 = 0 // the byte before `offset`
        let chunk = 256 << 10
        // Reads on from the checkpoint, a chunk at a time, noting where
        // each line ends.
        while line < wanted.upperBound {
            if offset >= end {
                // The last line, which has no "\n".
                if line >= wanted.lowerBound {
                    let cr = offset > lineStart && lastByte == 0x0D
                    out.append(lineStart..<(cr ? end - 1 : end))
                }
                break
            }
            let bytes = read(offset..<min(offset + chunk, end))
            if bytes.isEmpty { break }
            bytes.withUnsafeBufferPointer { buf in
                let base = buf.baseAddress!
                var i = 0
                while line < wanted.upperBound, i < buf.count,
                      let hit = memchr(base + i, 0x0A, buf.count - i) {
                    let nl = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)) - base
                    if line >= wanted.lowerBound {
                        let before = nl > 0 ? buf[nl - 1] : lastByte
                        let lineEnd = offset + nl
                        let cr = lineEnd > lineStart && before == 0x0D
                        out.append(lineStart..<(cr ? lineEnd - 1 : lineEnd))
                    }
                    line += 1
                    lineStart = offset + nl + 1
                    i = nl + 1
                }
            }
            lastByte = bytes[bytes.count - 1]
            offset += bytes.count
        }
        return out
    }

    /// The text of lines `lines`, as `lineRanges` finds them: a line
    /// longer than `displayLimit` bytes is cut there. Bytes that aren't
    /// UTF-8 show as U+FFFD.
    public func lines(_ lines: Range<Int>) -> [String] { textLines(lines).map(\.text) }

    /// Lines `lines`: their bytes in the file and their text, as `lines`.
    public func textLines(_ lines: Range<Int>) -> [(bytes: Range<Int>, text: String)] {
        let ranges = lineRanges(lines)
        guard let first = ranges.first, let last = ranges.last else { return [] }
        // One read for them all, unless the lines are long: then what
        // shows of each, alone.
        let span = first.lowerBound..<last.upperBound
        guard span.count <= 4 << 20 else { return ranges.map { ($0, text(of: $0)) } }
        let bytes = read(span)
        return ranges.map { r in
            let lo = r.lowerBound - span.lowerBound
            let hi = min(r.upperBound, r.lowerBound + Self.displayLimit) - span.lowerBound
            guard lo >= 0, lo <= hi, hi <= bytes.count else { return (r, text(of: r)) }
            return (r, String(decoding: bytes[lo..<hi], as: UTF8.self))
        }
    }

    /// The text of the bytes `range`, cut at `displayLimit`.
    public func text(of range: Range<Int>, limit: Int = LargeFile.displayLimit) -> String {
        String(decoding: read(range.lowerBound..<min(range.upperBound, range.lowerBound + limit)), as: UTF8.self)
    }

    /// Where the line that byte `offset` is on starts: after the last "\n"
    /// before it, or 0.
    public func lineStart(before offset: Int) -> Int {
        var end = min(max(0, offset), size)
        let chunk = 16 << 10
        while end > 0 {
            let from = max(0, end - chunk)
            let bytes = read(from..<end)
            if bytes.isEmpty { return 0 }
            if let nl = bytes.lastIndex(of: 0x0A) { return from + nl + 1 }
            end = from
        }
        return 0
    }

    /// The line that starts at byte `start`: its bytes (without "\n" or a
    /// "\r" before it) and its text, cut at `displayLimit`.
    public func line(startingAt start: Int) -> (bytes: Range<Int>, text: String) {
        let end = indexedLength
        var at = start
        let chunk = 16 << 10
        var lineEnd = end
        while at < end {
            let bytes = read(at..<min(at + chunk, end))
            if bytes.isEmpty { break }
            if let nl = bytes.firstIndex(of: 0x0A) { lineEnd = at + nl; break }
            at += bytes.count
        }
        var range = start..<max(start, lineEnd)
        if !range.isEmpty, read((range.upperBound - 1)..<range.upperBound) == [0x0D] {
            range = range.lowerBound..<(range.upperBound - 1)
        }
        return (range, text(of: range))
    }

    /// The 0-based line that byte `offset` is on.
    public func line(containing offset: Int) -> Int {
        let end = indexedLength
        let target = min(max(offset, 0), end)
        var (line, at) = checkpoint(beforeOffset: target)
        let chunk = 256 << 10
        while at < target {
            let bytes = read(at..<min(at + chunk, target))
            if bytes.isEmpty { break }
            line += bytes.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            at += bytes.count
        }
        return line
    }

    // MARK: Changes on disk

    /// What happened to the file since it was last looked at.
    public enum Change: Equatable, Sendable {
        case none
        /// It grew: `index` counts the rest.
        case grew
        /// It is shorter than it was (truncated, or rotated in place):
        /// what was counted no longer holds, and the file is to be opened
        /// again.
        case shrank
    }

    /// Looks at the file's size now.
    public func checkSize() -> Change {
        let now = currentSize
        return lock.withLock {
            if now < knownSize || now < indexed { return .shrank }
            if now > knownSize { knownSize = now; return .grew }
            return .none
        }
    }
}

/// A value handed to concurrent work that writes only its own part of it.
struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
