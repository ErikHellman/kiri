import Foundation

/// The metadata block some Markdown files start with: YAML between `---`
/// lines (Jekyll, Hugo, Obsidian, Astro…), or TOML between `+++` lines
/// (Hugo). The preview shows it as a table above the text.
///
/// Only the part of YAML that front matter uses is read: `key: value`,
/// nested maps by indentation, `- item` lists (of maps too), `[a, b]` flow
/// lists, quoted scalars, `|` and `>` blocks and comments. Anything else
/// (anchors, tags, a document that doesn't parse) leaves `entries` nil, and
/// the preview shows the block as it is written.
public struct FrontMatter: Equatable, Sendable {
    public enum Format: String, Sendable { case yaml, toml }

    /// A value: text, a list, or a map of its own.
    public indirect enum Value: Equatable, Sendable {
        case scalar(String)
        case list([Value])
        case map([Entry])
    }

    public struct Entry: Equatable, Sendable {
        public let key: String
        public let value: Value

        public init(_ key: String, _ value: Value) {
            self.key = key
            self.value = value
        }
    }

    public let format: Format
    /// The block's text between its delimiter lines.
    public let raw: String
    /// What it says, or nil when it couldn't be read.
    public let entries: [Entry]?
    /// How many lines of the file it takes, delimiters included.
    public let lineCount: Int

    public init(format: Format, raw: String, entries: [Entry]?, lineCount: Int) {
        self.format = format
        self.raw = raw
        self.entries = entries
        self.lineCount = lineCount
    }

    /// The front matter at the head of `text`, if it has some, and the
    /// rest of the text with the block's lines left empty: the Markdown
    /// after it keeps its line numbers (which the preview's scroll
    /// matching uses).
    public static func split(_ text: String) -> (frontMatter: FrontMatter?, body: String) {
        var lines = text.components(separatedBy: "\n")
        guard let first = lines.first else { return (nil, text) }
        let opener = first.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\r", with: "")
        let format: Format
        switch opener {
        case "---": format = .yaml
        case "+++": format = .toml
        default: return (nil, text)
        }
        let closers: Set<String> = format == .yaml ? ["---", "..."] : ["+++"]
        guard let end = lines.indices.dropFirst().first(where: {
            closers.contains(lines[$0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\r", with: ""))
        }) else { return (nil, text) }
        let inner = lines[1..<end].map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        // A `---` rule right after a `---` line is a thematic break, not metadata.
        guard format == .toml || !inner.isEmpty else { return (nil, text) }
        let raw = inner.joined(separator: "\n")
        let entries = format == .yaml ? YAMLSubset.parse(inner) : TOMLSubset.parse(inner)
        for i in 0...end { lines[i] = "" }
        return (FrontMatter(format: format, raw: raw, entries: entries, lineCount: end + 1),
                lines.joined(separator: "\n"))
    }
}

// MARK: YAML

/// The YAML front matter uses. Returns nil for what it doesn't know.
enum YAMLSubset {
    fileprivate struct Line {
        let indent: Int
        let text: String
    }

    static func parse(_ raw: [String]) -> [FrontMatter.Entry]? {
        var lines: [Line] = []
        for row in raw {
            // YAML indents with spaces only.
            if row.prefix(while: { $0 == " " || $0 == "\t" }).contains("\t") { return nil }
            let indent = row.prefix(while: { $0 == " " }).count
            let text = String(row.dropFirst(indent))
            lines.append(Line(indent: indent, text: text))
        }
        var parser = Parser(lines: lines)
        guard let entries = parser.map(indent: 0), parser.atEnd else { return nil }
        return entries
    }

    fileprivate struct Parser {
        let lines: [Line]
        var i = 0

        init(lines: [Line]) { self.lines = lines }

        var atEnd: Bool {
            var j = i
            while j < lines.count, Self.isBlank(lines[j]) { j += 1 }
            return j == lines.count
        }

        static func isBlank(_ line: Line) -> Bool { line.text.isEmpty || line.text.hasPrefix("#") }

        /// The next line with something on it, from `i`.
        mutating func next() -> Line? {
            while i < lines.count, Self.isBlank(lines[i]) { i += 1 }
            return i < lines.count ? lines[i] : nil
        }

        /// `key: value` lines at `indent`, until a line at less.
        mutating func map(indent: Int, first: String? = nil) -> [FrontMatter.Entry]? {
            var entries: [FrontMatter.Entry] = []
            var pending = first
            while true {
                let text: String
                if let p = pending {
                    text = p
                    pending = nil
                } else {
                    guard let line = next(), line.indent >= indent else { break }
                    guard line.indent == indent else { return nil }
                    text = line.text
                    i += 1
                }
                guard let (key, rest) = Self.keyValue(text) else { return nil }
                guard let value = value(after: rest, indent: indent) else { return nil }
                entries.append(FrontMatter.Entry(key, value))
            }
            return entries
        }

        /// What follows `key:` on its line (`rest`), and what is nested
        /// under it.
        mutating func value(after rest: String, indent: Int) -> FrontMatter.Value? {
            let rest = Self.stripComment(rest)
            if rest.isEmpty {
                guard let line = next() else { return .scalar("") }
                // A list may sit at the key's own indent (`key:\n- a`).
                if line.text.hasPrefix("- ") || line.text == "-", line.indent >= indent {
                    return list(indent: line.indent)
                }
                guard line.indent > indent else { return .scalar("") }
                return map(indent: line.indent).map { .map($0) }
            }
            if rest == "|" || rest == ">" || rest.hasPrefix("|-") || rest.hasPrefix(">-") || rest.hasPrefix("|+")
                || rest.hasPrefix(">+") {
                return .scalar(block(folded: rest.hasPrefix(">"), keep: rest.contains("+"), strip: rest.contains("-"),
                                     indent: indent))
            }
            if rest.hasPrefix("&") || rest.hasPrefix("*") || rest.hasPrefix("!") { return nil }
            return Self.inline(rest)
        }

        /// `- item` lines at `indent`.
        mutating func list(indent: Int) -> FrontMatter.Value? {
            var items: [FrontMatter.Value] = []
            while let line = next(), line.indent == indent, line.text == "-" || line.text.hasPrefix("- ") {
                i += 1
                let item = line.text == "-" ? "" : String(line.text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if item.isEmpty {
                    guard let nested = next(), nested.indent > indent else {
                        items.append(.scalar(""))
                        continue
                    }
                    if nested.text.hasPrefix("- ") {
                        guard let value = list(indent: nested.indent) else { return nil }
                        items.append(value)
                    } else {
                        guard let value = map(indent: nested.indent) else { return nil }
                        items.append(.map(value))
                    }
                } else if Self.keyValue(item) != nil, !item.hasPrefix("\""), !item.hasPrefix("'"), !item.hasPrefix("[") {
                    // `- key: value`, then the item's other keys under it.
                    let itemIndent = indent + 2 + (line.text.dropFirst(2).prefix(while: { $0 == " " }).count)
                    guard let entries = map(indent: itemIndent, first: item) else { return nil }
                    items.append(.map(entries))
                } else {
                    items.append(Self.inline(Self.stripComment(item)))
                }
            }
            return .list(items)
        }

        /// A `|` or `>` block: the lines indented under the key.
        mutating func block(folded: Bool, keep: Bool, strip: Bool, indent: Int) -> String {
            var body: [String] = []
            var blockIndent: Int?
            while i < lines.count {
                let line = lines[i]
                if line.text.isEmpty {
                    body.append("")
                    i += 1
                    continue
                }
                if blockIndent == nil {
                    guard line.indent > indent else { break }
                    blockIndent = line.indent
                }
                guard let b = blockIndent, line.indent >= b else { break }
                body.append(String(repeating: " ", count: line.indent - b) + line.text)
                i += 1
            }
            var trailing = 0
            while body.last == "" {
                body.removeLast()
                trailing += 1
            }
            var text: String
            if folded {
                // Lines fold into one with spaces; an empty line is a newline.
                text = ""
                var previousEmpty = true
                for line in body {
                    if line.isEmpty {
                        text += "\n"
                        previousEmpty = true
                    } else {
                        if !previousEmpty { text += " " }
                        text += line
                        previousEmpty = false
                    }
                }
            } else {
                text = body.joined(separator: "\n")
            }
            if strip { return text }
            return text + (keep ? String(repeating: "\n", count: trailing + 1) : "\n")
        }

        /// `key: rest`, if the line is one. The key may be quoted.
        static func keyValue(_ text: String) -> (String, String)? {
            if let quote = text.first, quote == "\"" || quote == "'" {
                guard let close = text.dropFirst().firstIndex(of: quote) else { return nil }
                let key = String(text[text.index(after: text.startIndex)..<close])
                let after = text[text.index(after: close)...]
                guard after.hasPrefix(":") else { return nil }
                return (key, String(after.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
            var search = text.startIndex
            while let colon = text[search...].firstIndex(of: ":") {
                let next = text.index(after: colon)
                if next == text.endIndex || text[next] == " " {
                    let key = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty, !key.hasPrefix("- "), !key.hasPrefix("{"), !key.hasPrefix("[") else { return nil }
                    return (key, String(text[next...]).trimmingCharacters(in: .whitespaces))
                }
                search = next
            }
            return nil
        }

        /// A value on one line: a flow list, a quoted or a plain scalar.
        static func inline(_ text: String) -> FrontMatter.Value {
            if text.hasPrefix("["), text.hasSuffix("]") {
                let inner = text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                if inner.isEmpty { return .list([]) }
                return .list(splitFlow(inner).map { inline($0.trimmingCharacters(in: .whitespaces)) })
            }
            return .scalar(unquote(text))
        }

        /// The items of a flow list, split at commas outside quotes and brackets.
        static func splitFlow(_ text: String) -> [String] {
            var items: [String] = []
            var current = ""
            var quote: Character?
            var depth = 0
            for c in text {
                if let q = quote {
                    current.append(c)
                    if c == q { quote = nil }
                    continue
                }
                switch c {
                case "\"", "'": quote = c; current.append(c)
                case "[", "{": depth += 1; current.append(c)
                case "]", "}": depth -= 1; current.append(c)
                case "," where depth == 0:
                    items.append(current)
                    current = ""
                default: current.append(c)
                }
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty { items.append(current) }
            return items
        }

        static func unquote(_ text: String) -> String {
            if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
                return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
                var out = ""
                var escaped = false
                for c in text.dropFirst().dropLast() {
                    if escaped {
                        switch c {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        default: out.append(c)
                        }
                        escaped = false
                    } else if c == "\\" {
                        escaped = true
                    } else {
                        out.append(c)
                    }
                }
                return out
            }
            return text
        }

        /// A plain value without its ` # comment`. Quoted ones keep theirs.
        static func stripComment(_ text: String) -> String {
            guard let first = text.first, first != "\"", first != "'" else {
                return text.trimmingCharacters(in: .whitespaces)
            }
            if text.hasPrefix("#") { return "" }
            if let r = text.range(of: " #") { return String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
            return text.trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: TOML

/// The TOML front matter uses: `key = value`, `[table]` and `[a.b]`
/// headers, strings, numbers, booleans, dates and one-line arrays.
enum TOMLSubset {
    static func parse(_ raw: [String]) -> [FrontMatter.Entry]? {
        var root: [FrontMatter.Entry] = []
        var tables: [(path: [String], entries: [FrontMatter.Entry])] = []
        for row in raw {
            let line = row.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), !line.hasPrefix("[[") else { return nil }
                let path = line.dropFirst().dropLast().split(separator: ".")
                    .map { YAMLSubset.unquoteTOML($0.trimmingCharacters(in: .whitespaces)) }
                guard !path.isEmpty, !path.contains(where: \.isEmpty) else { return nil }
                tables.append((path, []))
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { return nil }
            let key = YAMLSubset.unquoteTOML(String(line[..<eq]).trimmingCharacters(in: .whitespaces))
            let rest = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !rest.isEmpty else { return nil }
            let entry = FrontMatter.Entry(key, value(rest))
            if tables.isEmpty { root.append(entry) } else { tables[tables.count - 1].entries.append(entry) }
        }
        for table in tables { root = insert(table.entries, at: table.path[...], into: root) }
        return root
    }

    private static func insert(_ entries: [FrontMatter.Entry], at path: ArraySlice<String>,
                               into map: [FrontMatter.Entry]) -> [FrontMatter.Entry] {
        guard let head = path.first else { return map + entries }
        var map = map
        if let i = map.firstIndex(where: { $0.key == head }), case .map(let inner) = map[i].value {
            map[i] = FrontMatter.Entry(head, .map(insert(entries, at: path.dropFirst(), into: inner)))
        } else {
            map.append(FrontMatter.Entry(head, .map(insert(entries, at: path.dropFirst(), into: []))))
        }
        return map
    }

    static func value(_ text: String) -> FrontMatter.Value {
        var text = text
        if let quote = text.first, quote == "\"" || quote == "'" {
            // A string ends at its closing quote; a comment may follow.
            if let close = text.dropFirst().firstIndex(of: quote) { text = String(text[...close]) }
        } else if let r = text.range(of: " #") {
            text = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("["), text.hasSuffix("]") {
            let inner = text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .list([]) }
            return .list(YAMLSubset.Parser.splitFlow(inner).map { value($0.trimmingCharacters(in: .whitespaces)) })
        }
        return .scalar(YAMLSubset.unquoteTOML(text))
    }
}

extension YAMLSubset {
    static func unquoteTOML(_ text: String) -> String {
        if text.count >= 2, (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}
