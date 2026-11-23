#if os(macOS)
import Foundation
import KiriKit
import Testing
@testable import KiriSyntax

/// A sample per grammar and a few spans it must produce.
let samples: [(id: String, text: String, expect: [(String, SyntaxKind)])] = [
    ("swift", "import Foundation\n// hi\nstruct A { let x = 42; func f() -> String { \"s\\n\" } }\n",
     [("struct", .keyword), ("// hi", .comment), ("42", .number), ("\"", .string), ("\\n", .escape),
      ("String", .type), ("f", .function)]),
    ("json", "{\"name\": \"kiri\", \"n\": 3, \"ok\": true, \"z\": null}",
     [("\"kiri\"", .string), ("3", .number)]),
    ("yaml", "# config\nname: kiri\ncount: 3\nlist:\n  - a\n",
     [("# config", .comment), ("name", .property)]),
    ("markdown", "# Title\n\nSome *emphasis* and `code` and [link](http://x.y).\n\n```\nblock\n```\n",
     [("Title", .heading), ("`code`", .code)]),
    ("javascript", "// c\nconst x = 1;\nfunction f(a) { return `t${a}`; }\nclass K {}\n",
     [("const", .keyword), ("// c", .comment), ("1", .number), ("function", .keyword)]),
    ("typescript", "interface P { name: string }\nconst x: number = 2;\n",
     [("interface", .keyword), ("2", .number)]),
    ("tsx", "const e = <div className=\"a\">hi</div>;\n", [("const", .keyword), ("\"a\"", .string)]),
    ("python", "# c\ndef f(x):\n    return 'a' + str(1)\n",
     [("def", .keyword), ("# c", .comment), ("'a'", .string), ("1", .number)]),
    ("bash", "#!/bin/sh\n# c\nif [ -f x ]; then echo \"hi\"; fi\n",
     [("if", .keyword), ("# c", .comment), ("\"hi\"", .string)]),
    ("html", "<!-- c -->\n<div class=\"a\">hi</div>\n",
     [("div", .tag), ("class", .attribute), ("<!-- c -->", .comment)]),
    ("css", "/* c */\n.a { color: #fff; margin: 2px; }\n",
     [("/* c */", .comment), ("color", .property)]),
    ("go",
     "package main\n\nimport \"fmt\"\n\n// c\nfunc main() {\n\tx := 42\n\tfmt.Println(\"hi\\n\", x)\n}\n",
     [("func", .keyword), ("// c", .comment), ("42", .number), ("\"fmt\"", .string), ("main", .function)]),
    ("rust",
     "use std::fmt;\n// c\nfn add(a: i32) -> i32 { let s = \"x\\n\"; println!(\"{}\", s); a + 1 }\nstruct P { x: u8 }\n",
     [("fn", .keyword), ("// c", .comment), ("1", .number), ("i32", .type), ("add", .function), ("\\n", .escape), ("P", .type)]),
    ("java",
     "// c\npublic class A {\n  @Override\n  public String f(int x) { return \"s\" + 42; }\n}\n",
     [("class", .keyword), ("// c", .comment), ("42", .number), ("\"s\"", .string), ("String", .type), ("f", .function)]),
    ("kotlin",
     "// c\npackage a\n\nclass A(val x: Int) {\n  fun f(): String = \"s\" + 42\n}\n",
     [("class", .keyword), ("fun", .keyword), ("// c", .comment), ("42", .number), ("\"s\"", .string), ("String", .type), ("f", .function)]),
    ("csharp",
     "// c\nusing System;\nnamespace N {\n  class A {\n    public string F(int x) { return \"s\" + 42; }\n  }\n}\n",
     [("class", .keyword), ("// c", .comment), ("42", .number), ("\"s\"", .string), ("F", .function)]),
    ("c",
     "#include <stdio.h>\n// c\nstruct p { int x; };\nint main(void) { printf(\"hi\\n\"); return 42; }\n",
     [("#include", .keyword), ("// c", .comment), ("42", .number), ("return", .keyword), ("main", .function), ("int", .type)]),
    ("cpp",
     "#include <vector>\n// c\nnamespace n {\nclass A { public: int f() const { return 42; } };\n}\nauto s = \"x\";\n",
     [("#include", .keyword), ("class", .keyword), ("namespace", .keyword), ("// c", .comment), ("42", .number), ("\"x\"", .string), ("f", .function)]),
    ("zig",
     "const std = @import(\"std\");\n// c\npub fn main() void {\n    const x: u32 = 42;\n    _ = x;\n}\n",
     [("const", .keyword), ("fn", .keyword), ("// c", .comment), ("42", .number), ("\"std\"", .string), ("main", .function), ("u32", .type)]),
]

func text(of span: SyntaxSpan, in s: String) -> String {
    let u = Array(s.utf16)
    return String(decoding: u[span.range], as: UTF16.self)
}

@Suite struct GrammarTests {
    @Test(arguments: SyntaxGrammar.supportedIDs)
    func loadsAndHighlights(id: String) throws {
        // Throws with the query error if a highlight query doesn't compile.
        _ = try SyntaxGrammar.load(id)
        let grammar = try #require(SyntaxGrammar.forLanguage(id: id), "grammar \(id) loads (ABI + query)")
        let parser = try #require(SyntaxParser(grammar: grammar))
        let sample = try #require(samples.first { $0.id == id })
        let snapshot = try #require(parser.parse(sample.text as NSString))
        let spans = snapshot.spans(in: 0..<sample.text.utf16.count)
        #expect(!spans.isEmpty, "\(id) produces captures")
        for (fragment, kind) in sample.expect {
            // The innermost (last) span covering exactly this text decides its color.
            let match = spans.last { text(of: $0, in: sample.text) == fragment }
            if match?.kind != kind { print("SPANS \(id):", spans.map { "\(text(of: $0, in: sample.text))=\($0.kind)" }) }
            #expect(match?.kind == kind, "\(id): \(fragment) is \(kind), got \(String(describing: match?.kind))")
        }
    }

    @Test func everyLanguageIDExists() {
        for id in SyntaxGrammar.supportedIDs {
            #expect(Language.with(id: id) != nil, "\(id) is a KiriKit.Language")
        }
        #expect(SyntaxGrammar.forLanguage(id: "toml") == nil)
    }
}

@Suite struct IncrementalTests {
    /// Edits applied to the tree give the same highlights as a fresh parse.
    @Test func editMatchesFreshParse() throws {
        let grammar = try #require(SyntaxGrammar.forLanguage(id: "swift"))
        let parser = try #require(SyntaxParser(grammar: grammar))
        var text = "let a = 1\nlet b = \"two\"\n"
        _ = parser.parse(text as NSString)
        let edits: [(Range<Int>, String)] = [(4..<5, "alpha"), (0..<0, "// top\n"), (12..<16, "var"), (0..<7, "")]
        for (range, insert) in edits {
            let before = LineIndex(text)
            let ns = text as NSString
            text = ns.replacingCharacters(in: NSRange(location: range.lowerBound, length: range.count), with: insert)
            let edit = SyntaxEdit(old: range, newLength: insert.utf16.count, before: before, after: LineIndex(text))
            let incremental = try #require(parser.parse(text as NSString, edits: [edit]))
            let fresh = try #require(SyntaxParser(grammar: grammar)?.parse(text as NSString))
            let all = 0..<text.utf16.count
            #expect(incremental.spans(in: all) == fresh.spans(in: all), "after inserting \(insert)")
        }
    }

    @Test func rangeLimitsSpans() throws {
        let grammar = try #require(SyntaxGrammar.forLanguage(id: "json"))
        let text = "[" + (0..<1000).map { "\"item\($0)\"" }.joined(separator: ",\n") + "]"
        let snap = try #require(SyntaxParser(grammar: grammar)?.parse(text as NSString))
        let spans = snap.spans(in: 0..<200)
        #expect(!spans.isEmpty && spans.count < 40)
    }
}

/// One test at a time: run side by side on a busy CI runner, the full
/// parses (about 1.3 s each) slowed the 4 MB JSON one past the parser's
/// 2 s timeout (`SyntaxParser`), and it came back empty.
@Suite(.serialized) struct PerformanceTests {
    /// The biggest new grammars (C++, Kotlin, C#): one screen of highlights
    /// in a ~1.5 MB file stays cheap, as does an incremental reparse.
    @Test(arguments: [
        ("cpp", "namespace n { class A { public: int f(int x) const { return x * 42; } }; } // row\n"),
        // fwcd's Kotlin grammar wants a newline before a closing brace.
        ("kotlin", "class A(val x: Int) {\n    fun f(): String = \"s$x\" + 42 // row\n}\n"),
        ("csharp", "class A { public string F(int x) { return \"s\" + x + 42; } } // row\n"),
    ])
    func largeCodeFile(id: String, row: String) throws {
        let grammar = try #require(SyntaxGrammar.forLanguage(id: id))
        let text = String(repeating: row, count: 20_000) as NSString
        let parser = try #require(SyntaxParser(grammar: grammar))
        let clock = ContinuousClock()
        var snap: SyntaxSnapshot?
        let parse = clock.measure { snap = parser.parse(text) }
        let s = try #require(snap)
        let mid = text.length / 2
        var spans: [SyntaxSpan] = []
        let visible = clock.measure { spans = s.spans(in: mid..<(mid + 6000)) }
        let before = LineIndex(text as String)
        let edited = text.replacingCharacters(in: NSRange(location: mid, length: 0), with: "1") as NSString
        let edit = SyntaxEdit(old: mid..<mid, newLength: 1, before: before, after: LineIndex(edited as String))
        let reparse = clock.measure { _ = parser.parse(edited, edits: [edit]) }
        print("PERF \(id) \(text.length / 1024) KB: parse \(parse), visible spans \(visible), incremental \(reparse)")
        #expect(!spans.isEmpty)
        #expect(visible < .milliseconds(50))
        #expect(reparse < .milliseconds(200))
    }

    /// A ~4 MB JSON file: full parse in the background is fine, but one
    /// screen of highlights must be cheap enough for every keystroke.
    @Test func largeFile() throws {
        let grammar = try #require(SyntaxGrammar.forLanguage(id: "json"))
        let row = "{\"id\": 12345, \"name\": \"Kiri editor row\", \"tags\": [\"a\", \"b\"], \"ok\": true},\n"
        let text = "[\n" + String(repeating: row, count: 50_000) + "{}]\n"
        // The full parse of 4 MB takes about 2 s on a busy CI runner, right
        // at the app's timeout; this test measures what comes after it.
        let parser = try #require(SyntaxParser(grammar: grammar, timeout: 10))
        let clock = ContinuousClock()
        var snap: SyntaxSnapshot?
        let parse = clock.measure { snap = parser.parse(text as NSString) }
        let s = try #require(snap)
        let mid = text.utf16.count / 2
        let visible = clock.measure { _ = s.spans(in: mid..<(mid + 6000)) }
        // Small edit in the middle, incremental reparse.
        let before = LineIndex(text)
        let ns = text as NSString
        let edited = ns.replacingCharacters(in: NSRange(location: mid, length: 0), with: "1") as NSString
        let edit = SyntaxEdit(old: mid..<mid, newLength: 1, before: before, after: LineIndex(edited as String))
        let reparse = clock.measure { _ = parser.parse(edited, edits: [edit]) }
        print("PERF json \(text.utf8.count / 1024) KB: parse \(parse), visible spans \(visible), incremental \(reparse)")
        #expect(visible < .milliseconds(50))
        #expect(reparse < .milliseconds(200))
    }
}
#endif
