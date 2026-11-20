import Foundation

// The editor's file model: bytes on disk ⇄ text in the editor. Plain
// Foundation so it tests on Linux too.
//
// The editor always works on text with "\n" line endings. Reading detects the
// file's encoding (BOM, then UTF-8, then UTF-16 without a BOM, then Windows
// Latin 1) and its line ending; writing puts both back, so an unchanged file
// saves byte for byte as it was read (as long as its line endings were
// consistent to begin with).

/// How lines end in a file.
public enum LineEnding: String, CaseIterable, Sendable {
    case lf, crlf, cr

    /// The characters on disk.
    public var characters: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        }
    }

    /// Status bar label.
    public var label: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
    }

    /// The most common line ending in `text` (LF when there are none).
    public static func detect(in text: String) -> LineEnding {
        var lf = 0, crlf = 0, cr = 0
        var previousCR = false
        for u in text.utf8 {
            if u == 0x0D {
                if previousCR { cr += 1 }
                previousCR = true
            } else {
                if u == 0x0A { if previousCR { crlf += 1 } else { lf += 1 } }
                else if previousCR { cr += 1 }
                previousCR = false
            }
        }
        if previousCR { cr += 1 }
        if crlf > lf && crlf >= cr { return .crlf }
        if cr > lf && cr > crlf { return .cr }
        return .lf
    }

    /// `text` with every line ending (LF, CRLF or CR) turned into "\n".
    public static func normalize(_ text: String) -> String {
        guard text.utf8.contains(0x0D) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// `text` (with "\n" line endings) using this line ending.
    public func apply(to text: String) -> String {
        self == .lf ? text : text.replacingOccurrences(of: "\n", with: characters)
    }
}

/// A text encoding Kiri reads and writes.
public enum TextEncoding: String, CaseIterable, Sendable {
    case utf8, utf16LE, utf16BE, utf32LE, utf32BE, windowsLatin1

    public var label: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16LE: "UTF-16 LE"
        case .utf16BE: "UTF-16 BE"
        case .utf32LE: "UTF-32 LE"
        case .utf32BE: "UTF-32 BE"
        case .windowsLatin1: "Windows Latin 1"
        }
    }

    public var foundation: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16LE: .utf16LittleEndian
        case .utf16BE: .utf16BigEndian
        case .utf32LE: .utf32LittleEndian
        case .utf32BE: .utf32BigEndian
        case .windowsLatin1: .windowsCP1252
        }
    }

    /// The byte order mark for this encoding (empty for Latin 1).
    public var bom: [UInt8] {
        switch self {
        case .utf8: [0xEF, 0xBB, 0xBF]
        case .utf16LE: [0xFF, 0xFE]
        case .utf16BE: [0xFE, 0xFF]
        case .utf32LE: [0xFF, 0xFE, 0x00, 0x00]
        case .utf32BE: [0x00, 0x00, 0xFE, 0xFF]
        case .windowsLatin1: []
        }
    }

    /// Whether this is a Unicode encoding (can store any text).
    public var isUnicode: Bool { self != .windowsLatin1 }
}

/// Why a file could not be opened as text.
public enum TextFileError: Error, Equatable, Sendable {
    /// The bytes look like a binary file (NUL bytes, invalid in every encoding).
    case binary
    /// The text can't be stored in the file's encoding.
    case unencodable(TextEncoding)
}

/// A text file's contents and the format to write them back in.
public struct TextFile: Equatable, Sendable {
    /// The text, with "\n" line endings.
    public var text: String
    public var encoding: TextEncoding
    public var lineEnding: LineEnding
    /// Whether the file starts with a byte order mark.
    public var hasBOM: Bool

    public init(text: String = "", encoding: TextEncoding = .utf8, lineEnding: LineEnding = .lf, hasBOM: Bool = false) {
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.hasBOM = hasBOM
    }

    /// Reads a file's bytes, detecting the encoding and line ending.
    public init(data: Data) throws {
        let bytes = [UInt8](data)
        let (encoding, bomLength) = Self.detectEncoding(bytes)
        let body = Data(bytes[bomLength...])
        guard let raw = String(data: body, encoding: encoding.foundation) else { throw TextFileError.binary }
        // NUL is legal text but a sure sign of a binary file in UTF-8 / Latin 1.
        if !encoding.isUnicode || encoding == .utf8, raw.utf8.contains(0) { throw TextFileError.binary }
        self.init(text: LineEnding.normalize(raw), encoding: encoding, lineEnding: LineEnding.detect(in: raw),
                  hasBOM: bomLength > 0)
    }

    /// The bytes to write: the text in the file's encoding and line ending.
    public func data() throws -> Data {
        let onDisk = lineEnding.apply(to: text)
        guard let body = onDisk.data(using: encoding.foundation, allowLossyConversion: false) else {
            throw TextFileError.unencodable(encoding)
        }
        return hasBOM ? Data(encoding.bom) + body : body
    }

    /// The encoding of `bytes` and the length of its byte order mark.
    static func detectEncoding(_ bytes: [UInt8]) -> (TextEncoding, Int) {
        func starts(_ p: [UInt8]) -> Bool { bytes.count >= p.count && Array(bytes[0..<p.count]) == p }
        // UTF-32 LE before UTF-16 LE: their BOMs share a prefix.
        for e in [TextEncoding.utf32LE, .utf32BE, .utf8, .utf16LE, .utf16BE] where starts(e.bom) {
            return (e, e.bom.count)
        }
        // UTF-16 without a BOM: mostly-ASCII text has a NUL in every other byte.
        if bytes.count >= 4, bytes.count % 2 == 0, bytes.contains(0) {
            let sample = bytes.prefix(4096)
            let evenNUL = stride(from: 0, to: sample.count, by: 2).filter { sample[sample.startIndex + $0] == 0 }.count
            let oddNUL = stride(from: 1, to: sample.count, by: 2).filter { sample[sample.startIndex + $0] == 0 }.count
            let half = sample.count / 2
            if oddNUL > half * 6 / 10, evenNUL == 0 { return (.utf16LE, 0) }
            if evenNUL > half * 6 / 10, oddNUL == 0 { return (.utf16BE, 0) }
        }
        if String(data: Data(bytes), encoding: .utf8) != nil { return (.utf8, 0) }
        return (.windowsLatin1, 0)
    }
}
