/// The raw HTML a Markdown file holds, made safe for the preview: its
/// markup stays (`<details>`, `<kbd>`, `<img width>`, `<div align>`), but
/// nothing in it can restyle the page, lay something over it, send a form
/// or change where links go. Much like GitHub shows a README.
///
/// - `<style>` and `<script>` go with what's inside them.
/// - The tags of `<meta>`, `<base>`, `<link>`, forms and their controls,
///   frames, plug-ins and dialogs go; what's between them stays.
/// - `style`, event handler (`on…`), `formaction` and `popover…`
///   attributes go from every tag.
///
/// Every `<` that starts a tag for the browser is read here as a tag, the
/// way the HTML tokenizer reads it (names, quoted and unquoted attribute
/// values); a tag that doesn't end (`<div title="…` up to the end of the
/// block) is shown as text, so it can't run on into the markup after it.
/// The page's policy (`MarkdownPage.shell`) also blocks forms, `<base>`
/// and scripts.
enum RawHTML {
    /// Dropped with everything in them, up to their end tag.
    static let droppedElements: Set<String> = ["style", "script"]
    /// Dropped tags; what's between a start and end tag stays.
    static let droppedTags: Set<String> = [
        "meta", "base", "link",
        "form", "input", "button", "textarea", "select", "option", "optgroup", "datalist",
        "iframe", "frame", "frameset", "object", "embed", "applet", "portal",
        "dialog", "plaintext",
    ]
    /// Dropped attributes, besides every `on…` one.
    static let droppedAttributes: Set<String> = [
        "style", "formaction", "popover", "popovertarget", "popovertargetaction", "http-equiv",
    ]

    static func sanitize(_ html: String) -> String {
        let bytes = Array(html.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "<"), startsTag(bytes, at: i) else {
                out.append(bytes[i])
                i += 1
                continue
            }
            guard let tag = Tag(bytes, at: i) else {
                // Doesn't end: text, not the start of a tag.
                out.append(contentsOf: Array("&lt;".utf8))
                i += 1
                continue
            }
            if droppedElements.contains(tag.name) {
                i = tag.isEnd ? tag.end : endOfElement(tag.name, in: bytes, from: tag.end)
                continue
            }
            i = tag.end
            if droppedTags.contains(tag.name) { continue }
            out.append(UInt8(ascii: "<"))
            if tag.isEnd { out.append(UInt8(ascii: "/")) }
            out.append(contentsOf: bytes[tag.nameRange])
            for attribute in tag.attributes where keeps(attribute.name) {
                out.append(UInt8(ascii: " "))
                out.append(contentsOf: bytes[attribute.range])
            }
            // (After a space: `<img src=a/>` would make the value `a/`.)
            if tag.selfClosing { out.append(contentsOf: Array(" /".utf8)) }
            out.append(UInt8(ascii: ">"))
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func keeps(_ attribute: String) -> Bool {
        !droppedAttributes.contains(attribute) && !attribute.hasPrefix("on")
    }

    /// `<` followed by a letter, or `</` and a letter: a start or end tag
    /// to the browser. (Anything else after `<` is text or a comment.)
    private static func startsTag(_ bytes: [UInt8], at i: Int) -> Bool {
        var j = i + 1
        if j < bytes.count, bytes[j] == UInt8(ascii: "/") { j += 1 }
        return j < bytes.count && isLetter(bytes[j])
    }

    /// Just past the end tag of the element `name` whose content starts at
    /// `start` (`</style …>`), or the end of the text when it has none.
    private static func endOfElement(_ name: String, in bytes: [UInt8], from start: Int) -> Int {
        let closing = Array("</\(name)".utf8)
        var i = start
        while i + closing.count <= bytes.count {
            if bytes[i] == UInt8(ascii: "<"),
               zip(bytes[i..<(i + closing.count)], closing).allSatisfy({ pair in lower(pair.0) == pair.1 }) {
                var j = i + closing.count
                while j < bytes.count, bytes[j] != UInt8(ascii: ">") { j += 1 }
                return min(j + 1, bytes.count)
            }
            i += 1
        }
        return bytes.count
    }

    /// A start or end tag, read the way the HTML tokenizer reads it.
    struct Tag {
        var isEnd = false
        var name = ""
        var nameRange: Range<Int> = 0..<0
        var attributes: [(name: String, range: Range<Int>)] = []
        var selfClosing = false
        /// Just past its `>`.
        var end = 0

        /// The tag at `start` (a `<`), or nil if it doesn't end.
        init?(_ bytes: [UInt8], at start: Int) {
            var i = start + 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "/") {
                isEnd = true
                i += 1
            }
            let nameStart = i
            while i < bytes.count, !RawHTML.isSpace(bytes[i]), bytes[i] != UInt8(ascii: "/"), bytes[i] != UInt8(ascii: ">") { i += 1 }
            nameRange = nameStart..<i
            name = RawHTML.lowercased(bytes[nameRange])
            while true {
                // Before an attribute: spaces and stray slashes.
                selfClosing = false
                while i < bytes.count, RawHTML.isSpace(bytes[i]) || bytes[i] == UInt8(ascii: "/") {
                    selfClosing = bytes[i] == UInt8(ascii: "/")
                    i += 1
                }
                guard i < bytes.count else { return nil }
                if bytes[i] == UInt8(ascii: ">") {
                    end = i + 1
                    return
                }
                selfClosing = false
                // Its name: the first character whatever it is (even `=`).
                let attributeStart = i
                i += 1
                while i < bytes.count, !RawHTML.isSpace(bytes[i]), bytes[i] != UInt8(ascii: "/"),
                      bytes[i] != UInt8(ascii: ">"), bytes[i] != UInt8(ascii: "=") { i += 1 }
                let attributeName = RawHTML.lowercased(bytes[attributeStart..<i])
                var attributeEnd = i
                // Its value, if it has one.
                var j = i
                while j < bytes.count, RawHTML.isSpace(bytes[j]) { j += 1 }
                if j < bytes.count, bytes[j] == UInt8(ascii: "=") {
                    j += 1
                    while j < bytes.count, RawHTML.isSpace(bytes[j]) { j += 1 }
                    guard j < bytes.count else { return nil }
                    let quote = bytes[j]
                    if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                        j += 1
                        while j < bytes.count, bytes[j] != quote { j += 1 }
                        guard j < bytes.count else { return nil }
                        j += 1
                    } else {
                        while j < bytes.count, !RawHTML.isSpace(bytes[j]), bytes[j] != UInt8(ascii: ">") { j += 1 }
                    }
                    i = j
                    attributeEnd = j
                }
                attributes.append((name: attributeName, range: attributeStart..<attributeEnd))
            }
        }
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(lower(byte))
    }

    private static func lower(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }

    private static func lowercased(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.map(lower), as: UTF8.self)
    }
}
