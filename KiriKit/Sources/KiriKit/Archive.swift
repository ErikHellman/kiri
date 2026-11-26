import Foundation
#if canImport(Compression)
import Compression
#endif

// What a zip or tar archive holds, for the archive viewer: each file's
// path and uncompressed size, read without unpacking anything. A zip's
// list is at its end (the central directory), so only that is read; a tar
// is read through from the start, its files' contents skipped (a tar.gz
// is decompressed on the way, and what comes out is thrown away).

/// One file, folder or link in an archive.
public struct ArchiveEntry: Equatable, Sendable {
    /// Its path in the archive, "/"-separated ("src/main.swift").
    public var path: String
    /// How large it is unpacked, in bytes (0 for a folder or a link).
    public var size: Int64
    public var isDirectory: Bool
    public var isLink: Bool

    public init(path: String, size: Int64, isDirectory: Bool = false, isLink: Bool = false) {
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.isLink = isLink
    }
}

public enum ArchiveError: Error, Equatable, CustomStringConvertible {
    /// It isn't an archive of the kind its first bytes said.
    case notAnArchive
    /// Its list of files can't be read.
    case damaged(String)
    /// It is an archive, of a form Kiri doesn't read.
    case unsupported(String)

    public var description: String {
        switch self {
        case .notAnArchive: "It isn’t an archive Kiri can read."
        case .damaged(let why): "It looks damaged: \(why)."
        case .unsupported(let what): "Kiri doesn’t read \(what)."
        }
    }
}

/// What an archive holds, as read.
public struct ArchiveListing: Sendable {
    public var entries: [ArchiveEntry]
    /// The archive ended before its end-of-archive mark: a tar cut short
    /// (still being written, or not all downloaded). What came before it
    /// is listed.
    public var truncated: Bool

    public init(entries: [ArchiveEntry], truncated: Bool = false) {
        self.entries = entries
        self.truncated = truncated
    }
}

public enum ArchiveReader {
    /// Reads the list of what the archive at `url` holds. `progress` is
    /// told how much of the file has been read, 0 ... 1 (a tar's list
    /// takes reading all of it); `isCancelled` stops the reading.
    public static func listing(of url: URL, format: MediaKind.ArchiveFormat,
                               isCancelled: () -> Bool = { false },
                               progress: (Double) -> Void = { _ in }) throws -> ArchiveListing {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int64(try handle.seekToEnd())
        switch format {
        case .zip:
            let entries = try ZipDirectory.entries(size: size) { offset, count in
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: count) ?? Data()
            }
            return ArchiveListing(entries: entries)
        case .tar, .tarGzip:
            try handle.seek(toOffset: 0)
            var parser = TarParser()
            #if canImport(Compression)
            let gzip = format == .tarGzip ? GzipDecoder() : nil
            #else
            if format == .tarGzip { throw ArchiveError.unsupported("gzip here") }
            let gzip: Never? = nil
            #endif
            var read: Int64 = 0
            while !parser.isFinished, let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                if isCancelled() { throw CancellationError() }
                read += Int64(chunk.count)
                #if canImport(Compression)
                if let gzip {
                    try gzip.decode(chunk) { try parser.consume($0) }
                    if gzip.isFinished { break }
                } else {
                    try parser.consume(chunk)
                }
                #else
                _ = gzip
                try parser.consume(chunk)
                #endif
                progress(Double(read) / Double(max(1, size)))
            }
            if parser.entries.isEmpty, !parser.isFinished, !parser.isEmptySoFar { throw ArchiveError.notAnArchive }
            return ArchiveListing(entries: parser.entries, truncated: !parser.isFinished && !parser.isBetweenEntries)
        }
    }
}

// MARK: Little-endian and C fields

private extension Array where Element == UInt8 {
    func u16(_ i: Int) -> Int { Int(self[i]) | Int(self[i + 1]) << 8 }
    func u32(_ i: Int) -> Int64 { Int64(u16(i)) | Int64(u16(i + 2)) << 16 }
    func u64(_ i: Int) -> Int64 { Int64(bitPattern: UInt64(u32(i)) | UInt64(u32(i + 4)) << 32) }
    func matches(_ signature: [UInt8], at i: Int) -> Bool {
        i >= 0 && i + signature.count <= count && self[i..<i + signature.count].elementsEqual(signature)
    }
}

// MARK: Zip

/// A zip's central directory: the list at the end of the file of what it
/// holds, with each file's sizes (ZIP64 included, for archives and files
/// over 4 GB). Nothing is decompressed.
public enum ZipDirectory {
    private static let endSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    private static let end64Signature: [UInt8] = [0x50, 0x4B, 0x06, 0x06]
    private static let locator64Signature: [UInt8] = [0x50, 0x4B, 0x06, 0x07]
    private static let entrySignature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
    /// A directory larger than this (some 5 million files) isn't read.
    static let directoryLimit: Int64 = 512 << 20

    /// The entries of a zip of `size` bytes, read with `read(offset, count)`.
    public static func entries(size: Int64, read: (Int64, Int) throws -> Data) throws -> [ArchiveEntry] {
        // The end record is the last thing in the file, followed by a
        // comment of up to 64 KB.
        let tailLength = Int(min(size, 22 + 65_535))
        let tail = [UInt8](try read(size - Int64(tailLength), tailLength))
        var end = tail.count - 22
        while end >= 0, !tail.matches(endSignature, at: end) { end -= 1 }
        guard end >= 0 else { throw ArchiveError.notAnArchive }
        let endOffset = size - Int64(tailLength) + Int64(end)

        var count = Int64(tail.u16(end + 10))
        var directorySize = tail.u32(end + 12)
        var directoryOffset = tail.u32(end + 16)
        var zip64 = false
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF,
           tail.matches(locator64Signature, at: end - 20) {
            let recordOffset = tail.u64(end - 20 + 8)
            let record = [UInt8](try read(recordOffset, 56))
            guard record.count == 56, record.matches(end64Signature, at: 0) else { throw ArchiveError.damaged("its ZIP64 end record is missing") }
            count = record.u64(32)
            directorySize = record.u64(40)
            directoryOffset = record.u64(48)
            zip64 = true
        }
        guard count > 0 else { return [] }
        guard directorySize > 0, directorySize <= directoryLimit else {
            throw directorySize > directoryLimit ? ArchiveError.unsupported("a list of files this long")
                : ArchiveError.damaged("its list of files is empty")
        }
        // An archive with something before it (a self-extracting one) has
        // its offsets counted from where the zip starts.
        var start = directoryOffset
        if !zip64, start + directorySize != endOffset, endOffset - directorySize >= 0 { start = endOffset - directorySize }
        guard start >= 0, start + directorySize <= size else { throw ArchiveError.damaged("its list of files is out of place") }
        let directory = [UInt8](try read(start, Int(directorySize)))
        guard directory.matches(entrySignature, at: 0) else { throw ArchiveError.damaged("its list of files is out of place") }

        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(Int(min(count, 1 << 20)))
        var p = 0
        while p + 46 <= directory.count, directory.matches(entrySignature, at: p) {
            let madeBy = directory.u16(p + 4) >> 8
            let flags = directory.u16(p + 8)
            var compressed = directory.u32(p + 20)
            var size = directory.u32(p + 24)
            let nameLength = directory.u16(p + 28)
            let extraLength = directory.u16(p + 30)
            let commentLength = directory.u16(p + 32)
            let attributes = directory.u32(p + 38)
            let nameStart = p + 46
            guard nameStart + nameLength + extraLength <= directory.count else { break }
            let nameBytes = Array(directory[nameStart..<nameStart + nameLength])
            let name = flags & 0x800 != 0 ? String(decoding: nameBytes, as: UTF8.self)
                : String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? ""
            // ZIP64 sizes, for those the entry itself has as 0xFFFFFFFF.
            var e = nameStart + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let id = directory.u16(e), length = directory.u16(e + 2)
                guard e + 4 + length <= extraEnd else { break }
                if id == 0x0001 {
                    var f = e + 4
                    if size == 0xFFFF_FFFF, f + 8 <= e + 4 + length { size = directory.u64(f); f += 8 }
                    if compressed == 0xFFFF_FFFF, f + 8 <= e + 4 + length { compressed = directory.u64(f); f += 8 }
                }
                e += 4 + length
            }
            let mode = (attributes >> 16) & 0o170000
            let isUnix = madeBy == 3 || madeBy == 19
            let isDirectory = name.hasSuffix("/") || (isUnix && mode == 0o040000) || (madeBy == 0 && attributes & 0x10 != 0)
            let isLink = isUnix && mode == 0o120000
            entries.append(ArchiveEntry(path: name, size: isDirectory ? 0 : size, isDirectory: isDirectory, isLink: isLink))
            p = nameStart + nameLength + extraLength + commentLength
        }
        guard !entries.isEmpty else { throw ArchiveError.damaged("its list of files can’t be read") }
        return entries
    }
}

// MARK: Tar

/// A tar header's own check: the sum of its bytes.
public enum TarHeader {
    /// The 512-byte block `b` starts with is a tar header: its checksum
    /// field holds the sum of its bytes (counting the field as spaces).
    public static func checksumIsValid(_ b: [UInt8]) -> Bool {
        guard b.count >= 512 else { return false }
        var unsigned = 0, signed = 0
        for i in 0..<512 {
            let byte = (148..<156).contains(i) ? 0x20 : b[i]
            unsigned += Int(byte)
            signed += Int(Int8(bitPattern: byte))
        }
        guard let stored = number(b[148..<156]) else { return false }
        return stored == Int64(unsigned) || stored == Int64(signed)
    }

    /// A numeric field: octal digits (ending in a space or NUL), or a
    /// big-endian binary number when its first byte has the high bit
    /// set (GNU and star, for sizes over 8 GB).
    static func number(_ field: ArraySlice<UInt8>) -> Int64? {
        guard let first = field.first else { return nil }
        if first & 0x80 != 0 {
            var value: Int64 = Int64(first & 0x7F)
            for byte in field.dropFirst() {
                guard value < Int64.max >> 8 else { return nil }
                value = value << 8 | Int64(byte)
            }
            return value
        }
        var value: Int64 = 0
        var digits = 0
        for byte in field {
            if byte == 0x20 || byte == 0, digits == 0 { continue }
            guard (0x30...0x37).contains(byte) else { break }
            value = value * 8 + Int64(byte - 0x30)
            digits += 1
        }
        return digits > 0 || field.allSatisfy({ $0 == 0 || $0 == 0x20 }) ? value : nil
    }
}

/// Reads a tar as it comes, a chunk at a time: the headers, with the
/// contents between them skipped. Knows ustar, GNU (long names, sizes in
/// binary) and POSIX pax (long paths, sizes over 8 GB).
public struct TarParser: Sendable {
    public private(set) var entries: [ArchiveEntry] = []
    /// The end-of-archive mark (two empty blocks) has been read.
    public private(set) var isFinished = false
    /// Nothing but empty blocks so far (or nothing).
    public private(set) var isEmptySoFar = true

    private var block: [UInt8] = []
    /// Contents (and padding) still to skip.
    private var skip: Int64 = 0
    /// A long name or pax header being read: its type, what is left of
    /// it, what has been read, and the padding after it.
    private var collecting: (type: UInt8, remaining: Int, data: [UInt8], padding: Int)?
    private var longName: String?
    private var pax: [String: String] = [:]
    private var zeroBlocks = 0

    public init() {
        block.reserveCapacity(512)
    }

    /// Between files: what has been read ends where a file's header
    /// would start, so an archive that ends here lacks only its mark.
    public var isBetweenEntries: Bool { block.isEmpty && skip == 0 && collecting == nil }

    /// Reads the next bytes of the archive.
    public mutating func consume(_ data: Data) throws {
        var i = data.startIndex
        let end = data.endIndex
        while i < end, !isFinished {
            if skip > 0 {
                let take = Int(min(skip, Int64(end - i)))
                i += take
                skip -= Int64(take)
                continue
            }
            if var c = collecting {
                let take = min(c.remaining, end - i)
                c.data.append(contentsOf: data[i..<i + take])
                c.remaining -= take
                i += take
                if c.remaining == 0 {
                    collecting = nil
                    skip = Int64(c.padding)
                    collected(c.type, c.data)
                } else {
                    collecting = c
                }
                continue
            }
            let take = min(512 - block.count, end - i)
            block.append(contentsOf: data[i..<i + take])
            i += take
            if block.count == 512 {
                let header = block
                block.removeAll(keepingCapacity: true)
                try read(header)
            }
        }
    }

    private mutating func read(_ h: [UInt8]) throws {
        if h.allSatisfy({ $0 == 0 }) {
            zeroBlocks += 1
            if zeroBlocks >= 2 { isFinished = true }
            return
        }
        zeroBlocks = 0
        guard TarHeader.checksumIsValid(h) else {
            throw entries.isEmpty ? ArchiveError.notAnArchive : ArchiveError.damaged("a header in it is broken")
        }
        isEmptySoFar = false
        let type = h[156]
        let headerSize = TarHeader.number(h[124..<136]) ?? 0
        // pax gives the size when it is too large for the header.
        let size = pax["size"].flatMap { Int64($0) } ?? headerSize
        let padding = Int((512 - size % 512) % 512)
        switch type {
        case UInt8(ascii: "L"), UInt8(ascii: "K"), UInt8(ascii: "x"), UInt8(ascii: "g"):
            // A long name (GNU) or extended header (pax) for the next file.
            if size > 0, size <= 16 << 20 {
                collecting = (type, Int(size), [], padding)
            } else {
                skip = size + Int64(padding)
            }
            return
        default:
            break
        }
        let isUstar = h[257..<263].elementsEqual(Array("ustar\0".utf8))
        let name = Self.string(h[0..<100])
        let prefix = isUstar ? Self.string(h[345..<500]) : ""
        var path = pax["path"] ?? longName ?? (prefix.isEmpty ? name : prefix + "/" + name)
        if let sparse = pax["GNU.sparse.name"] { path = sparse }
        let isDirectory = type == UInt8(ascii: "5") || path.hasSuffix("/")
        let isLink = type == UInt8(ascii: "1") || type == UInt8(ascii: "2")
        // A sparse file's size unpacked.
        var shown = size
        if let real = pax["GNU.sparse.realsize"] ?? pax["GNU.sparse.size"], let value = Int64(real) {
            shown = value
        } else if type == UInt8(ascii: "S"), let real = TarHeader.number(h[483..<495]) {
            shown = real
        }
        entries.append(ArchiveEntry(path: path, size: isDirectory || isLink ? 0 : shown, isDirectory: isDirectory, isLink: isLink))
        longName = nil
        pax = [:]
        // A hard link, a folder or a device has no contents, whatever its size says.
        let hasContents = !(isDirectory || isLink || type == UInt8(ascii: "3") || type == UInt8(ascii: "4")
            || type == UInt8(ascii: "6"))
        skip = hasContents ? size + Int64(padding) : 0
    }

    private mutating func collected(_ type: UInt8, _ data: [UInt8]) {
        switch type {
        case UInt8(ascii: "L"):
            longName = Self.string(data[...])
        case UInt8(ascii: "x"):
            pax.merge(Self.paxRecords(data)) { _, new in new }
        default:
            // A long link target, or global pax settings: nothing listed.
            break
        }
    }

    /// pax records: "<length> <key>=<value>\n", one after another.
    static func paxRecords(_ data: [UInt8]) -> [String: String] {
        var records: [String: String] = [:]
        var i = 0
        while i < data.count {
            var j = i
            var length = 0
            while j < data.count, (0x30...0x39).contains(data[j]) {
                length = length * 10 + Int(data[j] - 0x30)
                j += 1
            }
            guard length > 0, j < data.count, data[j] == 0x20, i + length <= data.count else { break }
            var record = data[(j + 1)..<(i + length)]
            if record.last == 0x0A { record = record.dropLast() }
            if let equals = record.firstIndex(of: UInt8(ascii: "=")) {
                let key = String(decoding: record[record.startIndex..<equals], as: UTF8.self)
                records[key] = String(decoding: record[(equals + 1)...], as: UTF8.self)
            }
            i += length
        }
        return records
    }

    /// A NUL-terminated field.
    private static func string(_ field: ArraySlice<UInt8>) -> String {
        let bytes = field.prefix { $0 != 0 }
        return String(bytes: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: Gzip

#if canImport(Compression)
/// Decompresses gzip as it comes, a chunk at a time: the header, then the
/// DEFLATE stream (with the Compression framework), member after member.
public final class GzipDecoder {
    private enum State {
        /// Reading a member's header; `pending` holds what came of it.
        case header
        case body
        /// Skipping a member's 8-byte trailer (its CRC and length).
        case trailer(Int)
        case finished
    }

    private var state = State.header
    private var pending: [UInt8] = []
    private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    private var streamOpen = false
    private let output = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 18)
    private let outputSize = 1 << 18

    public init() {}

    deinit {
        if streamOpen { compression_stream_destroy(stream) }
        stream.deallocate()
        output.deallocate()
    }

    /// The last member has ended (and something that isn't gzip followed,
    /// or nothing).
    public var isFinished: Bool { if case .finished = state { true } else { false } }

    /// Decompresses the next bytes, handing what they come to to `sink`.
    public func decode(_ data: Data, sink: (Data) throws -> Void) throws {
        var bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            switch state {
            case .finished:
                return
            case .trailer(let left):
                let take = min(left, bytes.count - i)
                i += take
                state = left - take == 0 ? .header : .trailer(left - take)
            case .header:
                pending.append(contentsOf: bytes[i...])
                i = bytes.count
                guard let length = try Self.headerLength(pending) else { continue }
                // Not gzip after a member: the end (trailing zeros, say).
                if length < 0 {
                    state = .finished
                    return
                }
                guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                    throw ArchiveError.damaged("it can’t be decompressed")
                }
                streamOpen = true
                state = .body
                bytes = Array(pending[length...])
                pending = []
                i = 0
            case .body:
                let used = try inflate(bytes, from: i, sink: sink)
                i += used
            }
        }
    }

    /// Runs the DEFLATE stream over `bytes[from...]`; how many it took.
    private func inflate(_ bytes: [UInt8], from start: Int, sink: (Data) throws -> Void) throws -> Int {
        try bytes.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!.advanced(by: start)
            let count = buffer.count - start
            stream.pointee.src_ptr = UnsafePointer(base)
            stream.pointee.src_size = count
            while true {
                let before = stream.pointee.src_size
                stream.pointee.dst_ptr = output
                stream.pointee.dst_size = outputSize
                let status = compression_stream_process(stream, 0)
                let produced = outputSize - stream.pointee.dst_size
                let left = stream.pointee.src_size
                if produced > 0 { try sink(Data(bytes: output, count: produced)) }
                switch status {
                case COMPRESSION_STATUS_END:
                    compression_stream_destroy(stream)
                    streamOpen = false
                    state = .trailer(8)
                    return count - left
                case COMPRESSION_STATUS_OK:
                    // All taken, and nothing more to give until more comes.
                    if left == 0, produced < outputSize { return count }
                    // (No progress at all: wait for more input.)
                    if produced == 0, left == before { return count - left }
                default:
                    throw ArchiveError.damaged("its compressed data is broken")
                }
            }
        }
    }

    /// The length of the gzip header `b` starts with; nil if more bytes
    /// are needed, -1 if it isn't gzip.
    static func headerLength(_ b: [UInt8]) throws -> Int? {
        guard b.count >= 10 else { return b.count >= 2 && !(b[0] == 0x1F && b[1] == 0x8B) ? -1 : nil }
        guard b[0] == 0x1F, b[1] == 0x8B else { return -1 }
        guard b[2] == 8 else { throw ArchiveError.unsupported("this kind of gzip compression") }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard i + 2 <= b.count else { return nil }
            i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8)
        }
        if flags & 0x08 != 0 { // FNAME
            guard let zero = b[min(i, b.count)...].firstIndex(of: 0) else { return nil }
            i = zero + 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            guard let zero = b[min(i, b.count)...].firstIndex(of: 0) else { return nil }
            i = zero + 1
        }
        if flags & 0x02 != 0 { i += 2 } // FHCRC
        return i <= b.count ? i : nil
    }
}
#endif

// MARK: The tree

/// An archive's entries as folders and files, each folder with the size
/// and number of files of everything in it, for the viewer's outline.
public struct ArchiveTree: Sendable {
    public struct Node: Sendable, Identifiable {
        public let id: Int
        public let name: String
        public let path: String
        /// Unpacked; for a folder, of everything in it.
        public let size: Int64
        public let isDirectory: Bool
        public let isLink: Bool
        /// For a folder, the files in it at any depth; 1 for a file.
        public let fileCount: Int
        /// Folders first, then files, by name.
        public let children: [Node]
    }

    /// The archive itself: its children are what is at its top.
    public let root: Node
    /// The ids of all folders (Expand All).
    public let folderIDs: Set<Int>

    public var totalSize: Int64 { root.size }
    public var fileCount: Int { root.fileCount }

    public init(entries: [ArchiveEntry]) {
        let top = Builder(name: "", path: "", isDirectory: true)
        for entry in entries {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
            guard !parts.isEmpty else { continue }
            var node = top
            for (index, part) in parts.enumerated() {
                let name = String(part)
                let last = index == parts.count - 1
                let isDirectory = !last || entry.isDirectory
                if let existing = node.children[name] {
                    // The same path again (a tar can hold a file twice): the later one counts.
                    if last, !isDirectory, !existing.isDirectory {
                        existing.size = entry.size
                        existing.isLink = entry.isLink
                    }
                    node = existing
                } else {
                    let child = Builder(name: name, path: parts[...index].joined(separator: "/"), isDirectory: isDirectory)
                    if last, !isDirectory {
                        child.size = entry.size
                        child.isLink = entry.isLink
                    }
                    node.children[name] = child
                    node = child
                }
            }
        }
        var next = 0
        var folders = Set<Int>()
        root = top.freeze(next: &next, folders: &folders)
        folders.remove(root.id)
        folderIDs = folders
    }

    /// A row of the outline: a node, and how deep it is (0 at the top).
    public struct Row: Sendable, Identifiable {
        public let node: Node
        public let depth: Int
        public var id: Int { node.id }
    }

    /// The rows that show with the folders in `expanded` open.
    public func rows(expanded: Set<Int>) -> [Row] {
        var rows: [Row] = []
        func walk(_ nodes: [Node], depth: Int) {
            for node in nodes {
                rows.append(Row(node: node, depth: depth))
                if node.isDirectory, expanded.contains(node.id) { walk(node.children, depth: depth + 1) }
            }
        }
        walk(root.children, depth: 0)
        return rows
    }

    /// What opens at first: an archive of one folder (as most are) opens it.
    public var initiallyExpanded: Set<Int> {
        var open = Set<Int>()
        var nodes = root.children
        while nodes.count == 1, let only = nodes.first, only.isDirectory {
            open.insert(only.id)
            nodes = only.children
        }
        return open
    }

    private final class Builder {
        let name: String
        let path: String
        let isDirectory: Bool
        var isLink = false
        var size: Int64 = 0
        var children: [String: Builder] = [:]

        init(name: String, path: String, isDirectory: Bool) {
            self.name = name
            self.path = path
            self.isDirectory = isDirectory
        }

        func freeze(next: inout Int, folders: inout Set<Int>) -> Node {
            let id = next
            next += 1
            if isDirectory { folders.insert(id) }
            let sorted = children.values.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.compare(b.name, options: [.caseInsensitive, .numeric]) == .orderedAscending
            }
            let frozen = sorted.map { $0.freeze(next: &next, folders: &folders) }
            let total = isDirectory ? frozen.reduce(0) { $0 + $1.size } : size
            let files = isDirectory ? frozen.reduce(0) { $0 + $1.fileCount } : 1
            return Node(id: id, name: name, path: path, size: total, isDirectory: isDirectory, isLink: isLink,
                        fileCount: files, children: frozen)
        }
    }
}
