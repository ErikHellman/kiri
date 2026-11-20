import Foundation

/// The kinds of highlighted code, each with a Honey color token.
public enum SyntaxKind: String, CaseIterable, Sendable {
    case keyword, string, number, comment, function, type, property, tag, attribute, punctuation, heading, escape
    /// Emphasis in prose (Markdown): drawn in the text color, with a font trait.
    case strong, emphasis, link, code

    public var token: Honey.Token {
        switch self {
        case .keyword: Honey.synKeyword
        case .string, .code: Honey.synString
        case .number: Honey.synNumber
        case .comment: Honey.synComment
        case .function: Honey.synFunction
        case .type: Honey.synType
        case .property: Honey.synProperty
        case .tag: Honey.synTag
        case .attribute: Honey.synAttribute
        case .punctuation: Honey.synPunctuation
        case .heading: Honey.synHeading
        case .escape: Honey.synEscape
        case .strong, .emphasis: Honey.fg
        case .link: Honey.synFunction
        }
    }

    /// The kind for a tree-sitter highlight capture name such as
    /// `keyword.control`, `string.special.url` or `punctuation.bracket`;
    /// nil for captures Kiri leaves in the text color (`variable`, …).
    public init?(capture name: String) {
        let parts = name.split(separator: ".").map(String.init)
        guard let head = parts.first else { return nil }
        let rest = parts.dropFirst()
        switch head {
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass", "label":
            self = .keyword
        case "operator":
            self = rest.contains("word") ? .keyword : .punctuation
        case "string", "character":
            if rest.contains("escape") { self = .escape }
            else if rest.contains("regex") || rest.contains("regexp") { self = .escape }
            else if rest.contains("special") && rest.contains("key") { self = .property }
            else if rest.contains("url") || rest.contains("uri") { self = .link }
            else { self = .string }
        case "escape": self = .escape
        case "number", "float", "boolean": self = .number
        case "constant":
            self = rest.contains("builtin") || rest.contains("numeric") || rest.contains("character") ? .number : .number
        case "comment": self = .comment
        case "function", "method":
            self = rest.contains("macro") ? .keyword : .function
        case "constructor": self = .type
        case "type", "namespace", "module": self = .type
        case "property", "field": self = .property
        case "attribute": self = .attribute
        case "tag":
            self = rest.contains("attribute") ? .attribute : rest.contains("delimiter") ? .punctuation : .tag
        case "punctuation":
            self = rest.contains("special") ? .escape : .punctuation
        case "variable":
            if rest.contains("builtin") { self = .keyword }
            else if rest.contains("member") || rest.contains("property") { self = .property }
            else if rest.contains("parameter") { return nil }
            else { return nil }
        case "embedded": return nil
        // Markup (Markdown): tree-sitter uses both `markup.*` and the older `text.*`.
        case "markup", "text":
            switch rest.first {
            case "heading", "title": self = .heading
            case "strong", "bold": self = .strong
            case "italic", "emphasis": self = .emphasis
            case "link", "uri", "reference": self = .link
            case "raw", "literal": self = .code
            case "quote": self = .comment
            case "list": self = .punctuation
            case nil: return nil
            default: return nil
            }
        default: return nil
        }
    }
}

/// A highlighted range in UTF-16 offsets.
public struct SyntaxSpan: Equatable, Sendable {
    public var range: Range<Int>
    public var kind: SyntaxKind

    public init(_ range: Range<Int>, _ kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

/// A small lexer for languages without a tree-sitter grammar: strings,
/// numbers, line comments and a handful of common keywords. Good enough to
/// make TOML, INI, logs or Rust readable without being wrong in loud ways.
public enum FallbackHighlighter {
    static let keywords: Set<String> = [
        "true", "false", "null", "nil", "none", "None", "True", "False", "if", "else", "for", "while", "return",
        "fn", "func", "function", "def", "class", "struct", "enum", "let", "var", "const", "import", "package",
        "pub", "use", "mod", "impl", "trait", "match", "case", "switch", "break", "continue", "in", "public",
        "private", "static", "void", "int", "new", "this", "self", "type", "interface", "select", "from", "where",
        "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "CREATE", "TABLE", "AND", "OR", "NOT",
    ]

    /// Spans for `text` (UTF-16 offsets), within `range` if given.
    public static func spans(in text: String, language: Language, range: Range<Int>? = nil) -> [SyntaxSpan] {
        let units = Array(text.utf16)
        let lower = range?.lowerBound ?? 0
        let upper = min(range?.upperBound ?? units.count, units.count)
        var spans: [SyntaxSpan] = []
        let comment = language.lineComment.map { Array($0.utf16) }
        let isMarkup = language == .xml || language == .html
        var i = lower
        // Start at a line boundary so strings and comments are found whole.
        while i > 0 && units[i - 1] != 0x0A { i -= 1 }

        func at(_ p: [UInt16], _ j: Int) -> Bool {
            j + p.count <= units.count && Array(units[j..<(j + p.count)]) == p
        }
        func isIdent(_ u: UInt16) -> Bool {
            (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F
        }
        func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }

        var lineStart = true
        while i < upper {
            let u = units[i]
            if u == 0x0A { lineStart = true; i += 1; continue }
            // Comments: the language's line comment, or `#`/`;` at line start in config files.
            if let comment, at(comment, i) || (language == .ini && lineStart && (u == 0x23 || u == 0x3B)) {
                var j = i
                while j < units.count && units[j] != 0x0A { j += 1 }
                spans.append(SyntaxSpan(i..<j, .comment)); i = j; continue
            }
            if isMarkup && at(Array("<!--".utf16), i) {
                var j = i + 4
                while j < units.count && !at(Array("-->".utf16), j) { j += 1 }
                j = min(units.count, j + 3)
                spans.append(SyntaxSpan(i..<j, .comment)); i = j; continue
            }
            // Section headers in TOML / INI: [section]
            if lineStart, u == 0x5B, language == .toml || language == .ini {
                var j = i
                while j < units.count && units[j] != 0x0A && units[j] != 0x5D { j += 1 }
                if j < units.count && units[j] == 0x5D { j += 1 }
                spans.append(SyntaxSpan(i..<j, .heading)); i = j; lineStart = false; continue
            }
            if u == 0x22 || u == 0x27 || u == 0x60 { // " ' `
                var j = i + 1
                while j < units.count && units[j] != u && units[j] != 0x0A {
                    if units[j] == 0x5C { j += 1 } // backslash escape
                    j += 1
                }
                if j < units.count && units[j] == u { j += 1 }
                j = min(units.count, j)
                spans.append(SyntaxSpan(i..<j, .string)); i = j; lineStart = false; continue
            }
            if isDigit(u), i == 0 || !isIdent(units[i - 1]) {
                var j = i
                while j < units.count && (isIdent(units[j]) || units[j] == 0x2E) { j += 1 }
                spans.append(SyntaxSpan(i..<j, .number)); i = j; lineStart = false; continue
            }
            if isIdent(u) {
                var j = i
                while j < units.count && isIdent(units[j]) { j += 1 }
                let word = String(decoding: units[i..<j], as: UTF16.self)
                if keywords.contains(word) { spans.append(SyntaxSpan(i..<j, .keyword)) }
                // `key =` / `key:` at line start in config files.
                else if lineStart, language == .toml || language == .ini || language == .yaml {
                    spans.append(SyntaxSpan(i..<j, .property))
                }
                i = j; lineStart = false; continue
            }
            if u != 0x20 && u != 0x09 { lineStart = false }
            i += 1
        }
        return spans.filter { $0.range.upperBound > lower }
    }
}
