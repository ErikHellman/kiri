#if os(macOS)
import Foundation
import KiriKit
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSharp
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterKotlin
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML
import TreeSitterZig

// Tree-sitter highlighting, independent of AppKit: parse (incrementally, on
// any one thread at a time) and turn the highlight query's captures in a
// range into `SyntaxSpan`s. Offsets are UTF-16 units, the parser reads
// UTF-16LE, so a tree-sitter byte offset is always 2 × the UTF-16 offset.

/// A Tree-sitter grammar and its highlight query.
public final class SyntaxGrammar: @unchecked Sendable {
    public let id: String
    let language: SwiftTreeSitter.Language
    let highlights: Query
    /// Markdown: the inline grammar, parsed inside `inline` nodes.
    let inline: SyntaxGrammar?
    let inlineNodes: Query?

    init(id: String, language: OpaquePointer, inline: SyntaxGrammar? = nil) throws {
        self.id = id
        self.language = SwiftTreeSitter.Language(language)
        guard let url = Bundle.module.url(forResource: "highlights", withExtension: "scm",
                                          subdirectory: "Queries/\(id)") else {
            throw CocoaError(.fileNoSuchFile)
        }
        highlights = try Query(language: self.language, data: Data(contentsOf: url))
        self.inline = inline
        inlineNodes = inline == nil ? nil : try Query(language: self.language, data: Data("(inline) @inline".utf8))
    }

    /// Language ids (`KiriKit.Language.id`) with a bundled grammar.
    public static let supportedIDs = ["json", "yaml", "markdown", "javascript", "typescript", "tsx", "python",
                                      "bash", "html", "css", "swift", "go", "rust", "java", "kotlin", "csharp", "c",
                                      "cpp", "zig"]

    nonisolated(unsafe) private static var cache: [String: SyntaxGrammar] = [:]
    private static let lock = NSLock()

    /// The grammar for a language, loaded once; nil when Kiri has none.
    public static func forLanguage(id: String) -> SyntaxGrammar? {
        lock.withLock {
            if let g = cache[id] { return g }
            guard let g = try? load(id) else { return nil }
            cache[id] = g
            return g
        }
    }

    static func load(_ id: String) throws -> SyntaxGrammar? {
        switch id {
        case "json": try SyntaxGrammar(id: id, language: tree_sitter_json())
        case "yaml": try SyntaxGrammar(id: id, language: tree_sitter_yaml())
        case "markdown":
            try SyntaxGrammar(id: id, language: tree_sitter_markdown(),
                              inline: SyntaxGrammar(id: "markdown_inline", language: tree_sitter_markdown_inline()))
        case "javascript": try SyntaxGrammar(id: id, language: tree_sitter_javascript())
        case "typescript": try SyntaxGrammar(id: id, language: tree_sitter_typescript())
        case "tsx": try SyntaxGrammar(id: id, language: tree_sitter_tsx())
        case "python": try SyntaxGrammar(id: id, language: tree_sitter_python())
        case "bash": try SyntaxGrammar(id: id, language: tree_sitter_bash())
        case "html": try SyntaxGrammar(id: id, language: tree_sitter_html())
        case "css": try SyntaxGrammar(id: id, language: tree_sitter_css())
        case "swift": try SyntaxGrammar(id: id, language: tree_sitter_swift())
        case "go": try SyntaxGrammar(id: id, language: tree_sitter_go())
        case "rust": try SyntaxGrammar(id: id, language: tree_sitter_rust())
        case "java": try SyntaxGrammar(id: id, language: tree_sitter_java())
        case "kotlin": try SyntaxGrammar(id: id, language: tree_sitter_kotlin())
        case "csharp": try SyntaxGrammar(id: id, language: tree_sitter_c_sharp())
        case "c": try SyntaxGrammar(id: id, language: tree_sitter_c())
        case "cpp": try SyntaxGrammar(id: id, language: tree_sitter_cpp())
        case "zig": try SyntaxGrammar(id: id, language: tree_sitter_zig())
        default: nil
        }
    }
}

/// One text edit, in UTF-16 offsets and the lines before and after it.
public struct SyntaxEdit: Sendable {
    let input: InputEdit

    /// `old` (UTF-16 range in the old text) was replaced by `newLength`
    /// units. `before` and `after` are the line indexes of the two texts.
    public init(old: Range<Int>, newLength: Int, before: LineIndex, after: LineIndex) {
        func point(_ offset: Int, _ index: LineIndex) -> Point {
            let line = index.line(at: offset)
            return Point(row: UInt32(line), column: UInt32((offset - index.starts[line]) * 2))
        }
        let newEnd = old.lowerBound + newLength
        input = InputEdit(startByte: old.lowerBound * 2, oldEndByte: old.upperBound * 2, newEndByte: newEnd * 2,
                          startPoint: point(old.lowerBound, before), oldEndPoint: point(old.upperBound, before),
                          newEndPoint: point(newEnd, after))
    }
}

/// A parsed text: the tree and the exact text it was parsed from.
public struct SyntaxSnapshot: @unchecked Sendable {
    public let grammar: SyntaxGrammar
    let tree: Tree
    /// Immutable copy of the text this tree describes.
    public let text: NSString

    /// Highlighted spans that intersect `range` (UTF-16), innermost last.
    public func spans(in range: Range<Int>) -> [SyntaxSpan] {
        let clamped = max(0, range.lowerBound)..<min(text.length, range.upperBound)
        guard !clamped.isEmpty, let root = tree.rootNode else { return [] }
        var captures = Self.captures(of: grammar.highlights, root: root, tree: tree, text: text, range: clamped)
        if let inline = grammar.inline, let nodes = grammar.inlineNodes {
            captures += inlineCaptures(inline, nodes: nodes, root: root, range: clamped)
        }
        // Bigger ranges first so nested captures (an escape in a string) win;
        // for the same range the later pattern wins.
        captures.sort { a, b in
            a.range.count != b.range.count ? a.range.count > b.range.count : a.order < b.order
        }
        return captures.map { SyntaxSpan($0.range, $0.kind) }
    }

    private struct Capture {
        let range: Range<Int>
        let kind: SyntaxKind
        let order: Int
    }

    private static func captures(of query: Query, root: Node, tree: Tree, text: NSString,
                                 range: Range<Int>, orderBase: Int = 0) -> [Capture] {
        let cursor = query.execute(node: root, in: tree)
        cursor.setRange(NSRange(location: range.lowerBound, length: range.count))
        let context = Predicate.Context(textProvider: { r, _ in
            r.location >= 0 && NSMaxRange(r) <= text.length ? text.substring(with: r) : nil
        })
        var out: [Capture] = []
        for match in cursor.resolve(with: context) {
            for capture in match.captures {
                guard let name = capture.name, let kind = SyntaxKind(capture: name) else { continue }
                let r = capture.range
                guard r.length > 0 else { continue }
                out.append(Capture(range: r.location..<NSMaxRange(r), kind: kind,
                                   order: orderBase + capture.patternIndex))
            }
        }
        return out
    }

    /// Markdown's inline grammar (emphasis, code spans, links) inside the
    /// block grammar's `inline` nodes that intersect `range`.
    private func inlineCaptures(_ inline: SyntaxGrammar, nodes: Query, root: Node, range: Range<Int>) -> [Capture] {
        let cursor = nodes.execute(node: root, in: tree)
        cursor.setRange(NSRange(location: range.lowerBound, length: range.count))
        var ranges: [TSRange] = []
        while let c = cursor.nextCapture() { ranges.append(c.node.tsRange) }
        guard !ranges.isEmpty else { return [] }
        ranges.sort { $0.bytes.lowerBound < $1.bytes.lowerBound }
        let parser = Parser()
        guard (try? parser.setLanguage(inline.language)) != nil else { return [] }
        parser.includedRanges = ranges
        guard let inlineTree = parser.parse(tree: nil as Tree?, readBlock: SyntaxParser.reader(text))?.copy(),
              let inlineRoot = inlineTree.rootNode else { return [] }
        return Self.captures(of: inline.highlights, root: inlineRoot, tree: inlineTree, text: text, range: range,
                             orderBase: 100_000)
    }
}

/// Incremental parsing for one document. Not thread-safe: use it from one
/// queue at a time.
public final class SyntaxParser: @unchecked Sendable {
    public let grammar: SyntaxGrammar
    private let parser = Parser()
    private var tree: MutableTree?

    public init?(grammar: SyntaxGrammar) {
        self.grammar = grammar
        guard (try? parser.setLanguage(grammar.language)) != nil else { return nil }
        // Never hang on pathological input.
        parser.timeout = 2
    }

    /// Applies `edits` (in order) to the previous tree and parses `text`,
    /// which must be an immutable string (pass a copy).
    public func parse(_ text: NSString, edits: [SyntaxEdit] = []) -> SyntaxSnapshot? {
        if let tree { for e in edits { tree.edit(e.input) } }
        guard let new = parser.parse(tree: tree, readBlock: Self.reader(text)) else {
            tree = nil
            return nil
        }
        tree = new
        guard let copy = new.copy() else { return nil }
        return SyntaxSnapshot(grammar: grammar, tree: copy, text: text)
    }

    /// Feeds the parser UTF-16LE chunks straight from the NSString (random
    /// access, no Swift String index walking).
    static func reader(_ text: NSString) -> Parser.ReadBlock {
        let length = text.length
        return { byteOffset, _ in
            let start = byteOffset / 2
            guard start < length else { return nil }
            let count = min(4096, length - start)
            var buffer = [unichar](repeating: 0, count: count)
            text.getCharacters(&buffer, range: NSRange(location: start, length: count))
            return buffer.withUnsafeBytes { Data($0) }
        }
    }
}
#endif
