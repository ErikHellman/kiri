import Testing
@testable import KiriKit

/// Toggle Comment (⌘/) on whole lines.
struct CommentToggleTests {
    let slashes = CommentSyntax.line("//")
    let html = CommentSyntax.block(open: "<!--", close: "-->")

    func toggled(_ text: String, _ syntax: CommentSyntax) -> String? {
        CommentToggle.toggle(text, syntax: syntax)?.text
    }

    @Test func commentsAndUncommentsOneLine() {
        #expect(toggled("let x = 1\n", slashes) == "// let x = 1\n")
        #expect(toggled("// let x = 1\n", slashes) == "let x = 1\n")
        // A marker written without its space comes off too.
        #expect(toggled("//let x = 1\n", slashes) == "let x = 1\n")
        // Only the one space that came with the marker goes.
        #expect(toggled("//   let x = 1\n", slashes) == "  let x = 1\n")
    }

    @Test func theMarkerGoesAtTheLeastIndentation() {
        let code = "    if ok {\n        run()\n    }\n"
        let commented = "    // if ok {\n    //     run()\n    // }\n"
        #expect(toggled(code, slashes) == commented)
        #expect(toggled(commented, slashes) == code)
    }

    @Test func blankLinesAreLeftAlone() {
        let code = "  a\n\n   \n  b\n"
        #expect(toggled(code, slashes) == "  // a\n\n   \n  // b\n")
        #expect(toggled("  // a\n\n   \n  // b\n", slashes) == code)
        // Nothing but blank lines: nothing to do.
        #expect(toggled("\n   \n", slashes) == nil)
    }

    @Test func aSingleBlankLineGetsAMarkerToTypeAfter() {
        #expect(CommentToggle.toggle("", syntax: slashes) == .init(text: "// ", selection: 3..<3))
        #expect(CommentToggle.toggle("    \n", syntax: .line("#"), selection: 4..<4) == .init(text: "    # \n", selection: 6..<6))
    }

    @Test func aBlockWithSomeLinesCommentedIsCommentedAgain() {
        // Not every line is commented, so every line gets a marker: the
        // toggle back then gives exactly what was there.
        let mixed = "// a\nb\n"
        #expect(toggled(mixed, slashes) == "// // a\n// b\n")
        #expect(toggled("// // a\n// b\n", slashes) == mixed)
    }

    @Test func tabsAndMixedIndentation() {
        #expect(toggled("\tone\n\t\ttwo\n", .line("#")) == "\t# one\n\t# \ttwo\n")
        #expect(toggled("\t# one\n\t# \ttwo\n", .line("#")) == "\tone\n\t\ttwo\n")
        // A tab and spaces share no indentation: the marker goes first.
        #expect(toggled("\tone\n    two\n", .line("#")) == "# \tone\n#     two\n")
    }

    @Test func crlfLineEndingsStay() {
        #expect(toggled("a\r\n  b\r\n", slashes) == "// a\r\n//   b\r\n")
        #expect(toggled("// a\r\n//   b\r\n", slashes) == "a\r\n  b\r\n")
        // The closing marker goes before the line break, not into it.
        #expect(toggled("<p>\r\n\r\n</p>\r\n", html) == "<!-- <p> -->\r\n\r\n<!-- </p> -->\r\n")
        #expect(toggled("<!-- <p> -->\r\n\r\n<!-- </p> -->\r\n", html) == "<p>\r\n\r\n</p>\r\n")
    }

    @Test func theLastLineWithoutALineBreak() {
        #expect(toggled("a\nb", slashes) == "// a\n// b")
        #expect(toggled("// a\n// b", slashes) == "a\nb")
        #expect(toggled("b", html) == "<!-- b -->")
    }

    @Test func blockPairsWrapEachLine() {
        let css = CommentSyntax.block(open: "/*", close: "*/")
        let rules = "  a { color: red; }\n  b { }\n"
        let commented = "  /* a { color: red; } */\n  /* b { } */\n"
        #expect(toggled(rules, css) == commented)
        #expect(toggled(commented, css) == rules)
        // Written tight, or with spaces after it on the line.
        #expect(toggled("/*a*/  \n", css) == "a  \n")
        // An opening marker alone is not a commented line.
        #expect(toggled("<!-- a\n", html) == "<!-- <!-- a -->\n")
        #expect(toggled("<!---->\n", html) == "\n")
    }

    @Test func otherMarkers() {
        #expect(toggled("select 1;\n", .line("--")) == "-- select 1;\n")
        #expect(toggled("-- select 1;\n", .line("--")) == "select 1;\n")
        #expect(toggled("(car x)\n", .line(";")) == "; (car x)\n")
        #expect(toggled("\\item one\n", .line("%")) == "% \\item one\n")
    }

    @Test func theSelectionStaysOnItsText() {
        // "run()" selected on the second line.
        let code = "    if ok {\n        run()\n"
        let result = CommentToggle.toggle(code, syntax: slashes, selection: 20..<25)
        #expect(result?.selection == 26..<31)
        let u = Array(result!.text.utf16)
        #expect(String(decoding: u[result!.selection], as: UTF16.self) == "run()")
        // And back.
        #expect(CommentToggle.toggle(result!.text, syntax: slashes, selection: result!.selection)?.selection == 20..<25)

        // A selection from the first character keeps that character first.
        #expect(CommentToggle.toggle("abc\n", syntax: slashes, selection: 0..<3)?.selection == 3..<6)
        // A caret in the indentation stays there; one in the text moves with it.
        #expect(CommentToggle.toggle("    abc\n", syntax: slashes, selection: 2..<2)?.selection == 2..<2)
        #expect(CommentToggle.toggle("    abc\n", syntax: slashes, selection: 6..<6)?.selection == 9..<9)
        // A caret inside a marker that comes off lands where the marker was.
        #expect(CommentToggle.toggle("  // abc\n", syntax: slashes, selection: 3..<3)?.selection == 2..<2)
        // Whole lines selected stay whole lines.
        #expect(CommentToggle.toggle("a\nb\n", syntax: slashes, selection: 0..<4)?.selection == 3..<10)
        // The caret at the end of a line stays inside a block pair.
        #expect(CommentToggle.toggle("abc", syntax: html, selection: 3..<3) == .init(text: "<!-- abc -->", selection: 8..<8))
        // Characters outside the Basic Multilingual Plane count as two.
        #expect(CommentToggle.toggle("🙂x\n", syntax: slashes, selection: 2..<3)?.selection == 5..<6)
    }

    @Test func languagesSayHowTheyComment() {
        #expect(Language.swift.comment == .line("//"))
        #expect(Language.python.comment == .line("#"))
        #expect(Language.sql.comment == .line("--"))
        #expect(Language.html.comment == .block(open: "<!--", close: "-->"))
        #expect(Language.xml.comment == .block(open: "<!--", close: "-->"))
        #expect(Language.markdown.comment == .block(open: "<!--", close: "-->"))
        #expect(Language.css.comment == .block(open: "/*", close: "*/"))
        // No comments in these: the menu item is off.
        #expect(Language.plainText.comment == nil)
        #expect(Language.json.comment == nil)
        #expect(Language.csv.comment == nil)
        // JSON keeps its marker for the highlighter all the same.
        #expect(Language.json.lineComment == "//")
        // Every other language toggles with the marker it is highlighted by.
        for language in Language.all where language.lineComment != nil && language != .json {
            #expect(language.comment == .line(language.lineComment!), "\(language.id)")
        }
    }
}
