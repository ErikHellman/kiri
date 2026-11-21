import Foundation

// What the status bar says about the caret and the file's indentation, and
// how much room it keeps for it. Plain Foundation so it tests on Linux.

/// The status bar's position item.
public enum StatusText {
    /// "Ln 12, Col 5", or with a selection its length in the column's
    /// place: "Ln 12, Sel 5".
    public static func position(line: Int, column: Int, selected: Int = 0) -> String {
        selected > 0 ? "Ln \(line), Sel \(selected)" : "Ln \(line), Col \(column)"
    }

    /// The same for VoiceOver: "Line 12 of 340, column 5" or
    /// "Line 12 of 340, 5 characters selected".
    public static func spokenPosition(line: Int, lineCount: Int, column: Int, selected: Int = 0) -> String {
        let place = "Line \(line) of \(lineCount)"
        if selected > 0 { return "\(place), \(selected) character\(selected == 1 ? "" : "s") selected" }
        return "\(place), column \(column)"
    }

    /// The room the position item keeps, so the bar doesn't change width as
    /// the caret moves: as many digits as the document's last line, its
    /// longest line and its whole length can need. It changes only when one
    /// of those passes a power of ten.
    public struct Reserve: Equatable, Sendable {
        public let lineDigits: Int
        public let columnDigits: Int
        public let selectionDigits: Int

        /// - Parameters:
        ///   - lineCount: the document's lines.
        ///   - longestLine: the length of its longest line (the caret can
        ///     stand one past it).
        ///   - length: the length of the whole text, the most a selection holds.
        public init(lineCount: Int = 1, longestLine: Int = 0, length: Int = 0) {
            // A new document doesn't grow the bar at its tenth line or
            // column, or its hundredth character.
            lineDigits = max(2, Self.digits(lineCount))
            columnDigits = max(2, Self.digits(longestLine + 1))
            selectionDigits = max(3, Self.digits(length))
        }

        /// The widest texts the document can show, for laying out in
        /// tabular digits (every digit as wide as 8).
        public var texts: [String] {
            func eights(_ n: Int) -> String { String(repeating: "8", count: n) }
            return ["Ln \(eights(lineDigits)), Col \(eights(columnDigits))",
                    "Ln \(eights(lineDigits)), Sel \(eights(selectionDigits))"]
        }

        static func digits(_ n: Int) -> Int { String(max(n, 0)).count }
    }
}

/// What a file indents its lines with.
public enum IndentStyle: Equatable, Sendable {
    case tabs
    case spaces(Int)

    /// One level of indentation.
    public var unit: String {
        switch self {
        case .tabs: "\t"
        case .spaces(let n): String(repeating: " ", count: n)
        }
    }

    /// How many leading spaces one level is worth when a line of spaces is
    /// outdented (a tab counts four).
    public var width: Int {
        switch self {
        case .tabs: 4
        case .spaces(let n): n
        }
    }

    /// Status bar label.
    public var label: String {
        switch self {
        case .tabs: "Tabs"
        case .spaces(let n): "Spaces: \(n)"
        }
    }

    /// The same for VoiceOver.
    public var spoken: String {
        switch self {
        case .tabs: "Tabs"
        case .spaces(let n): "\(n) space\(n == 1 ? "" : "s")"
        }
    }

    /// Every label is laid out in the room of the widest (all digits are
    /// equally wide; a level is never more than 8 spaces).
    public static let widestLabel = IndentStyle.spaces(8).label

    /// How much of a text `detect` reads (UTF-16 units) and how many
    /// indented lines it takes as enough.
    static let head = 65_536
    static let sample = 200

    /// The indentation of `text`: tabs when its first indented line starts
    /// with one, else the smallest run of leading spaces among its first
    /// indented lines (2 or 4, say; never more than 8). A text with no
    /// indented line gets tabs.
    public static func detect(in text: String) -> IndentStyle {
        var smallest = Int.max
        var seen = 0
        var leading = 0
        var inIndent = true
        scan: for unit in text.utf16.prefix(head) {
            switch unit {
            case 0x0A, 0x0D, 0x85, 0x2028, 0x2029:
                leading = 0
                inIndent = true
            case 0x20 where inIndent:
                leading += 1
            default:
                guard inIndent else { continue }
                inIndent = false
                if unit == 0x09, leading == 0 {
                    // A line that starts with a tab ends the search: tabs,
                    // unless lines indented with spaces came first.
                    if seen == 0 { return .tabs }
                    break scan
                }
                if leading > 0 {
                    smallest = min(smallest, leading)
                    seen += 1
                    if seen >= sample { break scan }
                }
            }
        }
        return smallest == .max ? .tabs : .spaces(min(smallest, 8))
    }
}
