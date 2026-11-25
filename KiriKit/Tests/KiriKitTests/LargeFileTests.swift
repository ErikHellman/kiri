import Foundation
import Testing
@testable import KiriKit

@Suite final class LargeFileTests {
    /// Where this test's files are, deleted after it.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kiri-large-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: folder) }

    /// A file with `contents`, opened and counted.
    func file(_ contents: String) throws -> LargeFile {
        try file(Data(contents.utf8))
    }

    func file(_ data: Data) throws -> LargeFile {
        let url = folder.appendingPathComponent("\(UUID().uuidString).log")
        try data.write(to: url)
        let f = try LargeFile(url: url)
        f.index()
        return f
    }

    @Test func countsLinesAsTheEditorDoes() throws {
        #expect(try file("").lineCount == 1)
        #expect(try file("one").lineCount == 1)
        #expect(try file("one\n").lineCount == 2)
        #expect(try file("one\ntwo\nthree").lineCount == 3)
        let f = try file("one\ntwo\n\nfour")
        #expect(f.lines(0..<10) == ["one", "two", "", "four"])
        #expect(f.lines(1..<3) == ["two", ""])
        #expect(f.isIndexed)
    }

    @Test func dropsTheCarriageReturnOfCRLF() throws {
        let f = try file("one\r\ntwo\r\nthree\r")
        #expect(f.lines(0..<3) == ["one", "two", "three"])
        #expect(f.lineRanges(0..<3) == [0..<3, 5..<8, 10..<15])
    }

    /// Many lines of different lengths, across blocks and checkpoints.
    func numbered(_ count: Int) -> String {
        (0..<count).map { "line \($0)" + String(repeating: "x", count: $0 % 37) }.joined(separator: "\n")
    }

    @Test func findsAnyLineFromTheCheckpoints() throws {
        let text = numbered(100_000)
        let f = try file(text)
        #expect(f.lineCount == 100_000)
        let expected = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in [0, 1, 255, 256, 257, 511, 512, 4_097, 77_777, 99_999] {
            #expect(f.lines(line..<(line + 1)) == [String(expected[line])])
        }
        #expect(f.lines(99_990..<200_000).count == 10)
        // And back: the line an offset is on.
        let ranges = f.lineRanges(70_000..<70_003)
        #expect(f.line(containing: ranges[1].lowerBound) == 70_001)
        #expect(f.line(containing: ranges[1].upperBound) == 70_001) // its "\n"
        #expect(f.line(containing: 0) == 0)
        #expect(f.line(containing: f.size) == 99_999)
    }

    @Test func countsAcrossBlocks() throws {
        // Over two blocks of the count, with a line across the seam.
        let line = String(repeating: "0123456789", count: 9) + "\n" // 91 bytes
        let lines = LargeFile.blockSize / line.utf8.count * 2 + 5
        let f = try file(String(repeating: line, count: lines))
        #expect(f.lineCount == lines + 1)
        let seam = LargeFile.blockSize / line.utf8.count
        #expect(f.lines(seam..<(seam + 2)) == [String(line.dropLast()), String(line.dropLast())])
        #expect(f.lines((lines - 1)..<(lines + 1)) == [String(line.dropLast()), ""])
    }

    @Test func cutsAVeryLongLineForShow() throws {
        let f = try file(String(repeating: "a", count: LargeFile.displayLimit * 3) + "\nend")
        #expect(f.lines(0..<2).map(\.utf8.count) == [LargeFile.displayLimit, 3])
    }

    @Test func showsBytesThatAreNotUTF8() throws {
        let f = try file(Data([0x61, 0xFF, 0x62, 0x0A, 0x63]))
        #expect(f.lines(0..<2) == ["a\u{FFFD}b", "c"])
    }

    @Test func countsWhatAGrowingFileAdds() throws {
        let f = try file("one\ntwo")
        let handle = try FileHandle(forWritingTo: f.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\nthree\nfour".utf8))
        try handle.close()
        // (The count went to the end of "two", which a "\n" now follows.)
        #expect(f.checkSize() == .grew)
        f.index()
        #expect(f.lineCount == 4)
        #expect(f.lines(0..<4) == ["one", "two", "three", "four"])
        #expect(f.checkSize() == .none)
        try Data("o".utf8).write(to: f.url)
        #expect(f.checkSize() == .shrank)
    }

    // MARK: Search

    func search(_ query: String, _ options: SearchOptions = SearchOptions(), in f: LargeFile,
                limit: Int = LargeFileSearch.defaultLimit) throws -> LargeFileSearch.Result {
        try LargeFileSearch(query, options: options).run(in: f, limit: limit)
    }

    @Test func plainSearchIgnoresASCIICaseUnlessAsked() throws {
        let f = try file("Error: disk\nerror again\nno ERROR here\nterror")
        #expect(try search("error", in: f).ranges == [0..<5, 12..<17, 27..<32, 39..<44])
        #expect(try search("error", SearchOptions(matchCase: true), in: f).ranges == [12..<17, 39..<44])
        #expect(try search("missing", in: f).count == 0)
        #expect(try search("", in: f).count == 0)
        // Non-ASCII matches exactly.
        let g = try file("Öl öl")
        #expect(try search("öl", in: g).ranges == [4..<7])
    }

    @Test func searchFindsMatchesAcrossBlockSeams() throws {
        // A match across the seam between two search blocks.
        var bytes = [UInt8](repeating: UInt8(ascii: "."), count: LargeFile.blockSize + 100)
        let at = LargeFile.blockSize - 3
        bytes.replaceSubrange(at..<(at + 6), with: Array("needle".utf8))
        bytes.replaceSubrange(10..<16, with: Array("NEEDLE".utf8))
        let f = try file(Data(bytes))
        #expect(try search("needle", in: f).ranges == [10..<16, at..<(at + 6)])
        #expect(try search("needle", SearchOptions(matchCase: true), in: f).ranges == [at..<(at + 6)])
    }

    @Test func searchCountsPastItsLimit() throws {
        let f = try file(String(repeating: "ab ", count: 1000))
        let r = try search("ab", in: f, limit: 10)
        #expect(r.ranges.count == 10)
        #expect(r.count == 1000)
        #expect(r.truncated)
        #expect(r.ranges.last == 27..<29)
    }

    @Test func searchCanBeCancelled() throws {
        let f = try file(numbered(1000))
        let r = try LargeFileSearch("line").run(in: f, isCancelled: { true })
        #expect(r.cancelled)
    }

    @Test func regularExpressionsGiveByteOffsets() throws {
        let regex = SearchOptions(regularExpression: true)
        let f = try file("é 12\nab 345\n")
        // "é" is two bytes.
        #expect(try search("\\d+", regex, in: f).ranges == [3..<5, 9..<12])
        #expect(try search("^ab", regex, in: f).ranges == [6..<8])
        #expect(try search("AB", regex, in: f).ranges == [6..<8])
        #expect(try search("AB", SearchOptions(matchCase: true, regularExpression: true), in: f).count == 0)
        // Not UTF-8: a byte a character.
        let g = try file(Data([0xFF, 0x31, 0x32, 0x0A]))
        #expect(try search("\\d+", regex, in: g).ranges == [1..<3])
        #expect(throws: TextSearch.InvalidPattern.self) { try LargeFileSearch("(", options: regex) }
    }

    @Test func regularExpressionBlocksEndAtALine() throws {
        let line = String(repeating: "x", count: 99) + "\n"
        var text = String(repeating: line, count: LargeFile.blockSize / 100 + 10)
        text += "match 42\n"
        let f = try file(text)
        let r = try search("x+", SearchOptions(regularExpression: true), in: f)
        #expect(r.count == LargeFile.blockSize / 100 + 10)
        #expect(try search("\\d+$", SearchOptions(regularExpression: true), in: f).count == 1)
    }

    // MARK: Bytes

    @Test func foldsEveryByteAsTheSlowWayDoes() {
        var bytes = (0..<256).map { UInt8($0) } + (0..<256).map { UInt8(255 - $0) } + Array("Hello WORLD Ä".utf8)
        let expected = bytes.map(LargeFileSearch.lower)
        bytes.withUnsafeMutableBufferPointer { LargeFileSearch.lowercase($0) }
        #expect(bytes == expected)
    }

    @Test func countsNewlinesEightBytesAtATime() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let bytes = (0..<8).map { _ in [0x0A, 0x0B, 0x8A, 0x00, 0xFF, 0x61][Int.random(in: 0..<6, using: &generator)] as UInt8 }
            let word = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            #expect(LargeFile.newlines(in: word) == bytes.filter { $0 == 0x0A }.count)
        }
    }
}
