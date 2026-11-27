import Foundation
import Testing
@testable import KiriMarkdown

@Suite struct PreviewSafetyTests {
    @Test func theWebIsLetInOnlyWhenAllowed() {
        let strict = MarkdownPage.contentSecurityPolicy(allowsRemote: false)
        #expect(strict.contains("default-src 'none'"))
        #expect(strict.contains("img-src kiri-preview: data:;"))
        #expect(strict.contains("media-src kiri-preview:;"))
        #expect(!strict.contains("http"))
        let open = MarkdownPage.contentSecurityPolicy(allowsRemote: true)
        #expect(open.contains("img-src kiri-preview: https: http: data:;"))
        #expect(open.contains("media-src kiri-preview: https: http:;"))
        // Never a script, a frame or a stylesheet from anywhere.
        for policy in [strict, open] {
            #expect(!policy.contains("script-src"))
            #expect(!policy.contains("frame-src"))
            #expect(policy.contains("style-src 'unsafe-inline';"))
        }
        // The page holds the web back unless it is told otherwise.
        #expect(MarkdownPage.shell(style: .init()).contains("content=\"\(strict)\""))
        #expect(MarkdownPage.shell(style: .init(), allowsRemote: true).contains("content=\"\(open)\""))
    }

    @Test func theSettingAndTheAnswer() {
        #expect(PreviewExternalContent(saved: nil) == .ask)
        #expect(PreviewExternalContent(saved: "nonsense") == .ask)
        #expect(PreviewExternalContent(saved: "deny") == .deny)
        #expect(PreviewExternalContent(saved: "allow") == .allow)

        #expect(!PreviewExternalContent.ask.loads(answer: nil))
        #expect(PreviewExternalContent.ask.loads(answer: true))
        #expect(!PreviewExternalContent.ask.loads(answer: false))
        #expect(PreviewExternalContent.ask.asks(answer: nil))
        #expect(!PreviewExternalContent.ask.asks(answer: true))
        #expect(!PreviewExternalContent.ask.asks(answer: false))
        // Always Deny and Always Allow: no question, whatever was answered before.
        for answer in [nil, true, false] as [Bool?] {
            #expect(!PreviewExternalContent.deny.loads(answer: answer))
            #expect(!PreviewExternalContent.deny.asks(answer: answer))
            #expect(PreviewExternalContent.allow.loads(answer: answer))
            #expect(!PreviewExternalContent.allow.asks(answer: answer))
        }
    }

    @Test func whatTheNoticeSays() {
        #expect(PreviewHeldBack().isEmpty)
        #expect(!PreviewHeldBack(remote: true).isEmpty)
        #expect(PreviewHeldBack(remote: true).notice == "This document loads pictures or media from the internet.")
        #expect(PreviewHeldBack(outside: true).notice == "This document loads pictures from outside its folder.")
        #expect(PreviewHeldBack(remote: true, outside: true).notice
            == "This document loads pictures or media from the internet and from outside its folder.")
    }

    @Test func filesInsideTheFolder() throws {
        let folder = URL(fileURLWithPath: "/Users/me/Notes")
        #expect(MarkdownPage.isInside(URL(fileURLWithPath: "/Users/me/Notes/a.png"), folder: folder))
        #expect(MarkdownPage.isInside(URL(fileURLWithPath: "/Users/me/Notes/img/deep/a.png"), folder: folder))
        #expect(MarkdownPage.isInside(URL(fileURLWithPath: "/Users/me/Notes/img/../a.png"), folder: folder))
        #expect(!MarkdownPage.isInside(URL(fileURLWithPath: "/Users/me/Notes/../a.png"), folder: folder))
        #expect(!MarkdownPage.isInside(URL(fileURLWithPath: "/Users/me/Notes/img/../../Secret/a.png"), folder: folder))
        #expect(!MarkdownPage.isInside(URL(fileURLWithPath: "/Users/me/a.png"), folder: folder))
        // A folder whose name only starts the same.
        #expect(!MarkdownPage.isInside(URL(fileURLWithPath: "/Users/me/Notes2/a.png"), folder: folder))
        #expect(!MarkdownPage.isInside(URL(fileURLWithPath: "/etc/passwd"), folder: folder))
        // The folder itself isn't a file in it, and a document without a folder has none.
        #expect(!MarkdownPage.isInside(folder, folder: folder))
        #expect(!MarkdownPage.isInside(URL(fileURLWithPath: "/Users/me/Notes/a.png"), folder: nil))
        #expect(MarkdownPage.folderPrefix(folder) == "/Users/me/Notes/")
        #expect(MarkdownPage.folderPrefix(nil) == nil)
        // What a URL of the page stands for.
        let base = MarkdownPage.baseURL(folder: folder)
        let up = try #require(URL(string: "../Secret/a.png", relativeTo: base)?.absoluteURL)
        let file = try #require(MarkdownPage.fileURL(for: up))
        #expect(file.path == "/Users/me/Secret/a.png")
        #expect(!MarkdownPage.isInside(file, folder: folder))
    }

    @Test func aLinkInTheFolderToAFileOutsideIsOutside() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("kiri-inside-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("doc"), other = root.appendingPathComponent("other")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try files.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        try Data("x".utf8).write(to: other.appendingPathComponent("secret.png"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("mine.png"))
        try files.createSymbolicLink(at: folder.appendingPathComponent("link.png"),
                                     withDestinationURL: other.appendingPathComponent("secret.png"))
        try files.createSymbolicLink(at: folder.appendingPathComponent("elsewhere"), withDestinationURL: other)
        #expect(MarkdownPage.isInside(folder.appendingPathComponent("mine.png"), folder: folder))
        #expect(!MarkdownPage.isInside(folder.appendingPathComponent("link.png"), folder: folder))
        #expect(!MarkdownPage.isInside(folder.appendingPathComponent("elsewhere/secret.png"), folder: folder))
        // The folder itself reached through a link is still the folder.
        try files.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: folder)
        #expect(MarkdownPage.isInside(root.appendingPathComponent("alias/mine.png"), folder: folder))
        #expect(MarkdownPage.isInside(folder.appendingPathComponent("mine.png"), folder: root.appendingPathComponent("alias")))
    }

    @Test func whereALinkGoes() throws {
        func link(_ text: String) throws -> PreviewLink { PreviewLink(try #require(URL(string: text))) }
        #expect(try link("https://example.com/kiri") == .web)
        #expect(try link("HTTP://example.com") == .web)
        #expect(try link("mailto:someone@example.com") == .web)
        // A file next to the document, and one named outright.
        let base = MarkdownPage.baseURL(folder: URL(fileURLWithPath: "/Users/me/Notes"))
        let notes = try #require(URL(string: "notes.md", relativeTo: base)?.absoluteURL)
        #expect(PreviewLink(notes) == .file(URL(fileURLWithPath: "/Users/me/Notes/notes.md")))
        let app = try #require(URL(string: "/System/Applications/Calculator.app", relativeTo: base)?.absoluteURL)
        #expect(PreviewLink(app) == .file(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        guard case .file(let named) = try link("file:///Applications/Some.app") else {
            Issue.record("a file: link is a file")
            return
        }
        #expect(named.path == "/Applications/Some.app")
        // Everything else belongs to another app.
        #expect(try link("x-apple.systempreferences:com.apple.preference.security") == .app(scheme: "x-apple.systempreferences"))
        #expect(try link("zoommtg://zoom.us/join?confno=1") == .app(scheme: "zoommtg"))
        #expect(try link("ssh://host") == .app(scheme: "ssh"))
        #expect(try link("kiri-preview://app/fonts/Nunito-400.ttf") == .app(scheme: "kiri-preview"))
    }
}
