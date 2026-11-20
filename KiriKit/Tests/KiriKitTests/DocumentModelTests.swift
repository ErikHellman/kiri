import Foundation
import Testing
@testable import KiriKit

@Suite struct TextFileTests {
    func roundTrip(_ bytes: [UInt8], encoding: TextEncoding, lineEnding: LineEnding, bom: Bool,
                   text: String) throws {
        let file = try TextFile(data: Data(bytes))
        #expect(file.encoding == encoding)
        #expect(file.lineEnding == lineEnding)
        #expect(file.hasBOM == bom)
        #expect(file.text == text)
        #expect(try [UInt8](file.data()) == bytes, "saves byte for byte")
    }

    @Test func utf8() throws {
        try roundTrip(Array("héllo\nwörld 🍯\n".utf8), encoding: .utf8, lineEnding: .lf, bom: false,
                      text: "héllo\nwörld 🍯\n")
    }

    @Test func utf8WithBOM() throws {
        try roundTrip([0xEF, 0xBB, 0xBF] + Array("a\nb".utf8), encoding: .utf8, lineEnding: .lf, bom: true, text: "a\nb")
    }

    @Test func crlf() throws {
        try roundTrip(Array("one\r\ntwo\r\n".utf8), encoding: .utf8, lineEnding: .crlf, bom: false, text: "one\ntwo\n")
    }

    @Test func classicMacCR() throws {
        try roundTrip(Array("one\rtwo\r".utf8), encoding: .utf8, lineEnding: .cr, bom: false, text: "one\ntwo\n")
    }

    @Test func utf16LEWithBOM() throws {
        let body = "hi\r\nyou".data(using: .utf16LittleEndian)!
        try roundTrip([0xFF, 0xFE] + [UInt8](body), encoding: .utf16LE, lineEnding: .crlf, bom: true, text: "hi\nyou")
    }

    @Test func utf16BEWithBOM() throws {
        let body = "hej\n".data(using: .utf16BigEndian)!
        try roundTrip([0xFE, 0xFF] + [UInt8](body), encoding: .utf16BE, lineEnding: .lf, bom: true, text: "hej\n")
    }

    @Test func utf16LEWithoutBOM() throws {
        let body = "plain ascii text\n".data(using: .utf16LittleEndian)!
        try roundTrip([UInt8](body), encoding: .utf16LE, lineEnding: .lf, bom: false, text: "plain ascii text\n")
    }

    @Test func latin1Fallback() throws {
        // "café" in Windows-1252 is not valid UTF-8.
        try roundTrip([0x63, 0x61, 0x66, 0xE9, 0x0A], encoding: .windowsLatin1, lineEnding: .lf, bom: false,
                      text: "café\n")
    }

    @Test func emptyFile() throws {
        try roundTrip([], encoding: .utf8, lineEnding: .lf, bom: false, text: "")
    }

    @Test func rejectsBinary() {
        #expect(throws: TextFileError.binary) { try TextFile(data: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x01])) }
    }

    @Test func newTextInFileFormat() throws {
        var file = try TextFile(data: Data("a\r\n".utf8))
        file.text = "a\nb\n"
        #expect(try file.data() == Data("a\r\nb\r\n".utf8))
    }

    @Test func latin1CannotStoreEmoji() throws {
        var file = try TextFile(data: Data([0xE9]))
        file.text = "🍯"
        #expect(throws: TextFileError.unencodable(.windowsLatin1)) { try file.data() }
    }

    @Test func lineEndingDetection() {
        #expect(LineEnding.detect(in: "") == .lf)
        #expect(LineEnding.detect(in: "a\r\nb\r\nc\n") == .crlf)
        #expect(LineEnding.detect(in: "a\nb\nc\r\n") == .lf)
        #expect(LineEnding.detect(in: "a\rb\r") == .cr)
        #expect(LineEnding.normalize("a\r\nb\rc\n") == "a\nb\nc\n")
    }
}

@Suite struct LineIndexTests {
    @Test func buildsFromText() {
        let index = LineIndex("ab\ncd\n\nef")
        #expect(index.starts == [0, 3, 6, 7])
        #expect(index.lineCount == 4)
        #expect(index.line(at: 0) == 0)
        #expect(index.line(at: 2) == 0)
        #expect(index.line(at: 3) == 1)
        #expect(index.line(at: 6) == 2)
        #expect(index.line(at: 9) == 3)
        #expect(index.range(ofLine: 1) == 3..<5)
        #expect(index.range(ofLine: 3) == 7..<9)
    }

    @Test func emptyText() {
        let index = LineIndex("")
        #expect(index.starts == [0])
        #expect(index.line(at: 0) == 0)
    }

    @Test func gutterEdgeCases() {
        // No trailing newline: two lines.
        let a = LineIndex("one\ntwo")
        #expect(a.lineCount == 2)
        #expect(a.line(at: a.length) == 1)
        // Trailing newline: the empty last line is a line of its own.
        let b = LineIndex("one\ntwo\n")
        #expect(b.lineCount == 3)
        #expect(b.line(at: b.length) == 2)
        #expect(b.range(ofLine: 2) == 8..<8)
        // Offsets past the end clamp to the last line.
        #expect(b.line(at: 1000) == 2)
        #expect(LineIndex("").line(at: 5) == 0)
        #expect(LineIndex("").range(ofLine: 0) == 0..<0)
    }

    /// Loading text into a non-empty editor replaces all of it (the case that
    /// once doubled the index and crashed the gutter).
    @Test func replaceEverything() {
        var index = LineIndex("old\ntext\n")
        index.replace(range: 0..<index.length, with: "new\n")
        #expect(index == LineIndex("new\n"))
        var empty = LineIndex()
        empty.replace(range: 0..<0, with: "a\nb")
        #expect(empty == LineIndex("a\nb"))
    }

    @Test func utf16Offsets() {
        // 🍯 is two UTF-16 units.
        #expect(LineIndex("🍯\nx").starts == [0, 3])
    }

    /// Random edits stay identical to rebuilding the index from scratch.
    @Test func incrementalEditsMatchRebuild() {
        var rng = SplitMix(seed: 42)
        var text = "first line\nsecond\n\nthird line here\n"
        var index = LineIndex(text)
        let pieces = ["", "x", "\n", "ab\ncd", "\n\n", "🍯", "line\n"]
        for _ in 0..<2000 {
            let units = Array(text.utf16)
            let a = Int(rng.next() % UInt64(units.count + 1))
            let b = min(units.count, a + Int(rng.next() % 6))
            // Keep edits on scalar boundaries so the String round trip is lossless.
            guard String(decoding: units[..<a], as: UTF16.self).utf16.count == a,
                  String(decoding: units[b...], as: UTF16.self).utf16.count == units.count - b else { continue }
            let piece = pieces[Int(rng.next() % UInt64(pieces.count))]
            text = String(decoding: units[..<a], as: UTF16.self) + piece + String(decoding: units[b...], as: UTF16.self)
            index.replace(range: a..<b, with: piece)
            #expect(index == LineIndex(text))
            if index != LineIndex(text) { break }
        }
    }
}

@Suite struct LanguageTests {
    @Test func byExtension() {
        #expect(Language.detect(fileName: "main.swift") == .swift)
        #expect(Language.detect(fileName: "package.JSON") == .json)
        #expect(Language.detect(fileName: "ci.yml") == .yaml)
        #expect(Language.detect(fileName: "README.md") == .markdown)
        #expect(Language.detect(fileName: "app.tsx") == .tsx)
        #expect(Language.detect(fileName: "styles.css") == .css)
        #expect(Language.detect(fileName: "notes") == .plainText)
        #expect(Language.detect(fileName: nil) == .plainText)
    }

    @Test func byFileName() {
        #expect(Language.detect(fileName: "Makefile") == .makefile)
        #expect(Language.detect(fileName: ".zshrc") == .shell)
        #expect(Language.detect(fileName: ".env.local") == .ini)
        #expect(Language.detect(fileName: "Dockerfile.dev") == .dockerfile)
    }

    @Test func byShebang() {
        #expect(Language.detect(fileName: "run", firstLine: "#!/usr/bin/env python3") == .python)
        #expect(Language.detect(fileName: "run", firstLine: "#!/bin/zsh") == .shell)
        #expect(Language.detect(fileName: "run", firstLine: "#!/usr/bin/env -S node --flag") == .javascript)
        #expect(Language.detect(fileName: "run", firstLine: "hello") == .plainText)
    }

    @Test func uniqueIDs() {
        #expect(Set(Language.all.map(\.id)).count == Language.all.count)
    }
}

/// A small deterministic random generator for the tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
