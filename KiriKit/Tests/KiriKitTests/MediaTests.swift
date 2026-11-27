import Foundation
import Testing
@testable import KiriKit

/// `MediaKind`: which files open in a viewer, from their first bytes.
@Suite struct MediaKindTests {
    func bytes(_ values: [UInt8], padTo length: Int = 64) -> Data {
        Data(values + [UInt8](repeating: 0, count: max(0, length - values.count)))
    }

    func ascii(_ s: String, at offset: Int = 0, padTo length: Int = 64) -> Data {
        var b = [UInt8](repeating: 0, count: max(length, offset + s.utf8.count))
        b.replaceSubrange(offset..<offset + s.utf8.count, with: Array(s.utf8))
        return Data(b)
    }

    @Test func picturesByTheirFirstBytes() {
        #expect(MediaKind.detect(fileName: "a.png", head: bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == .image("PNG"))
        // Whatever it is called.
        #expect(MediaKind.detect(fileName: "photo", head: bytes([0xFF, 0xD8, 0xFF, 0xE0])) == .image("JPEG"))
        #expect(MediaKind.detect(fileName: "x.gif", head: ascii("GIF89a")) == .image("GIF"))
        var webp = ascii("RIFF")
        webp.replaceSubrange(8..<12, with: Array("WEBP".utf8))
        #expect(MediaKind.detect(fileName: "x.webp", head: webp) == .image("WebP"))
        #expect(MediaKind.detect(fileName: "x.tiff", head: bytes([0x49, 0x49, 0x2A, 0x00])) == .image("TIFF"))
        #expect(MediaKind.detect(fileName: "x.nef", head: bytes([0x4D, 0x4D, 0x00, 0x2A])) == .image("NEF"))
        #expect(MediaKind.detect(fileName: "x.bmp", head: ascii("BM")) == .image("BMP"))
    }

    @Test func animatedPNGHasAnAnimationChunk() {
        func png(_ chunks: [String]) -> Data {
            var b: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            for chunk in chunks {
                let data: [UInt8] = chunk == "IHDR" ? [UInt8](repeating: 1, count: 13) : [0, 0, 0, 1, 0, 0, 0, 0]
                b += [0, 0, 0, UInt8(data.count)] + Array(chunk.utf8) + data + [0, 0, 0, 0]
            }
            return Data(b)
        }
        #expect(MediaKind.detect(fileName: "a.png", head: png(["IHDR", "acTL", "IDAT"])) == .image("APNG"))
        #expect(MediaKind.detect(fileName: "a.png", head: png(["IHDR", "IDAT", "acTL"])) == .image("PNG"))
    }

    @Test func isoMediaByItsBrands() {
        func ftyp(_ major: String, _ compatible: [String] = []) -> Data {
            let size = 16 + 4 * compatible.count
            var b: [UInt8] = [0, 0, 0, UInt8(size)] + Array("ftyp".utf8) + Array(major.utf8) + [0, 0, 0, 0]
            for brand in compatible { b += Array(brand.utf8) }
            return Data(b + [UInt8](repeating: 0, count: 32))
        }
        #expect(MediaKind.detect(fileName: "a.heic", head: ftyp("heic", ["mif1", "heic"])) == .image("HEIC"))
        #expect(MediaKind.detect(fileName: "a.avif", head: ftyp("avif", ["mif1", "avif"])) == .image("AVIF"))
        #expect(MediaKind.detect(fileName: "a.mp4", head: ftyp("isom", ["isom", "mp41"])) == .video("MPEG-4"))
        #expect(MediaKind.detect(fileName: "a.mov", head: ftyp("qt  ", ["qt  "])) == .video("QuickTime"))
        #expect(MediaKind.detect(fileName: "a.m4a", head: ftyp("M4A ", ["M4A "])) == .video("MPEG-4 Audio"))
    }

    @Test func mpegAndQuickTime() {
        #expect(MediaKind.detect(fileName: "a.mpg", head: bytes([0x00, 0x00, 0x01, 0xBA])) == .video("MPEG"))
        #expect(MediaKind.detect(fileName: "a.m2v", head: bytes([0x00, 0x00, 0x01, 0xB3])) == .video("MPEG"))
        #expect(MediaKind.detect(fileName: "old.mov", head: ascii("moov", at: 4)) == .video("QuickTime"))
        var ts = [UInt8](repeating: 0xFF, count: 512)
        ts[0] = 0x47; ts[188] = 0x47; ts[376] = 0x47
        #expect(MediaKind.detect(fileName: "a.ts", head: Data(ts)) == .video("MPEG-TS"))
    }

    @Test func archives() {
        #expect(MediaKind.detect(fileName: "a.zip", head: bytes([0x50, 0x4B, 0x03, 0x04])) == .archive(.zip))
        #expect(MediaKind.detect(fileName: "lib.jar", head: bytes([0x50, 0x4B, 0x03, 0x04])) == .archive(.zip))
        #expect(MediaKind.detect(fileName: "a.tar.gz", head: bytes([0x1F, 0x8B, 0x08])) == .archive(.tarGzip))
        #expect(MediaKind.detect(fileName: "a.tgz", head: bytes([0x1F, 0x8B, 0x08])) == .archive(.tarGzip))
        // A gzipped file that isn't called a tar is not listed.
        #expect(MediaKind.detect(fileName: "app.log.gz", head: bytes([0x1F, 0x8B, 0x08])) == nil)
        #expect(MediaKind.detect(fileName: "a.tar", head: ascii("ustar", at: 257, padTo: 512)) == .archive(.tar))
    }

    @Test func textIsNeverMedia() {
        #expect(MediaKind.detect(fileName: "logo.svg", head: Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)) == nil)
        // A TypeScript file is not a transport stream, nor a text file called .png a picture.
        #expect(MediaKind.detect(fileName: "main.ts", head: Data("export const x = 1\n".utf8)) == nil)
        #expect(MediaKind.detect(fileName: "notes.png", head: Data("just text".utf8)) == nil)
        #expect(MediaKind.detect(fileName: "empty.png", head: Data()) == nil)
        #expect(MediaKind.detect(fileName: "a.bin", head: bytes([0x00, 0x01, 0x02])) == nil)
    }

    @Test func namesDecideForBinaryFilesWithoutAMark() {
        #expect(MediaKind.detect(fileName: "x.tga", head: bytes([0x00, 0x00, 0x02])) == .image("TGA"))
        #expect(MediaKind.detect(fileName: "x.mp4", head: bytes([0x00, 0x00, 0x00])) == .video("MPEG-4"))
    }

    @Test func statusTexts() {
        #expect(MediaText.duration(7.2) == "0:07")
        #expect(MediaText.duration(151) == "2:31")
        #expect(MediaText.duration(3723) == "1:02:03")
        #expect(MediaText.duration(.nan).isEmpty)
        #expect(MediaText.dimensions(1920, 1080) == "1920 × 1080")
        #expect(MediaText.files(1) == "1 file" && MediaText.files(3) == "3 files")
    }

    @Test func sidebarIcons() {
        #expect(FileIcon.forFile(named: "shot.PNG") == FileIcon.image)
        #expect(FileIcon.forFile(named: "clip.mov") == FileIcon.video)
        #expect(FileIcon.forFile(named: "src.tar.gz") == FileIcon.archive)
        #expect(FileIcon.forFile(named: "lib.jar") == FileIcon.archive)
        // TypeScript keeps its own.
        #expect(FileIcon.forFile(named: "main.ts") == FileIcon.of(.typescript))
        #expect(FileIcon.tints.contains(FileIcon.image.tint!) && FileIcon.tints.contains(FileIcon.video.tint!)
                && FileIcon.tints.contains(FileIcon.archive.tint!))
    }
}

/// `ArchiveReader`, `TarParser`, `ZipDirectory` and `ArchiveTree`.
@Suite final class ArchiveTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kiri-archive-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: folder) }

    func write(_ data: Data, _ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Made with Python's zipfile: a folder entry, deflated files, a
    /// UTF-8 name and a comment after the end record.
    static let zip = Data(base64Encoded: """
        UEsDBBQAAAAIAFw4el0AAAAAAgAAAAAAAAAIAAAAcHJvamVjdC8DAFBLAwQUAAAACABcOHpdvv0aZgwAAAD0AQAAEQAAAHByb2plY3QvUkVBRE1FLm1kU1bwyORSHiVGEgEAUEsDBBQAAAAIAFw4el18h5YpEQAAAA8AAAAWAAAAcHJvamVjdC9zcmMvbWFpbi5zd2lmdCsoyswr0VDKSM3JyVfS5AIAUEsDBBQAAAgIAFw4el3myUE7CwAAAOgDAAAZAAAAcHJvamVjdC9zcmMvw5xuw69jb2RlLnR4dKuoGAWjYBQMdwAAUEsBAhQDFAAAAAgAXDh6XQAAAAACAAAAAAAAAAgAAAAAAAAAAAAQAP1BAAAAAHByb2plY3QvUEsBAhQDFAAAAAgAXDh6Xb79GmYMAAAA9AEAABEAAAAAAAAAAAAAAIABKAAAAHByb2plY3QvUkVBRE1FLm1kUEsBAhQDFAAAAAgAXDh6XXyHlikRAAAADwAAABYAAAAAAAAAAAAAAIABYwAAAHByb2plY3Qvc3JjL21haW4uc3dpZnRQSwECFAMUAAAICABcOHpd5slBOwsAAADoAwAAGQAAAAAAAAAAAAAAgAGoAAAAcHJvamVjdC9zcmMvw5xuw69jb2RlLnR4dFBLBQYAAAAABAAEAAABAADqAAAACQBhIGNvbW1lbnQ=
        """, options: .ignoreUnknownCharacters)!

    @Test func zipListsItsDirectory() throws {
        let url = try write(Self.zip, "a.zip")
        let listing = try ArchiveReader.listing(of: url, format: .zip)
        #expect(!listing.truncated)
        #expect(listing.entries == [
            ArchiveEntry(path: "project/", size: 0, isDirectory: true),
            ArchiveEntry(path: "project/README.md", size: 500),
            ArchiveEntry(path: "project/src/main.swift", size: 15),
            ArchiveEntry(path: "project/src/Ünïcode.txt", size: 1000),
        ])
    }

    @Test func zipWithSomethingBeforeIt() throws {
        // A self-extracting archive: a program, then the zip.
        let url = try write(Data(repeating: 0x7F, count: 1000) + Self.zip, "sfx.zip")
        #expect(try ArchiveReader.listing(of: url, format: .zip).entries.count == 4)
    }

    @Test func notAZip() throws {
        let url = try write(Data("PK\u{3}\u{4} but nothing else".utf8), "bad.zip")
        #expect(throws: ArchiveError.notAnArchive) { try ArchiveReader.listing(of: url, format: .zip) }
    }

    // MARK: Tar, made here

    /// A tar header block for `name`.
    /// `sizeField` replaces the octal size with those 12 bytes.
    static func header(_ name: String, size: Int, type: Character = "0", ustar: Bool = true,
                       sizeField: [UInt8]? = nil) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, _ at: Int) { h.replaceSubrange(at..<at + s.utf8.count, with: Array(s.utf8)) }
        put(name, 0)
        put("0000644", 100)
        if let sizeField { h.replaceSubrange(124..<136, with: sizeField) } else { put(String(format: "%011o", size), 124) }
        put("00000000000", 136)
        h[156] = type.asciiValue!
        if ustar { put("ustar", 257); put("00", 263) }
        put("        ", 148)
        let sum = h.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum) + "\0 ", 148)
        return h
    }

    static func file(_ name: String, _ contents: [UInt8], type: Character = "0") -> [UInt8] {
        let padding = (512 - contents.count % 512) % 512
        return header(name, size: contents.count, type: type) + contents + [UInt8](repeating: 0, count: padding)
    }

    static let end = [UInt8](repeating: 0, count: 1024)

    @Test func tarListsFilesAndFolders() throws {
        let tar = Self.file("top/", [], type: "5") + Self.file("top/a.txt", [UInt8](repeating: 0x61, count: 700))
            + Self.file("top/b", [UInt8](repeating: 0x62, count: 512)) + Self.file("top/link", [], type: "2") + Self.end
        var parser = TarParser()
        // In pieces of every size, as a stream gives them.
        var rest = tar[...]
        var piece = 1
        while !rest.isEmpty {
            try parser.consume(Data(rest.prefix(piece)))
            rest = rest.dropFirst(piece)
            piece = piece * 3 + 1
        }
        #expect(parser.isFinished)
        #expect(parser.entries == [
            ArchiveEntry(path: "top/", size: 0, isDirectory: true),
            ArchiveEntry(path: "top/a.txt", size: 700),
            ArchiveEntry(path: "top/b", size: 512),
            ArchiveEntry(path: "top/link", size: 0, isLink: true),
        ])
    }

    @Test func gnuLongNamesAndPaxHeaders() throws {
        let long = "top/" + String(repeating: "long", count: 40) + ".txt"
        let pax = Array("32 path=top/from-pax-header.txt\n".utf8)
        let tar = Self.file("././@LongLink", Array(long.utf8) + [0], type: "L") + Self.file("top/short", [1, 2, 3])
            + Self.file("PaxHeader", pax, type: "x") + Self.file("top/ignored", [UInt8](repeating: 0, count: 10))
            + Self.file("top/after", [9]) + Self.end
        var parser = TarParser()
        try parser.consume(Data(tar))
        #expect(parser.entries.map(\.path) == [long, "top/from-pax-header.txt", "top/after"])
        #expect(parser.entries.map(\.size) == [3, 10, 1])
    }

    @Test func paxSizeOverTheHeader() throws {
        let record = "20 size=12345678901\n"
        #expect(TarParser.paxRecords(Array(record.utf8)) == ["size": "12345678901"])
        #expect(TarHeader.number([0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10, 0x00][...]) == 4096)
        #expect(TarHeader.number(Array("00000001750 ".utf8)[...]) == 1000)
    }

    @Test func aTarCutShortListsWhatCame() throws {
        let tar = Self.file("a", [1]) + Self.file("b", [UInt8](repeating: 2, count: 2000))
        let url = try write(Data(tar.prefix(512 + 512 + 512 + 100)), "cut.tar")
        let listing = try ArchiveReader.listing(of: url, format: .tar)
        #expect(listing.truncated)
        #expect(listing.entries.map(\.path) == ["a", "b"])
    }

    @Test func notATar() throws {
        let url = try write(Data(repeating: 0x41, count: 2048), "bad.tar")
        #expect(throws: ArchiveError.notAnArchive) { try ArchiveReader.listing(of: url, format: .tar) }
        #expect(!TarHeader.checksumIsValid([UInt8](repeating: 0x41, count: 512)))
        #expect(TarHeader.checksumIsValid(Self.header("x", size: 1)))
    }

    // MARK: Crafted numbers: damage, not a crash

    /// `value` as `count` little-endian bytes.
    static func le(_ value: UInt64, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    /// A zip's end record: `count` files, a list of `size` bytes at `offset`.
    static func endRecord(count: UInt64, size: UInt64, offset: UInt64) -> [UInt8] {
        [0x50, 0x4B, 0x05, 0x06] + le(0, 4) + le(count, 2) + le(count, 2) + le(size, 4) + le(offset, 4) + le(0, 2)
    }

    /// The ZIP64 locator: where the ZIP64 end record is.
    static func locator(_ recordOffset: UInt64) -> [UInt8] {
        [0x50, 0x4B, 0x06, 0x07] + le(0, 4) + le(recordOffset, 8) + le(1, 4)
    }

    static func zip64Record(count: UInt64, size: UInt64, offset: UInt64) -> [UInt8] {
        [0x50, 0x4B, 0x06, 0x06] + le(44, 8) + le(0x2D, 2) + le(0x2D, 2) + le(0, 8)
            + le(count, 8) + le(count, 8) + le(size, 8) + le(offset, 8)
    }

    /// A central directory entry whose size is in a ZIP64 extra field.
    static func centralEntry(_ name: String, zip64Size: UInt64) -> [UInt8] {
        let extra = le(1, 2) + le(16, 2) + le(zip64Size, 8) + le(0, 8)
        return [0x50, 0x4B, 0x01, 0x02] + le(0x31E, 2) + le(0x2D, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(0, 4)
            + le(0xFFFF_FFFF, 4) + le(0xFFFF_FFFF, 4) + le(UInt64(name.utf8.count), 2) + le(UInt64(extra.count), 2)
            + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(0, 4) + Array(name.utf8) + extra
    }

    func zipListing(_ zip: [UInt8]) throws -> ArchiveListing {
        try ArchiveReader.listing(of: try write(Data(zip), "crafted.zip"), format: .zip)
    }

    @Test func zip64EndRecordBelowZero() throws {
        let zip = Self.locator(0x8000_0000_0000_0000) + Self.endRecord(count: 0xFFFF, size: 0xFFFF_FFFF, offset: 0xFFFF_FFFF)
        #expect(throws: ArchiveError.damaged("its ZIP64 end record is missing")) { try self.zipListing(zip) }
    }

    @Test func zip64ListNearTheLimit() throws {
        let zip = Self.zip64Record(count: 1, size: 46, offset: UInt64(Int64.max - 10)) + Self.locator(0)
            + Self.endRecord(count: 0xFFFF, size: 0xFFFF_FFFF, offset: 0xFFFF_FFFF)
        #expect(throws: ArchiveError.damaged("its list of files is out of place")) { try self.zipListing(zip) }
        let negative = Self.zip64Record(count: UInt64.max, size: 46, offset: 0) + Self.locator(0)
            + Self.endRecord(count: 0xFFFF, size: 0xFFFF_FFFF, offset: 0xFFFF_FFFF)
        #expect(throws: ArchiveError.damaged("its list of files is out of place")) { try self.zipListing(negative) }
    }

    @Test func zip64FileSizes() throws {
        let large = Self.centralEntry("large", zip64Size: 5_000_000_000)
        #expect(try self.zipListing(large + Self.endRecord(count: 1, size: UInt64(large.count), offset: 0)).entries
            == [ArchiveEntry(path: "large", size: 5_000_000_000)])
        let negative = Self.centralEntry("negative", zip64Size: UInt64.max)
        #expect(throws: ArchiveError.damaged("a file’s size in it is out of range")) {
            try self.zipListing(negative + Self.endRecord(count: 1, size: UInt64(negative.count), offset: 0))
        }
    }

    @Test func zipWithTooManyFiles() throws {
        let entries = Self.centralEntry("a", zip64Size: 1) + Self.centralEntry("b", zip64Size: 1)
        let zip = entries + Self.endRecord(count: 2, size: UInt64(entries.count), offset: 0)
        let read: (Int64, Int) throws -> Data = { offset, count in Data(zip[Int(offset)..<min(zip.count, Int(offset) + count)]) }
        #expect(try ZipDirectory.entries(size: Int64(zip.count), entryLimit: 2, read: read).count == 2)
        #expect(throws: ArchiveError.unsupported("a list of files this long")) {
            try ZipDirectory.entries(size: Int64(zip.count), entryLimit: 1, read: read)
        }
    }

    /// A pax record, "<length> <key>=<value>\n", for a record of 10 to 99 bytes.
    static func paxRecord(_ keyValue: String) -> [UInt8] {
        let rest = " \(keyValue)\n"
        return Array((String(rest.utf8.count + 2) + rest).utf8)
    }

    @Test(arguments: ["size=9223372036854775807", "size=-1", "GNU.sparse.realsize=-5"])
    func tarSizesOutOfRange(_ record: String) throws {
        let tar = Self.file("PaxHeader", Self.paxRecord(record), type: "x") + Self.file("big", []) + Self.end
        let url = try write(Data(tar), "crafted.tar")
        #expect(throws: ArchiveError.damaged("a file’s size in it is out of range")) {
            try ArchiveReader.listing(of: url, format: .tar)
        }
    }

    @Test func tarBinarySizeNearTheLimit() throws {
        let field: [UInt8] = [0x80, 0, 0, 0, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE, 0xFF]
        #expect(TarHeader.number(field[...]) == 0x7FFF_FFFF_FFFF_FEFF)
        var parser = TarParser()
        #expect(throws: ArchiveError.damaged("a file’s size in it is out of range")) {
            try parser.consume(Data(Self.header("big", size: 0, sizeField: field) + Self.end))
        }
    }

    @Test func numbersTooLongToRead() {
        #expect(TarParser.paxRecords(Array("99999999999999999999999 size=1\n".utf8)).isEmpty)
        #expect(TarHeader.number(Array(String(repeating: "7", count: 30).utf8)[...]) == nil)
    }

    @Test func tarWithTooManyFiles() throws {
        let tar = Self.file("a", [1]) + Self.file("b", [2]) + Self.file("c", [3]) + Self.end
        var three = TarParser(entryLimit: 3)
        try three.consume(Data(tar))
        #expect(three.entries.count == 3)
        var parser = TarParser(entryLimit: 2)
        #expect(throws: ArchiveError.unsupported("a list of files this long")) { try parser.consume(Data(tar)) }
    }

    // MARK: Gzip

    #if canImport(zlib)
    /// Python's tarfile (pax format), gzipped: a folder, a 700-byte file,
    /// a 164-character name and an empty file.
    static let paxTarGz = Data(base64Encoded: """
        H4sIAAAAAAAC/+3XSwrCMBSF4YxdRVfQJunLieDQoVuIWHSgtmiEuntTBwVLQXykKv0/KOmg0MHhXk5sWUXCM+lkSXI7ne7Z856l7vMgFQM4n6w5ul+KcbIufxPa2n4vf6XzpJN/nsYuf0n+3hngTwm8LYzCaL409aIw6+Lob//37P125+tM3+9/JbVKRVCz/71T+TSojN3OmiKwKw+bX36anjJhZj/d/3zH9rD/q878x64RavrfEFYtZmGs81/sK3vxeAd8+v6vZML9DwAAAAAAAACA110BGAKKeAAoAAA=
        """, options: .ignoreUnknownCharacters)!

    /// The same files in GNU format (a long-name entry).
    static let gnuTarGz = Data(base64Encoded: """
        H4sIAAAAAAAC/+3X0QqCMBiG4V3KrkC3ubnTLsCbMIiISqMW1N03OhASISq2Ct8HZOLpx//5L/SHUiSmotra+xmNz4n32ikrpBMZnE+hPUopZirE/NsiXML38tfG21H+3sZPUpF/ci3wpwQ+VpRFuWj6bt1sum3C/p/o/aHzjdPj/veuErKh/7P8/3cx/l9+Eq8ns5Yj/6f7vzaP818Zrwz7Xw7LAbMw1/lf7Q/hmrBkX77/a1Vx/wMAAAAAAAAA4H030JdyUAAoAAA=
        """, options: .ignoreUnknownCharacters)!

    /// The pax one gzipped in two members (as pigz and bgzip write).
    static let twoMemberTarGz = Data(base64Encoded: """
        H4sIAAAAAAAC/yvJL9BnoDEwAAIzExMwDQToNBa2mSlQuYIpAx1AaXFJYhHQSoaRCUqA8Z+oV1JRMnDxb2hkboIW/+amxsD4NxiNf5qDxFEwCoYoYBgFFAM9fT19h4DECo/UxJTUItqV/1jKfXiZb2RmhFr+GxoYGZoyKFSMlv80B4bmFgoFiSUZtqCGQE5+XvpgxqB2CtdongUBALhZ/1W4CwAAH4sIAAAAAAAC/+3TQQrCQAyF4RzFE9jMNOh5Koib2hlqBL29LYUK3QjSdjP/ByGPbLJ6IuvwlKs2dbctRwcnM9HJcquG+M3jvY5ni3JQ2cHz4U0/vJcyXWaCAo39v96zv4/+8o1+/Oz/Mge12ug/AAAAAAAAAAD/+gCvgPSoSBwAAA==
        """, options: .ignoreUnknownCharacters)!

    static let expected = ["top/", "top/a.txt", "top/" + String(repeating: "long", count: 40) + ".txt", "top/empty.txt"]

    @Test(arguments: [("pax.tar.gz", paxTarGz), ("gnu.tar.gz", gnuTarGz), ("two.tar.gz", twoMemberTarGz)])
    func tarGzLists(_ name: String, _ data: Data) throws {
        let url = try write(data, name)
        var fractions: [Double] = []
        let listing = try ArchiveReader.listing(of: url, format: .tarGzip, progress: { fractions.append($0) })
        #expect(!listing.truncated)
        #expect(listing.entries.map(\.path) == Self.expected)
        #expect(listing.entries.map(\.size) == [0, 700, 10, 0])
        #expect(fractions.last == 1)
    }

    /// Given a byte at a time, both members come out whole, and zeros
    /// after the last one end it.
    @Test func gzipInPiecesAndPadded() throws {
        let gzip = try GzipDecoder()
        var out = Data()
        for byte in Self.twoMemberTarGz + Data(count: 512) {
            try gzip.decode(Data([byte])) { out.append($0) }
        }
        #expect(out.count == 10240)
        #expect(gzip.isFinished)
        var parser = TarParser()
        try parser.consume(out)
        #expect(parser.entries.map(\.path) == Self.expected)
    }

    @Test func gzipThatIsBroken() throws {
        var damaged = Self.paxTarGz
        damaged.replaceSubrange(20..<40, with: Data(repeating: 0xFF, count: 20))
        let url = try write(damaged, "broken.tar.gz")
        #expect(throws: ArchiveError.self) { try ArchiveReader.listing(of: url, format: .tarGzip) }
    }
    #endif

    // MARK: The tree

    @Test func treeSumsFolders() {
        let tree = ArchiveTree(entries: [
            ArchiveEntry(path: "./b.txt", size: 5),
            ArchiveEntry(path: "src/lib/x.swift", size: 10),
            ArchiveEntry(path: "src/", size: 0, isDirectory: true),
            ArchiveEntry(path: "src/main.swift", size: 20),
            ArchiveEntry(path: "src/lib/y.swift", size: 30),
            ArchiveEntry(path: "a.txt", size: 1),
            ArchiveEntry(path: "a.txt", size: 2), // again: the later one counts
            ArchiveEntry(path: "empty/", size: 0, isDirectory: true),
        ])
        #expect(tree.totalSize == 67)
        #expect(tree.fileCount == 5)
        // Folders first, then files, by name.
        #expect(tree.root.children.map(\.name) == ["empty", "src", "a.txt", "b.txt"])
        let src = tree.root.children[1]
        #expect(src.size == 60 && src.fileCount == 3 && src.isDirectory)
        #expect(src.children.map(\.name) == ["lib", "main.swift"])
        #expect(src.children[0].path == "src/lib")
        #expect(tree.folderIDs.count == 3)

        #expect(tree.rows(expanded: []).map(\.node.name) == ["empty", "src", "a.txt", "b.txt"])
        let open = tree.rows(expanded: [src.id, src.children[0].id])
        #expect(open.map(\.node.name) == ["empty", "src", "lib", "x.swift", "y.swift", "main.swift", "a.txt", "b.txt"])
        #expect(open.map(\.depth) == [0, 0, 1, 2, 2, 1, 0, 0])
        // Several things at the top: nothing opens by itself.
        #expect(tree.initiallyExpanded.isEmpty)
    }

    @Test func folderSizesStopAtTheLargestNumber() {
        let tree = ArchiveTree(entries: [ArchiveEntry(path: "a/x", size: .max), ArchiveEntry(path: "a/y", size: .max)])
        #expect(tree.totalSize == .max)
        #expect(tree.root.children[0].size == .max)
    }

    @Test func oneFolderAtTheTopOpens() {
        let tree = ArchiveTree(entries: [ArchiveEntry(path: "kiri-1.0/src/a.swift", size: 1), ArchiveEntry(path: "kiri-1.0/README", size: 2)])
        let top = tree.root.children[0]
        #expect(tree.initiallyExpanded == [top.id])
        #expect(tree.rows(expanded: tree.initiallyExpanded).map(\.node.name) == ["kiri-1.0", "src", "README"])
    }

    @Test func numbersSortAsNumbers() {
        let tree = ArchiveTree(entries: ["f10", "f2", "F1"].map { ArchiveEntry(path: $0, size: 1) })
        #expect(tree.root.children.map(\.name) == ["F1", "f2", "f10"])
    }
}
