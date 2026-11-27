import Foundation
import KiriKit
import Testing
@testable import KiriMarkdown

@Suite struct MarkdownHTMLTests {
    @Test func svgShowsAsAnImage() {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>"
        let html = MarkdownPage.svgHTML(svg)
        // As an image (no script of it runs), with the file's bytes as they are.
        #expect(html.hasPrefix("<figure class=\"svg-view\" data-line=\"1\"><img src=\"data:image/svg+xml;base64,"))
        #expect(html.contains(Data(svg.utf8).base64EncodedString()))
        #expect(!html.contains("<script"))
    }

    @Test func blocksSayTheirLine() {
        let html = MarkdownHTML.render("# Title\n\nSome *text* and `code`.\n\n- one\n- two\n").html
        #expect(html.contains("<h1 id=\"title\" data-line=\"1\">Title</h1>"))
        #expect(html.contains("<p data-line=\"3\">Some <em>text</em> and <code>code</code>.</p>"))
        #expect(html.contains("<ul data-line=\"5\">"))
        #expect(html.contains("<li data-line=\"6\">"))
    }

    @Test func frontMatterBecomesATableAndLinesStay() {
        let r = MarkdownHTML.render("---\ntitle: Hello <you>\ntags: [a, b]\n---\n# Heading\n")
        #expect(r.frontMatter?.entries?.count == 2)
        #expect(r.html.hasPrefix("<section class=\"front-matter\""))
        #expect(r.html.contains("<th scope=\"row\">title</th><td>Hello &lt;you&gt;</td>"))
        #expect(r.html.contains("<ul class=\"chips\"><li>a</li><li>b</li></ul>"))
        // The heading is on the file's line 5.
        #expect(r.html.contains("<h1 id=\"heading\" data-line=\"5\">Heading</h1>"))
    }

    @Test func textAndCodeAreEscaped() {
        let html = MarkdownHTML.render("a < b & \"c\"\n\n```\n<script>alert(1)</script>\n```\n").html
        #expect(html.contains("a &lt; b &amp; &quot;c&quot;"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!html.contains("<script>"))
    }

    @Test func mermaidBlocksAreLeftForMermaid() {
        let r = MarkdownHTML.render("Text\n\n```mermaid\ngraph TD\n  A --> B\n```\n")
        #expect(r.hasMermaid)
        #expect(r.html.contains("<figure class=\"mermaid\" data-line=\"3\"><pre class=\"mermaid-source\">graph TD\n  A --&gt; B</pre></figure>"))
        #expect(!MarkdownHTML.render("```swift\nlet a = 1\n```").hasMermaid)
    }

    @Test func codeBlocksAreColoredByTheHighlighter() {
        let r = MarkdownHTML.render("```js\nlet a = 1\n```\n", highlight: { code, language in
            #expect(language == .javascript)
            #expect(code == "let a = 1")
            return [SyntaxSpan(0..<3, .keyword), SyntaxSpan(8..<9, .number)]
        })
        #expect(r.html.contains("data-lang=\"JavaScript\""))
        #expect(r.html.contains("<code><span class=\"syn-keyword\">let</span> a = <span class=\"syn-number\">1</span></code>"))
    }

    @Test func tasksTablesAndStrikethrough() {
        let html = MarkdownHTML.render("""
            - [x] done
            - [ ] to do

            | a | b |
            |:--|--:|
            | 1 | ~~2~~ |
            """).html
        #expect(html.contains("<ul class=\"tasks\" data-line=\"1\">"))
        #expect(html.contains("<li class=\"task done\" data-line=\"1\"><span class=\"check\" role=\"checkbox\" aria-checked=\"true\" tabindex=\"0\"></span>"))
        #expect(html.contains("<li class=\"task\" data-line=\"2\">"))
        #expect(html.contains("<th style=\"text-align: left\">a</th>"))
        #expect(html.contains("<td style=\"text-align: right\"><del>2</del></td>"))
    }

    @Test func alerts() {
        let html = MarkdownHTML.render("> [!WARNING]\n> Mind the *gap*.\n\n> Plain quote\n").html
        #expect(html.contains("<div class=\"alert alert-warning\" data-line=\"1\"><p class=\"alert-title\">Warning</p>"))
        #expect(html.contains("<p data-line=\"1\">Mind the <em>gap</em>.</p>"))
        #expect(!html.contains("[!WARNING]"))
        #expect(html.contains("<blockquote data-line=\"4\">"))
    }

    @Test func headingAnchorsAreUnique() {
        let html = MarkdownHTML.render("# Hello, World!\n\n## Hello, World!\n").html
        #expect(html.contains("id=\"hello-world\""))
        #expect(html.contains("id=\"hello-world-1\""))
    }

    @Test func scriptLinksAreDropped() {
        let html = MarkdownHTML.render("[x](javascript:alert(1)) ![i](img.png \"T\")").html
        #expect(html.contains("<a>x</a>"))
        #expect(html.contains("<img src=\"img.png\" alt=\"i\" title=\"T\">"))
    }

    @Test func rawHTMLKeepsItsMarkup() {
        let html = MarkdownHTML.render(
            "<details><summary>More</summary>\n\nText <kbd>Ctrl</kbd>\n</details>\n\n<p align=\"center\"><img src=\"logo.png\" width=\"200\"></p>\n"
        ).html
        #expect(html.contains("<details><summary>More</summary>"))
        #expect(html.contains("<kbd>Ctrl</kbd>"))
        #expect(html.contains("</details>"))
        #expect(html.contains("<p align=\"center\"><img src=\"logo.png\" width=\"200\"></p>"))
    }

    @Test func rawHTMLCantTakeOverThePage() {
        // Styles that could lay a link over the whole page.
        #expect(RawHTML.sanitize("<style>\na { position: fixed; inset: 0 }\n</style>\n<p>after</p>") == "\n<p>after</p>")
        #expect(RawHTML.sanitize("<STYLE type=text/css>a{}</Style >tail") == "tail")
        #expect(RawHTML.sanitize("<a href=\"#x\" STYLE='display:block' onclick=\"f()\">t</a>") == "<a href=\"#x\">t</a>")
        #expect(RawHTML.sanitize("<svg viewBox=\"0 0 1 1\"><style>*{}</style><rect /></svg>") == "<svg viewBox=\"0 0 1 1\"><rect /></svg>")
        // Forms, <base>, <meta refresh>, <link>, frames, popovers.
        #expect(RawHTML.sanitize("<form action=\"https://x\"><input name=a><button formaction=https://y>Go</button></form>") == "Go")
        #expect(RawHTML.sanitize("<base href=\"https://x/\"><meta http-equiv=\"refresh\" content=\"0\"><link rel=stylesheet href=x>").isEmpty)
        #expect(RawHTML.sanitize("<iframe src=\"https://x\"></iframe>").isEmpty)
        #expect(RawHTML.sanitize("<div popover id=p>x</div><a popovertarget=p>o</a>") == "<div id=p>x</div><a>o</a>")
        // A script goes with its text, inline too.
        #expect(!MarkdownHTML.render("Hi <script>alert(1)</script> there").html.contains("<script"))
    }

    @Test func rawHTMLIsReadAsTheBrowserReadsIt() {
        // A quoted `>` doesn't end the tag.
        #expect(RawHTML.sanitize("<div title=\"a>b\" style=\"z\">") == "<div title=\"a>b\">")
        // A tag that never ends is text, so it can't swallow what follows.
        #expect(RawHTML.sanitize("<div title=\"open\n\nnext") == "&lt;div title=\"open\n\nnext")
        // Not tags: left as they are.
        #expect(RawHTML.sanitize("a < b, <3, <!-- note --> <br/>") == "a < b, <3, <!-- note --> <br />")
        // An unquoted value keeps its end.
        #expect(RawHTML.sanitize("<img src=a.png />") == "<img src=a.png />")
    }

    @Test func pagePolicyBlocksFormsAndBase() {
        let shell = MarkdownPage.shell(style: MarkdownPage.Style())
        #expect(shell.contains("form-action 'none'"))
        #expect(shell.contains("base-uri 'none'"))
    }

    @Test func fenceLanguages() {
        #expect(MarkdownHTML.language(fence: "swift") == .swift)
        #expect(MarkdownHTML.language(fence: "sh") == .shell)
        #expect(MarkdownHTML.language(fence: "c++") == .cpp)
        #expect(MarkdownHTML.language(fence: "ts {1,3}") == .typescript)
        #expect(MarkdownHTML.language(fence: "Python") == .python)
        #expect(MarkdownHTML.language(fence: "nope") == nil)
    }

    @Test func styleSetsEveryToken() {
        let css = MarkdownPage.Style(dark: true).css
        #expect(css.contains("color-scheme: dark"))
        #expect(css.contains("--surface: #251F18;"))
        #expect(css.contains("--syn-keyword: #F08BC0;"))
        #expect(MarkdownPage.Style(codeFont: "JetBrains Mono").css.contains("--mono: \"JetBrains Mono\", ui-monospace"))
    }

    @Test func baseURLAndFiles() {
        let base = MarkdownPage.baseURL(folder: URL(fileURLWithPath: "/Users/me/My Notes"))
        #expect(base.absoluteString == "kiri-preview://file/Users/me/My%20Notes/")
        let image = URL(string: "img/a%20b.png", relativeTo: base)!.absoluteURL
        #expect(MarkdownPage.fileURL(for: image)?.path == "/Users/me/My Notes/img/a b.png")
        #expect(MarkdownPage.fileURL(for: URL(string: "https://example.com/a.png")!) == nil)
        #expect(!MarkdownPage.stylesheet.isEmpty)
        #expect(!MarkdownPage.script.isEmpty)
        #expect(MarkdownPage.mermaidURL != nil)
        #expect(MarkdownPage.purifyURL != nil)
    }
}
