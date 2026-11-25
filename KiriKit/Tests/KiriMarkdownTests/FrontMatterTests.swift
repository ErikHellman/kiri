import Testing
@testable import KiriMarkdown

@Suite struct FrontMatterTests {
    typealias E = FrontMatter.Entry

    @Test func yamlScalarsListsAndMaps() throws {
        let text = """
            ---
            title: "Kiri: a quick editor"
            date: 2026-11-25
            draft: false # not yet
            tags: [release, "mac os", 'it''s']
            authors:
              - Erik
              - name: Claude
                role: helper
            seo:
              description: >
                Folded
                into one.
              keywords:
              - a
              - b
            notes: |
              Line one
              Line two
            empty:
            ---
            # Body
            """
        let (fm, body) = FrontMatter.split(text)
        let front = try #require(fm)
        #expect(front.format == .yaml)
        #expect(front.lineCount == 21)
        #expect(front.entries == [
            E("title", .scalar("Kiri: a quick editor")),
            E("date", .scalar("2026-11-25")),
            E("draft", .scalar("false")),
            E("tags", .list([.scalar("release"), .scalar("mac os"), .scalar("it's")])),
            E("authors", .list([.scalar("Erik"), .map([E("name", .scalar("Claude")), E("role", .scalar("helper"))])])),
            E("seo", .map([
                E("description", .scalar("Folded into one.\n")),
                E("keywords", .list([.scalar("a"), .scalar("b")])),
            ])),
            E("notes", .scalar("Line one\nLine two\n")),
            E("empty", .scalar("")),
        ])
        // The block's lines are left empty, so the body keeps its line numbers.
        let lines = body.components(separatedBy: "\n")
        #expect(lines.count == 22)
        #expect(lines[0..<21].allSatisfy { $0.isEmpty })
        #expect(lines[21] == "# Body")
    }

    @Test func yamlItDoesntKnowIsShownRaw() throws {
        let (fm, _) = FrontMatter.split("---\nbase: &b\n  a: 1\nother: *b\n---\ntext\n")
        let front = try #require(fm)
        #expect(front.entries == nil)
        #expect(front.raw == "base: &b\n  a: 1\nother: *b")
    }

    @Test func onlyAtTheHeadAndClosed() {
        #expect(FrontMatter.split("# Title\n---\na: b\n---\n").frontMatter == nil)
        #expect(FrontMatter.split("---\na: b\nno end\n").frontMatter == nil)
        // A rule right after a rule isn't metadata.
        #expect(FrontMatter.split("---\n---\n").frontMatter == nil)
        #expect(FrontMatter.split("---\r\ntitle: CRLF\r\n---\r\nbody").frontMatter?.entries == [E("title", .scalar("CRLF"))])
        #expect(FrontMatter.split("---\ntitle: dots\n...\nbody").frontMatter?.entries == [E("title", .scalar("dots"))])
    }

    @Test func toml() throws {
        let text = """
            +++
            title = "Hugo post"
            draft = true
            tags = ["a", "b"]
            [params]
            author = 'Erik'
            [params.social]
            site = "https://hellsoft.se" # home
            +++
            """
        let front = try #require(FrontMatter.split(text).frontMatter)
        #expect(front.format == .toml)
        #expect(front.entries == [
            E("title", .scalar("Hugo post")),
            E("draft", .scalar("true")),
            E("tags", .list([.scalar("a"), .scalar("b")])),
            E("params", .map([
                E("author", .scalar("Erik")),
                E("social", .map([E("site", .scalar("https://hellsoft.se"))])),
            ])),
        ])
    }
}
