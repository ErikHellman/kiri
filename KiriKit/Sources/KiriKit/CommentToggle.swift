import Foundation

/// How a language comments one line out.
public enum CommentSyntax: Hashable, Sendable {
    /// A marker that comments the rest of the line: `//`, `#`, `--`.
    case line(String)
    /// A pair around the line, for languages that only have block
    /// comments: `<!--` and `-->`, `/*` and `*/`.
    case block(open: String, close: String)
}

/// Toggle Comment (⌘/) on whole lines, as a function of strings so it can
/// be tested without an editor.
public enum CommentToggle {
    public struct Result: Equatable, Sendable {
        /// The lines after the toggle.
        public let text: String
        /// Where the selection is now (UTF-16 offsets into `text`): on
        /// the same characters as before.
        public let selection: Range<Int>
    }

    /// Comments or uncomments `lines`, which is whole lines (the last may
    /// lack its line break). If every line that isn't blank is commented,
    /// the markers come off; otherwise every such line gets one, at the
    /// indentation the lines share, followed by a space. Blank lines are
    /// left alone, except a single blank line on its own (the caret's),
    /// which gets a marker to type after.
    ///
    /// - Parameter selection: UTF-16 offsets into `lines`.
    /// - Returns: nil when there is nothing to do (only blank lines).
    public static func toggle(_ lines: String, syntax: CommentSyntax, selection: Range<Int> = 0..<0) -> Result? {
        let text = Array(lines.utf16)
        let (open, close): ([UInt16], [UInt16]) = switch syntax {
        case .line(let marker): (Array(marker.utf16), [])
        case .block(let open, let close): (Array(open.utf16), Array(close.utf16))
        }
        guard !open.isEmpty else { return nil }

        // Each line's content: without its line break, LF or CRLF.
        var all: [Line] = []
        var start = 0
        while start <= text.count {
            let lineBreak = text[start...].firstIndex(of: newline) ?? text.count
            var end = lineBreak
            if end > start, text[end - 1] == carriageReturn { end -= 1 }
            // What follows a final line break is not a line.
            if !(start == text.count && !all.isEmpty) { all.append(Line(text, start..<end)) }
            start = lineBreak + 1
        }
        var targets = all.filter { !$0.isBlank }
        if targets.isEmpty {
            guard all.count == 1 else { return nil }
            targets = all
        }

        var edits: [Edit] = []
        if targets.allSatisfy({ $0.isCommented(text, open: open, close: close) }) {
            for line in targets {
                // The marker and the one space that came with it.
                let afterOpen = line.code.lowerBound + open.count
                let spaced = afterOpen < line.trimmedEnd && text[afterOpen] == space
                edits.append(Edit(at: line.code.lowerBound, delete: open.count + (spaced ? 1 : 0)))
                guard !close.isEmpty else { continue }
                let closeStart = line.trimmedEnd - close.count
                let spacedBefore = closeStart - 1 >= afterOpen + (spaced ? 1 : 0) && text[closeStart - 1] == space
                edits.append(Edit(at: closeStart - (spacedBefore ? 1 : 0), delete: close.count + (spacedBefore ? 1 : 0)))
            }
        } else {
            // Where every line's indentation is still the same characters:
            // the least indentation, or less when tabs and spaces are mixed.
            var shared = targets.map(\.indent).min() ?? 0
            let first = targets[0]
            for line in targets.dropFirst() {
                var n = 0
                while n < shared, text[first.range.lowerBound + n] == text[line.range.lowerBound + n] { n += 1 }
                shared = n
            }
            for line in targets {
                edits.append(Edit(at: line.range.lowerBound + shared, insert: open + [space]))
                if !close.isEmpty { edits.append(Edit(at: line.range.upperBound, insert: [space] + close, closes: true)) }
            }
        }

        var out: [UInt16] = []
        out.reserveCapacity(text.count + edits.reduce(0) { $0 + $1.insert.count })
        var from = 0
        for edit in edits {
            out += text[from..<edit.at]
            out += edit.insert
            from = edit.at + edit.delete
        }
        out += text[from...]

        // The selection stays on its characters: an end that sits where a
        // marker goes in stays before it, a start (or the caret) after it,
        // and nothing moves past a closing marker put in at its place.
        func moved(_ position: Int, isStart: Bool) -> Int {
            var delta = 0
            for edit in edits {
                if position >= edit.at + edit.delete, edit.delete > 0 || position > edit.at || (isStart && !edit.closes) {
                    delta += edit.insert.count - edit.delete
                } else if position > edit.at {
                    delta -= position - edit.at
                }
            }
            return position + delta
        }
        let lower = moved(min(max(selection.lowerBound, 0), text.count), isStart: true)
        let upper = selection.isEmpty ? lower : max(lower, moved(min(max(selection.upperBound, 0), text.count), isStart: false))
        return Result(text: String(decoding: out, as: UTF16.self), selection: lower..<upper)
    }

    private static let newline: UInt16 = 0x0A, carriageReturn: UInt16 = 0x0D, space: UInt16 = 0x20, tab: UInt16 = 0x09

    /// One line of the text, in UTF-16 offsets.
    private struct Line {
        /// The line without its line break.
        let range: Range<Int>
        /// How many spaces and tabs it starts with.
        let indent: Int
        /// The end of the line without the spaces and tabs it ends with.
        let trimmedEnd: Int

        init(_ text: [UInt16], _ range: Range<Int>) {
            self.range = range
            var i = range.lowerBound
            while i < range.upperBound, text[i] == space || text[i] == tab { i += 1 }
            indent = i - range.lowerBound
            var end = range.upperBound
            while end > i, text[end - 1] == space || text[end - 1] == tab { end -= 1 }
            trimmedEnd = end
        }

        /// From the first character that isn't indentation.
        var code: Range<Int> { (range.lowerBound + indent)..<trimmedEnd }
        var isBlank: Bool { code.isEmpty }

        func isCommented(_ text: [UInt16], open: [UInt16], close: [UInt16]) -> Bool {
            guard code.count >= open.count + close.count, text[code].starts(with: open) else { return false }
            return close.isEmpty || text[(trimmedEnd - close.count)..<trimmedEnd].elementsEqual(close)
        }
    }

    /// Characters to take out at an offset of the old text, and what goes
    /// in there. Edits are made in order, front to back.
    private struct Edit {
        let at: Int
        var delete = 0
        var insert: [UInt16] = []
        /// A closing marker going in at the end of a line.
        var closes = false
    }
}
