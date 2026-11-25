import AppKit
import KiriKit
import KiriMarkdown
import KiriSyntax
import UniformTypeIdentifiers
import WebKit

/// A Markdown tab's preview: the file rendered (`MarkdownHTML`), its front
/// matter as a table and its Mermaid diagrams drawn, in the editor's place
/// on the paper (`TabEditorSlot`). View ▸ Markdown Preview (⌃⌘P) and the
/// Text / Preview switch in the top bar turn it on and off.
///
/// Made the first time a tab shows its preview, never at launch: the web
/// view, and Mermaid (only for a file with a diagram), load then. The page
/// is loaded once (`MarkdownPage.shell`); each rendering goes into it, so
/// the place, and Mermaid, stay. Switching keeps the place: the preview
/// opens at the block at the top of the text, and the text comes back at
/// the block at the top of the preview if it was scrolled.
@MainActor final class MarkdownPreview: NSObject {
    let webView: PreviewWebView
    private weak var tab: DocumentTab?
    /// It shows a rendering: the slot can put it in the editor's place.
    private(set) var isReady = false
    /// The line of the block at the top of the preview.
    private(set) var topLine = 1
    /// `topLine` when the preview was last switched to: if it is still
    /// that, the text stays where it was.
    private(set) var enteredLine = 1

    private var baseURL: URL?
    private var shellLoaded = false
    private var mermaidLoaded = false
    private var style: MarkdownPage.Style
    /// The text rendered, and its HTML.
    private var renderedText: String?
    private var html: String?
    private var hasMermaid = false
    /// Bumped by each `show`: an older rendering that finishes late is dropped.
    private var generation = 0
    /// What the next time the page is filled scrolls to (nil: keeps its place).
    private var pendingLine: Int?
    private var waiting: [() -> Void] = []

    init(tab: DocumentTab) {
        self.tab = tab
        style = MarkdownPage.Style()
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(PreviewFiles.shared, forURLScheme: MarkdownPage.scheme)
        // Nothing of it is kept on disk.
        config.websiteDataStore = .nonPersistent()
        // The file's own scripts never run; Kiri's run in a world of their own.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let messages = MessageProxy()
        config.userContentController.add(messages, contentWorld: .defaultClient, name: "kiri")
        config.userContentController.addUserScript(WKUserScript(source: MarkdownPage.script, injectionTime: .atDocumentEnd,
                                                                forMainFrameOnly: true, in: .defaultClient))
        webView = PreviewWebView(frame: .zero, configuration: config)
        super.init()
        messages.owner = self
        webView.navigationDelegate = self
        // The paper of the editor's panel shows through.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setAccessibilityLabel("Markdown preview")
        webView.onAppearanceChange = { [weak self] in self?.restyle() }
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .honeyThemeDidChange, object: nil)
    }

    @objc private func themeChanged() { restyle() }

    /// Renders `text` (a file in `folder`, which images resolve against)
    /// and calls `ready` once the page shows it, scrolled to the block at
    /// `line` (1-based) if given.
    func show(text: String, folder: URL?, line: Int?, ready: (() -> Void)? = nil) {
        generation += 1
        let generation = generation
        if let ready { waiting.append(ready) }
        pendingLine = line
        style = currentStyle()
        let base = MarkdownPage.baseURL(folder: folder)
        if base != baseURL {
            baseURL = base
            loadShell()
        }
        guard text != renderedText || html == nil else {
            fill()
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let rendering = MarkdownHTML.render(text, highlight: MarkdownPreview.highlight)
            await self?.rendered(rendering, of: text, generation: generation)
        }
    }

    private func rendered(_ rendering: MarkdownRendering, of text: String, generation: Int) {
        guard generation == self.generation else { return }
        renderedText = text
        html = rendering.html
        if rendering.hasMermaid, !hasMermaid { Telemetry.track("markdown_mermaid") }
        hasMermaid = rendering.hasMermaid
        fill()
    }

    /// The editor's text size or font, or the window's appearance, may
    /// have changed: the page follows.
    func restyle() {
        let new = currentStyle()
        guard new != style else { return }
        style = new
        guard shellLoaded, html != nil else { return }
        call("return await kiriPreview.show(null, style, null)", ["style": style.css])
    }

    // MARK: The page

    private func loadShell() {
        shellLoaded = false
        mermaidLoaded = false
        webView.loadHTMLString(MarkdownPage.shell(style: style), baseURL: baseURL)
    }

    /// Puts the latest rendering in the page, once both are there.
    private func fill() {
        guard shellLoaded, let html else { return }
        let line = pendingLine
        pendingLine = nil
        call("return await kiriPreview.show(html, style, line)",
             ["html": html, "style": style.css, "line": line.map { $0 as Any } ?? NSNull()], scrolled: line != nil)
    }

    /// Runs `body` in Kiri's world of the page; a `{top, waiting}` result
    /// says where the page is and whether its diagrams wait for Mermaid.
    private func call(_ body: String, _ arguments: [String: Any], scrolled: Bool = false) {
        let generation = generation
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                let answer = (try? result.get()) as? [String: Any]
                if let top = answer?["top"] as? Int {
                    self.topLine = top
                    if scrolled { self.enteredLine = top }
                }
                guard generation == self.generation else { return }
                if !self.isReady || !self.waiting.isEmpty {
                    self.isReady = true
                    let waiting = self.waiting
                    self.waiting = []
                    for ready in waiting { ready() }
                }
                if answer?["waiting"] as? Bool == true { self.loadMermaid() }
            }
        }
    }

    /// Mermaid, into the page's Kiri world, then the diagrams drawn.
    private func loadMermaid() {
        guard !mermaidLoaded, let source = Self.mermaidSource else { return }
        mermaidLoaded = true
        webView.evaluateJavaScript(source, in: nil, in: .defaultClient) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shellLoaded else { return }
                self.call("return await kiriPreview.redraw(null)", [:])
            }
        }
    }

    /// Mermaid's script (5 MB), read the first time a file has a diagram.
    /// (`;true`: its value, Mermaid itself, can't come back to the app.)
    private static let mermaidSource: String? = MarkdownPage.mermaidURL
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .map { $0 + "\n;true" }

    private func currentStyle() -> MarkdownPage.Style {
        let appearance = tab?.window?.effectiveAppearance ?? webView.effectiveAppearance
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                .accessibilityHighContrastDarkAqua])
        let scale = UserDefaults.standard.object(forKey: Prefs.textScaleKey) as? Double ?? 1
        return MarkdownPage.Style(theme: Honey.theme,
                                  dark: match == .darkAqua || match == .accessibilityHighContrastDarkAqua,
                                  highContrast: match == .accessibilityHighContrastAqua
                                      || match == .accessibilityHighContrastDarkAqua,
                                  textScale: scale, codeFont: EditorFont.shared.shown)
    }

    /// Code blocks colored as the editor colors them: Tree-sitter where
    /// Kiri has the grammar, the small lexer for the rest.
    nonisolated static let highlight: CodeHighlighter = { code, language in
        guard language != .plainText else { return nil }
        if SyntaxGrammar.supportedIDs.contains(language.id), let grammar = SyntaxGrammar.forLanguage(id: language.id),
           let parser = SyntaxParser(grammar: grammar), let snapshot = parser.parse(code as NSString) {
            return snapshot.spans(in: 0..<(code as NSString).length)
        }
        return FallbackHighlighter.spans(in: code, language: language)
    }

    // MARK: Messages from the page

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any] else { return }
        if let top = message["top"] as? Int { topLine = top }
        if let text = message["copy"] as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// The page's script posts to `kiri`; the content controller keeps
    /// this, not the preview.
    private final class MessageProxy: NSObject, WKScriptMessageHandler {
        weak var owner: MarkdownPreview?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated { owner?.received(message.body) }
        }
    }
}

// MARK: Links

extension MarkdownPreview: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let isPage = Self.withoutFragment(url) == baseURL.map(Self.withoutFragment)
        // The page itself (loading, a reload), and a jump within it (`#heading`).
        if isPage, navigationAction.navigationType != .linkActivated || url.fragment != nil,
           navigationAction.targetFrame?.isMainFrame == true {
            return .allow
        }
        if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil { open(url) }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // (Also after a reload from the page's menu.)
        shellLoaded = true
        mermaidLoaded = false
        // The page is filled again, where it was.
        if pendingLine == nil, isReady { pendingLine = topLine }
        fill()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadShell()
    }

    /// A link: a file next to the document opens in Kiri if it is text,
    /// in its own app otherwise; anything else in the browser (or the app
    /// for its scheme, such as Mail).
    private func open(_ url: URL) {
        guard url.scheme == MarkdownPage.scheme else {
            NSWorkspace.shared.open(url)
            return
        }
        guard let file = MarkdownPage.fileURL(for: url), FileManager.default.fileExists(atPath: file.path) else {
            NSSound.beep()
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)
        let isText = type.map { $0.conforms(to: .text) || $0.conforms(to: .kiriMarkdown) } ?? false
        if isText, !file.hasDirectoryPath {
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { _, _, _ in }
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    private static func withoutFragment(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }
}

/// The preview's web view: tells the preview when the appearance changes
/// (light, dark, more contrast), and takes the keyboard to scroll.
final class PreviewWebView: WKWebView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // (Another window may have another appearance.)
        if window != nil { onAppearanceChange?() }
    }
}

/// What the page loads from `kiri-preview:` URLs: the images next to the
/// document (`kiri-preview://file/…`) and Nunito (`kiri-preview://app/fonts/…`).
/// Nothing else: no other kind of file is read.
final class PreviewFiles: NSObject, WKURLSchemeHandler {
    static let shared = PreviewFiles()

    /// Bigger images aren't read.
    static let limit = 64 * 1024 * 1024

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return fail(task) }
        let file: URL
        let mime: String
        if url.host == "app" {
            let name = url.lastPathComponent
            guard url.path.hasPrefix("/fonts/"), let font = Honey.fontURLs.first(where: { $0.lastPathComponent == name }) else {
                return fail(task)
            }
            file = font
            mime = "font/ttf"
        } else if let local = MarkdownPage.fileURL(for: url),
                  let type = UTType(filenameExtension: local.pathExtension), type.conforms(to: .image),
                  let size = (try? local.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.limit {
            file = local
            mime = type.preferredMIMEType ?? "application/octet-stream"
        } else {
            return fail(task)
        }
        guard let data = try? Data(contentsOf: file) else { return fail(task) }
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func fail(_ task: any WKURLSchemeTask) {
        task.didFailWithError(URLError(.fileDoesNotExist))
    }
}

// MARK: The tab's side

extension DocumentTab {
    /// The tab can show a preview: its language is Markdown (from the
    /// file's name or picked), and it isn't a large file (read-only).
    var canPreviewMarkdown: Bool { model.language == .markdown && !document.isLargeFile }

    /// Switches between the text and the preview.
    func setMarkdownPreview(_ on: Bool) {
        if on {
            guard canPreviewMarkdown, !showsMarkdownPreview else { return }
            showsMarkdownPreview = true
            Telemetry.track("markdown_preview")
            let preview = markdownPreview ?? MarkdownPreview(tab: self)
            markdownPreview = preview
            // The page is laid out and scrolled at the size it will show at:
            // at another width the same scroll offset is another part of it.
            if preview.webView.superview == nil, container.bounds.width > 0 { preview.webView.frame = container.frame }
            let line = (controller.currentPosition()?.topLine ?? 0) + 1
            preview.show(text: markdownText, folder: document.location?.deletingLastPathComponent(), line: line) { [weak self] in
                guard let self, self.showsMarkdownPreview else { return }
                self.showInSlot(focus: true)
            }
        } else {
            guard showsMarkdownPreview else { return }
            showsMarkdownPreview = false
            let preview = markdownPreview
            let hadKeyboard = preview.map { $0.webView.window?.firstResponder === $0.webView } ?? false
            showInSlot(focus: false)
            // Back at the block the preview was scrolled to, if it was.
            if let preview, preview.topLine != preview.enteredLine { controller.scroll(toTopLine: preview.topLine - 1) }
            if hadKeyboard { controller.focus() }
        }
    }

    /// The text changed under the preview (File ▸ Revert, the file changed
    /// on disk, the preview tab took another file): it renders again, or
    /// goes if the tab can't show one any more.
    func markdownTextChanged() {
        guard showsMarkdownPreview else { return }
        // (After the language has followed the new file.)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.showsMarkdownPreview else { return }
            guard self.canPreviewMarkdown else { return self.setMarkdownPreview(false) }
            self.markdownPreview?.show(text: self.markdownText, folder: self.document.location?.deletingLastPathComponent(),
                                       line: nil)
        }
    }

    private var markdownText: String { controller.textView?.string ?? document.text }

    /// Puts the editor or the preview in the window, if this tab shows.
    private func showInSlot(focus: Bool) {
        guard let window, window.tabs.selectedTab === self, let slot = window.editorSlot else { return }
        slot.show(self)
        if focus, let web = markdownPreview?.webView, web.window != nil { web.window?.makeFirstResponder(web) }
    }
}

extension EditorController {
    /// Scrolls the text so `line` (0-based) is at the top, the selection
    /// as it is.
    func scroll(toTopLine line: Int) {
        guard let textView else { return }
        let selection = textView.selectedRange()
        pendingPosition = FilePosition(selection: selection.location..<NSMaxRange(selection), topLine: line,
                                       in: currentLineIndex)
        applyPendingPosition()
    }
}
