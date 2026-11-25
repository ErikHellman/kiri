import Foundation
import KiriKit
import Markdown

/// A Markdown file as the preview shows it: its front matter, and its
/// text as HTML for the preview's page (`MarkdownPage`).
public struct MarkdownRendering: Sendable, Equatable {
    public let frontMatter: FrontMatter?
    /// The front matter's table (if any) and the text, as HTML.
    public let html: String
    /// It has ```` ```mermaid ```` diagrams, which the page draws once
    /// Mermaid has loaded.
    public let hasMermaid: Bool
}

/// Colors a code block: the spans of its text (UTF-16 offsets) for a
/// language named by the fence's info string, or nil to leave it plain.
/// Called off the main thread.
public typealias CodeHighlighter = @Sendable (_ code: String, _ language: Language) -> [SyntaxSpan]?

/// Markdown to HTML: CommonMark with GitHub's tables, task lists and
/// strikethrough (cmark-gfm), GitHub's alerts (`> [!NOTE]`), and
/// ```` ```mermaid ```` blocks left for the page's Mermaid to draw. Raw
/// HTML in the file goes through as it is: the page runs none of the
/// file's scripts (`MarkdownPage`).
///
/// Every block says which line of the file it starts on (`data-line`), so
/// switching between the text and the preview keeps the same place.
public enum MarkdownHTML {
    public static func render(_ text: String, highlight: CodeHighlighter? = nil) -> MarkdownRendering {
        let (frontMatter, body) = FrontMatter.split(text)
        let document = Document(parsing: body, options: [.disableSmartOpts])
        var walker = HTMLWalker(highlight: highlight)
        walker.visit(document)
        var html = ""
        if let frontMatter { html += FrontMatterHTML.table(frontMatter) }
        html += walker.result
        return MarkdownRendering(frontMatter: frontMatter, html: html, hasMermaid: walker.hasMermaid)
    }

    /// `text` with `&`, `<`, `>` and quotes escaped, for HTML text and attributes.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for c in text.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// GitHub's anchor for a heading: lower case, punctuation dropped,
    /// spaces as hyphens. (`HTMLWalker` numbers repeats: `a`, `a-1`.)
    public static func slug(_ text: String) -> String {
        var out = ""
        for c in text.lowercased() {
            if c.isLetter || c.isNumber || c == "-" || c == "_" { out.append(c) }
            else if c == " " { out.append("-") }
        }
        return out
    }

    /// The language a fence's info string names (`swift`, `js`, `sh`,
    /// `c++`…), if Kiri knows it.
    public static func language(fence info: String) -> Language? {
        let name = info.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first.map { $0.lowercased() } ?? ""
        guard !name.isEmpty else { return nil }
        let aliases = ["shell": "bash", "sh": "bash", "zsh": "bash", "console": "bash", "shellsession": "bash",
                       "c++": "cpp", "objective-c": "objc", "objectivec": "objc", "golang": "go", "jsonc": "json",
                       "json5": "json", "yml": "yaml", "md": "markdown", "py": "python", "python3": "python",
                       "js": "javascript", "jsx": "javascript", "ts": "typescript", "kt": "kotlin", "cs": "csharp",
                       "c#": "csharp", "rb": "ruby", "rs": "rust", "docker": "dockerfile", "makefile": "make",
                       "html5": "html", "xhtml": "html", "svg": "xml", "plist": "xml"]
        let id = aliases[name] ?? name
        if let language = Language.with(id: id) { return language }
        return Language.all.first { $0.extensions.contains(name) || $0.name.lowercased() == name }
    }

    /// A code block's text as HTML, in spans of the Honey syntax classes
    /// (`syn-keyword`…). Later spans win where they overlap, as in the editor.
    static func highlighted(_ code: String, spans: [SyntaxSpan]) -> String {
        let units = Array(code.utf16)
        var kinds = [SyntaxKind?](repeating: nil, count: units.count)
        for span in spans {
            let lower = max(0, span.range.lowerBound), upper = min(units.count, span.range.upperBound)
            guard lower < upper else { continue }
            for i in lower..<upper { kinds[i] = span.kind }
        }
        var out = ""
        var start = 0
        while start < units.count {
            var end = start + 1
            while end < units.count, kinds[end] == kinds[start] { end += 1 }
            // Never split a surrogate pair.
            while end < units.count, UTF16.isTrailSurrogate(units[end]) { end += 1 }
            let piece = escape(String(decoding: units[start..<end], as: UTF16.self))
            if let kind = kinds[start] {
                out += "<span class=\"syn-\(kind.rawValue)\">\(piece)</span>"
            } else {
                out += piece
            }
            start = end
        }
        return out
    }
}

// MARK: Front matter

enum FrontMatterHTML {
    static func table(_ fm: FrontMatter) -> String {
        let label = fm.format == .yaml ? "YAML front matter" : "TOML front matter"
        guard let entries = fm.entries else {
            // Shown as written when it can't be read.
            return "<section class=\"front-matter raw\" data-line=\"1\" aria-label=\"\(label)\">"
                + "<pre><code>\(MarkdownHTML.escape(fm.raw))</code></pre></section>\n"
        }
        guard !entries.isEmpty else { return "" }
        return "<section class=\"front-matter\" data-line=\"1\" aria-label=\"\(label)\">\(map(entries))</section>\n"
    }

    static func map(_ entries: [FrontMatter.Entry]) -> String {
        var out = "<table><tbody>"
        for entry in entries {
            out += "<tr><th scope=\"row\">\(MarkdownHTML.escape(entry.key))</th><td>\(value(entry.value))</td></tr>"
        }
        return out + "</tbody></table>"
    }

    static func value(_ value: FrontMatter.Value) -> String {
        switch value {
        case .scalar(let text): return scalar(text)
        case .map(let entries): return entries.isEmpty ? "<span class=\"empty\">—</span>" : map(entries)
        case .list(let items):
            if items.isEmpty { return "<span class=\"empty\">—</span>" }
            // A list of words (tags, authors) is a row of chips; any other a list.
            let words = items.compactMap { item -> String? in
                if case .scalar(let s) = item, !s.contains("\n"), s.count <= 60 { return s }
                return nil
            }
            if words.count == items.count {
                return "<ul class=\"chips\">" + words.map { "<li>\(scalar($0))</li>" }.joined() + "</ul>"
            }
            return "<ol class=\"items\">" + items.map { "<li>\(self.value($0))</li>" }.joined() + "</ol>"
        }
    }

    static func scalar(_ text: String) -> String {
        if text.isEmpty { return "<span class=\"empty\">—</span>" }
        let escaped = MarkdownHTML.escape(text)
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme),
           !text.contains(" ") {
            return "<a href=\"\(escaped)\">\(escaped)</a>"
        }
        switch text.lowercased() {
        case "true", "yes": return "<span class=\"bool yes\">\(escaped)</span>"
        case "false", "no": return "<span class=\"bool no\">\(escaped)</span>"
        default: break
        }
        return text.contains("\n") ? "<span class=\"multiline\">\(escaped)</span>" : escaped
    }
}

// MARK: The walker

private struct HTMLWalker: MarkupWalker {
    let highlight: CodeHighlighter?
    var result = ""
    var hasMermaid = false
    private var inTableHead = false
    private var alignments: [Table.ColumnAlignment?] = []
    private var column = 0
    private var slugs: [String: Int] = [:]
    /// How many children of the next paragraph are its alert's `[!NOTE]`.
    private var alertSkip = 0

    init(highlight: CodeHighlighter?) { self.highlight = highlight }

    private func line(_ markup: Markup) -> String {
        guard let line = markup.range?.lowerBound.line else { return "" }
        return " data-line=\"\(line)\""
    }

    // MARK: Blocks

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        if let (kind, skip) = Self.alert(blockQuote) {
            result += "<div class=\"alert alert-\(kind)\"\(line(blockQuote))><p class=\"alert-title\">\(kind.capitalized)</p>\n"
            alertSkip = skip
            descendInto(blockQuote)
            alertSkip = 0
            result += "</div>\n"
            return
        }
        result += "<blockquote\(line(blockQuote))>\n"
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    /// GitHub's alerts: a quote whose first line is `[!NOTE]`, `[!TIP]`,
    /// `[!IMPORTANT]`, `[!WARNING]` or `[!CAUTION]`. Also how many of its
    /// first paragraph's children the marker takes (with its line break).
    static func alert(_ quote: BlockQuote) -> (kind: String, skip: Int)? {
        guard let paragraph = quote.child(at: 0) as? Paragraph else { return nil }
        var first = ""
        var count = 0
        for child in paragraph.children {
            if child is SoftBreak || child is LineBreak {
                count += 1
                break
            }
            guard let text = child as? Text else { return nil }
            first += text.string
            count += 1
        }
        let marker = first.trimmingCharacters(in: .whitespaces).lowercased()
        for kind in ["note", "tip", "important", "warning", "caution"] where marker == "[!\(kind)]" {
            return (kind, count)
        }
        return nil
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }
        let info = codeBlock.language ?? ""
        let name = info.split(separator: " ").first.map { $0.lowercased() } ?? ""
        if name == "mermaid" {
            hasMermaid = true
            result += "<figure class=\"mermaid\"\(line(codeBlock))><pre class=\"mermaid-source\">\(MarkdownHTML.escape(code))</pre></figure>\n"
            return
        }
        let language = MarkdownHTML.language(fence: info)
        let body: String
        if let language, let highlight, code.utf16.count <= 200_000, let spans = highlight(code, language) {
            body = MarkdownHTML.highlighted(code, spans: spans)
        } else {
            body = MarkdownHTML.escape(code)
        }
        let label = name.isEmpty ? "" : " data-lang=\"\(MarkdownHTML.escape(language?.name ?? name))\""
        result += "<div class=\"code\"\(line(codeBlock))\(label)><pre><code>\(body)</code></pre></div>\n"
    }

    mutating func visitHeading(_ heading: Heading) {
        var slug = MarkdownHTML.slug(heading.plainText)
        if let n = slugs[slug] {
            slugs[slug] = n + 1
            slug += "-\(n + 1)"
        } else {
            slugs[slug] = 0
        }
        result += "<h\(heading.level) id=\"\(MarkdownHTML.escape(slug))\"\(line(heading))>"
        descendInto(heading)
        result += "</h\(heading.level)>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result += "<hr\(line(thematicBreak))>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        result += html.rawHTML
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked
            result += "<li class=\"task\(checked ? " done" : "")\"\(line(listItem))>"
            result += "<span class=\"check\" role=\"checkbox\" aria-checked=\"\(checked)\"></span>"
        } else {
            result += "<li\(line(listItem))>"
        }
        descendInto(listItem)
        result += "</li>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let start = orderedList.startIndex != 1 ? " start=\"\(orderedList.startIndex)\"" : ""
        result += "<ol\(start)\(line(orderedList))>\n"
        descendInto(orderedList)
        result += "</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        let tasks = unorderedList.listItems.contains { $0.checkbox != nil }
        result += "<ul\(tasks ? " class=\"tasks\"" : "")\(line(unorderedList))>\n"
        descendInto(unorderedList)
        result += "</ul>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        // An alert's first paragraph, without its `[!NOTE]` line.
        if alertSkip > 0 {
            let skip = alertSkip
            alertSkip = 0
            guard paragraph.childCount > skip else { return }
            result += "<p\(line(paragraph))>"
            for child in paragraph.children.dropFirst(skip) { visit(child) }
            result += "</p>\n"
            return
        }
        result += "<p\(line(paragraph))>"
        descendInto(paragraph)
        result += "</p>\n"
    }

    mutating func visitTable(_ table: Table) {
        alignments = table.columnAlignments
        result += "<div class=\"table\"\(line(table))><table>\n"
        descendInto(table)
        result += "</table></div>\n"
        alignments = []
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        result += "<thead>\n<tr>\n"
        inTableHead = true
        column = 0
        descendInto(tableHead)
        inTableHead = false
        result += "</tr>\n</thead>\n"
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        guard !tableBody.isEmpty else { return }
        result += "<tbody>\n"
        descendInto(tableBody)
        result += "</tbody>\n"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        result += "<tr>\n"
        column = 0
        descendInto(tableRow)
        result += "</tr>\n"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        guard tableCell.colspan > 0, tableCell.rowspan > 0 else { return }
        let element = inTableHead ? "th" : "td"
        result += "<\(element)"
        if column < alignments.count, let alignment = alignments[column] {
            let value = switch alignment {
            case .left: "left"
            case .center: "center"
            case .right: "right"
            }
            result += " style=\"text-align: \(value)\""
        }
        column += Int(tableCell.colspan)
        if tableCell.rowspan > 1 { result += " rowspan=\"\(tableCell.rowspan)\"" }
        if tableCell.colspan > 1 { result += " colspan=\"\(tableCell.colspan)\"" }
        result += ">"
        descendInto(tableCell)
        result += "</\(element)>\n"
    }

    // MARK: Inline

    private mutating func inline(_ tag: String, _ content: Markup) {
        result += "<\(tag)>"
        descendInto(content)
        result += "</\(tag)>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += "<code>\(MarkdownHTML.escape(inlineCode.code))</code>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) { inline("em", emphasis) }
    mutating func visitStrong(_ strong: Strong) { inline("strong", strong) }
    mutating func visitStrikethrough(_ strikethrough: Strikethrough) { inline("del", strikethrough) }

    mutating func visitImage(_ image: Image) {
        result += "<img"
        if let source = image.source, !source.isEmpty, Self.allowed(source) {
            result += " src=\"\(MarkdownHTML.escape(source))\""
        }
        result += " alt=\"\(MarkdownHTML.escape(image.plainText))\""
        if let title = image.title, !title.isEmpty { result += " title=\"\(MarkdownHTML.escape(title))\"" }
        result += ">"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        result += inlineHTML.rawHTML
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br>\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "\n"
    }

    mutating func visitLink(_ link: Link) {
        result += "<a"
        if let destination = link.destination, Self.allowed(destination) {
            result += " href=\"\(MarkdownHTML.escape(destination))\""
        }
        if let title = link.title, !title.isEmpty { result += " title=\"\(MarkdownHTML.escape(title))\"" }
        result += ">"
        descendInto(link)
        result += "</a>"
    }

    mutating func visitText(_ text: Text) {
        result += MarkdownHTML.escape(text.string)
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
        if let destination = symbolLink.destination { result += "<code>\(MarkdownHTML.escape(destination))</code>" }
    }

    /// Not a `javascript:` (or `vbscript:`) link.
    static func allowed(_ destination: String) -> Bool {
        let scheme = destination.trimmingCharacters(in: .whitespaces).lowercased()
        return !scheme.hasPrefix("javascript:") && !scheme.hasPrefix("vbscript:")
    }
}
