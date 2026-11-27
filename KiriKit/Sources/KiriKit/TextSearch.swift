import Foundation

// Find and replace as functions on strings, for the editor's find bar.
// Positions are UTF-16 offsets (the unit NSString and NSTextView use), as in
// `LineIndex`. Nothing here knows about views.

/// What a search looks for beyond its text.
public struct SearchOptions: Equatable, Sendable {
    /// "Kiri" finds only "Kiri"; off, it also finds "kiri" and "KIRI".
    public var matchCase: Bool
    /// The query is a regular expression (ICU syntax; `^` and `$` match at
    /// each line), and a replacement may use `$1` for its groups.
    public var regularExpression: Bool

    public init(matchCase: Bool = false, regularExpression: Bool = false) {
        self.matchCase = matchCase
        self.regularExpression = regularExpression
    }
}

/// One query, ready to run on any text.
public struct TextSearch: @unchecked Sendable {
    /// The query is not a regular expression that can be used.
    public struct InvalidPattern: Error, Equatable, Sendable {
        // periphery:ignore - the error's own text, for whoever catches it
        public let message: String
    }

    /// The matches found, in the order they stand in the text.
    public struct Matches: Equatable, Sendable {
        public var ranges: [Range<Int>]
        /// The text has more matches than the limit asked for.
        public var truncated: Bool

        public init(ranges: [Range<Int>] = [], truncated: Bool = false) {
            self.ranges = ranges
            self.truncated = truncated
        }
    }

    /// Every match replaced, as one edit: `range` of the old text (from the
    /// first match to the last) becomes `text`.
    public struct Replacement: Equatable, Sendable {
        public let range: Range<Int>
        public let text: String
        /// How many matches were replaced.
        public let count: Int
    }

    public let query: String
    public let options: SearchOptions
    // Immutable once made, and safe to match with from any thread.
    private let regex: NSRegularExpression

    /// How many matches a search collects unless told otherwise.
    public static let defaultLimit = 100_000

    /// Throws for a regular expression that doesn't compile. An empty query
    /// is valid and finds nothing.
    public init(_ query: String, options: SearchOptions = SearchOptions()) throws(InvalidPattern) {
        self.query = query
        self.options = options
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.matchCase { flags.insert(.caseInsensitive) }
        let pattern = query.isEmpty ? "(?!)"
            : options.regularExpression ? query : NSRegularExpression.escapedPattern(for: query)
        do {
            regex = try NSRegularExpression(pattern: pattern, options: flags)
        } catch {
            throw InvalidPattern(message: error.localizedDescription)
        }
    }

    // MARK: Finding

    /// The matches in `text`, at most `limit` of them. Matches of no length
    /// (`^`, `x*` where there is no x) are left out: there is nothing to
    /// show or select. `isCancelled` is asked now and then during a long
    /// search; when it says yes the search stops and the result is nil.
    public func matches(in text: String, limit: Int = TextSearch.defaultLimit,
                        isCancelled: (() -> Bool)? = nil) -> Matches? {
        var found = Matches()
        var cancelled = false
        guard !query.isEmpty else { return found }
        let whole = NSRange(location: 0, length: text.utf16.count)
        regex.enumerateMatches(in: text, options: isCancelled == nil ? [] : [.reportProgress], range: whole) {
            result, _, stop in
            if let isCancelled, isCancelled() {
                cancelled = true
                stop.pointee = true
                return
            }
            guard let range = result?.range, range.length > 0 else { return }
            if found.ranges.count >= limit {
                found.truncated = true
                stop.pointee = true
                return
            }
            found.ranges.append(range.location..<(range.location + range.length))
        }
        return cancelled ? nil : found
    }

    /// Which of `ranges` (sorted, as `matches` gives them) Find Next or Find
    /// Previous goes to. From the match at `current` it is the one after or
    /// before it; otherwise the first that starts at or after the end of
    /// `selection`, or the last that ends at or before its start. Either
    /// way it wraps around at the ends. Nil only when there are no matches.
    public static func step(from current: Int?, selection: Range<Int>, forward: Bool,
                            in ranges: [Range<Int>]) -> Int? {
        guard !ranges.isEmpty else { return nil }
        if let current, ranges.indices.contains(current) {
            return forward ? (current + 1) % ranges.count : (current + ranges.count - 1) % ranges.count
        }
        if forward {
            return index(startingAtOrAfter: selection.upperBound, in: ranges)
        }
        // The last match that ends at or before the selection's start.
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].upperBound <= selection.lowerBound { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : ranges.count - 1
    }

    /// The first of `ranges` that starts at or after `offset`, or the first
    /// of all when none does (what a search shows as the query is typed:
    /// the match under the caret stays the current one while it still
    /// matches). Nil only when there are no matches.
    public static func index(startingAtOrAfter offset: Int, in ranges: [Range<Int>]) -> Int? {
        guard !ranges.isEmpty else { return nil }
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].lowerBound < offset { lo = mid + 1 } else { hi = mid }
        }
        return lo < ranges.count ? lo : 0
    }

    /// Where exactly `range` is in `ranges`, if it is one of them.
    public static func index(of range: Range<Int>, in ranges: [Range<Int>]) -> Int? {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].lowerBound < range.lowerBound { lo = mid + 1 } else { hi = mid }
        }
        return lo < ranges.count && ranges[lo] == range ? lo : nil
    }

    // MARK: Replacing

    /// What `match` (one of `matches(in:)`) becomes when replaced with
    /// `template`: the template as it is, or for a regular expression with
    /// `$0` … `$9` filled in from the match and `\n`, `\t` as a new line
    /// and a tab. Nil when the text has no match exactly there any more.
    public func replacement(for match: Range<Int>, in text: String, with template: String) -> String? {
        let length = text.utf16.count
        guard !query.isEmpty, match.lowerBound >= 0, match.upperBound <= length else { return nil }
        // From the match on, seeing the text around it (for `^`, `\b`,
        // lookbehind), and only a match that starts right there.
        let rest = NSRange(location: match.lowerBound, length: length - match.lowerBound)
        guard let result = regex.firstMatch(in: text, options: [.anchored, .withTransparentBounds, .withoutAnchoringBounds],
                                            range: rest),
              result.range.location == match.lowerBound, result.range.length == match.count else { return nil }
        return regex.replacementString(for: result, in: text, offset: 0, template: icuTemplate(template))
    }

    /// Every match in `text` replaced with `template`, as one edit, or nil
    /// when there are none.
    public func replaceAll(in text: String, with template: String) -> Replacement? {
        guard !query.isEmpty else { return nil }
        let source = NSString(string: text)
        let icu = icuTemplate(template)
        let out = NSMutableString(capacity: 0) // (Linux has only this initialiser)
        var first = -1, end = 0, count = 0
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: source.length)) { result, _, _ in
            guard let result, result.range.length > 0 else { return }
            if first < 0 {
                first = result.range.location
            } else {
                out.append(source.substring(with: NSRange(location: end, length: result.range.location - end)))
            }
            out.append(regex.replacementString(for: result, in: text, offset: 0, template: icu))
            end = result.range.location + result.range.length
            count += 1
        }
        guard count > 0 else { return nil }
        return Replacement(range: first..<end, text: String(out), count: count)
    }

    /// `text` with every match replaced, and how many there were.
    public func replacingAll(in text: String, with template: String) -> (text: String, count: Int) {
        guard let all = replaceAll(in: text, with: template) else { return (text, 0) }
        let source = NSString(string: text)
        let range = NSRange(location: all.range.lowerBound, length: all.range.count)
        return (source.replacingCharacters(in: range, with: all.text), all.count)
    }

    /// The template in the form NSRegularExpression takes. A plain search
    /// replaces with exactly what was typed, `$` and `\` included.
    private func icuTemplate(_ template: String) -> String {
        guard options.regularExpression else { return NSRegularExpression.escapedTemplate(for: template) }
        var out = ""
        var escaped = false
        for ch in template {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                // `\\` and `\$` stay for the template to read.
                default: out.append("\\"); out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        if escaped { out.append("\\\\") }
        return out
    }
}

/// What Go to Line was asked for: "12", or "12:5" for a column too.
public struct LineTarget: Equatable, Sendable {
    /// 1-based, inside the document: a number past either end becomes the
    /// first or the last line.
    public let line: Int
    /// 1-based.
    public let column: Int

    /// Nil for anything that isn't a line number with an optional column.
    public init?(_ input: String, lineCount: Int) {
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count <= 2, let first = parts.first, let line = Int(first) else { return nil }
        var column = 1
        if parts.count == 2, !parts[1].isEmpty {
            guard let c = Int(parts[1]) else { return nil }
            column = max(1, c)
        }
        self.line = min(max(line, 1), max(lineCount, 1))
        self.column = column
    }
}
