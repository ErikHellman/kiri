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
///
/// Pictures and media from the internet, and files outside the document's
/// folder, load only once the person lets them (`PreviewExternalContent`,
/// Settings ▸ Privacy): until then the page's policy and `PreviewFiles`
/// hold them back, and the tab shows a notice with Accept and Deny
/// (`DocumentTab.previewNotice`).
final class MarkdownPreview: NSObject {
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
    /// The document's file (nil until it has one): its folder is what
    /// pictures load from without a question.
    private var file: URL?
    private let files = PreviewFiles()
    /// The page is loaded letting the web, and files outside the folder, in.
    private var loadsExternal = false
    /// What the page holds back: as its script counts it in the rendering,
    /// and as the page's policy and `PreviewFiles` say they refused.
    private var counted = PreviewHeldBack()
    private var refused = PreviewHeldBack()
    /// The answer for a document that has no file yet.
    private var untitledAnswer: Bool?
    private var shellLoaded = false
    private var mermaidLoaded = false
    private var style: MarkdownPage.Style
    /// The text rendered (and whether as an SVG's picture), and its HTML.
    private var renderedText: String?
    private var renderedSVG = false
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
        config.setURLSchemeHandler(files, forURLScheme: MarkdownPage.scheme)
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
        files.owner = self
        webView.navigationDelegate = self
        // The paper of the editor's panel shows through.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setAccessibilityLabel("Markdown preview")
        webView.onAppearanceChange = { [weak self] in self?.restyle() }
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .honeyThemeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
    }

    @objc private func themeChanged() { restyle() }

    /// Renders `text` (the text of `file`, whose folder images resolve
    /// against and load from) and calls `ready` once the page shows it,
    /// scrolled to the block at `line` (1-based) if given. `svg`: the text
    /// is an SVG file's, and the page shows its picture
    /// (`MarkdownPage.svgHTML`).
    func show(text: String, file: URL?, line: Int?, svg: Bool = false, ready: (() -> Void)? = nil) {
        generation += 1
        let generation = generation
        if let ready { waiting.append(ready) }
        pendingLine = line
        style = currentStyle()
        if file != self.file {
            // Another document: its own answer, and nothing held back yet.
            self.file = file
            untitledAnswer = nil
            counted = PreviewHeldBack()
            refused = PreviewHeldBack()
        }
        let folder = file?.deletingLastPathComponent()
        let base = MarkdownPage.baseURL(folder: folder)
        let loads = Self.policy.loads(answer: answer)
        if base != baseURL || loads != loadsExternal {
            baseURL = base
            loadsExternal = loads
            files.folder = folder
            files.allowsOutside = loads
            loadShell()
        }
        tellNotice()
        guard text != renderedText || svg != renderedSVG || html == nil else {
            fill()
            return
        }
        if svg {
            rendered(html: MarkdownPage.svgHTML(text), hasMermaid: false, of: text, svg: true, generation: generation)
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let rendering = MarkdownHTML.render(text, highlight: MarkdownPreview.highlight)
            await self?.rendered(html: rendering.html, hasMermaid: rendering.hasMermaid, of: text, svg: false,
                                 generation: generation)
        }
    }

    private func rendered(html: String, hasMermaid: Bool, of text: String, svg: Bool, generation: Int) {
        guard generation == self.generation else { return }
        renderedText = text
        renderedSVG = svg
        self.html = html
        if hasMermaid, !self.hasMermaid { Telemetry.track("markdown_mermaid") }
        self.hasMermaid = hasMermaid
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
        refused = PreviewHeldBack()
        webView.loadHTMLString(MarkdownPage.shell(style: style, allowsRemote: loadsExternal), baseURL: baseURL)
    }

    /// Puts the latest rendering in the page, once both are there.
    private func fill() {
        guard shellLoaded, let html else { return }
        let line = pendingLine
        pendingLine = nil
        let inFolder = MarkdownPage.folderPrefix(file?.deletingLastPathComponent())
        call("return await kiriPreview.show(html, style, line, inFolder)",
             ["html": html, "style": style.css, "line": line.map { $0 as Any } ?? NSNull(),
              "inFolder": inFolder.map { $0 as Any } ?? NSNull()], scrolled: line != nil)
    }

    /// Runs `body` in Kiri's world of the page; a `{top, waiting, remote,
    /// outside}` result says where the page is, whether its diagrams wait
    /// for Mermaid, and how many pictures and media come from the web and
    /// from outside the document's folder.
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
                if let remote = answer?["remote"] as? Int, let outside = answer?["outside"] as? Int {
                    self.counted = PreviewHeldBack(remote: remote > 0, outside: outside > 0)
                    self.tellNotice()
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

    // MARK: Pictures and media from elsewhere

    /// The setting (Settings ▸ Privacy).
    static var policy: PreviewExternalContent {
        #if DEBUG || KIRI_SELFTEST
        if let policy = policyForTests { return policy }
        #endif
        return PreviewExternalContent(saved: UserDefaults.standard.string(forKey: Prefs.previewExternalKey))
    }

    /// What the person answered on the notice, by the document's path:
    /// kept until Kiri quits, so the same file doesn't ask in every tab.
    private static var answers: [String: Bool] = [:]

    private var answer: Bool? {
        get {
            guard let file else { return untitledAnswer }
            return Self.answers[file.standardizedFileURL.path]
        }
        set {
            guard let file else { untitledAnswer = newValue; return }
            Self.answers[file.standardizedFileURL.path] = newValue
        }
    }

    /// The notice's Accept (the page loads again, with what it held back)
    /// or Deny (the notice goes, and nothing loads), for this document.
    func answerExternal(accept: Bool) {
        answer = accept
        externalChanged()
    }

    /// (Preferences can be written, and so this called, on any thread.)
    @objc private nonisolated func settingsChanged() {
        Task { @MainActor [weak self] in self?.externalChanged() }
    }

    /// The setting or the answer may have changed: the page is loaded
    /// again if it now lets other things in, and the notice follows.
    private func externalChanged() {
        let loads = Self.policy.loads(answer: answer)
        if loads != loadsExternal, baseURL != nil {
            loadsExternal = loads
            files.allowsOutside = loads
            loadShell()
        }
        tellNotice()
    }

    /// The tab's notice: what the page holds back, while the person is
    /// still to be asked about it.
    private func tellNotice() {
        let held = PreviewHeldBack(remote: counted.remote || refused.remote, outside: counted.outside || refused.outside)
        let notice = !loadsExternal && !held.isEmpty && Self.policy.asks(answer: answer) ? held : nil
        if tab?.previewNotice != notice { tab?.previewNotice = notice }
    }

    /// `PreviewFiles` refused a file outside the document's folder.
    fileprivate func refusedOutside() {
        guard !refused.outside else { return }
        refused.outside = true
        tellNotice()
    }

    // MARK: Messages from the page

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any] else { return }
        if let top = message["top"] as? Int { topLine = top }
        if message["blocked"] as? String == "remote", !refused.remote {
            refused.remote = true
            tellNotice()
        }
        if let text = message["copy"] as? String {
            let board = Self.pasteboard
            board.clearContents()
            board.setString(text, forType: .string)
        }
    }

    /// Where Copy puts a code block.
    private static var pasteboard: NSPasteboard {
        #if DEBUG || KIRI_SELFTEST
        if let board = pasteboardForTests { return board }
        #endif
        return .general
    }

    #if DEBUG || KIRI_SELFTEST
    /// A self-test's own pasteboard for Copy (the person's stays as it is),
    /// what it is told of links instead of opening them, its answer to
    /// the question before a link opens an app, and its setting for
    /// pictures from elsewhere (the saved one stays as it is).
    static var pasteboardForTests: NSPasteboard?
    static var openedForTests: ((URL) -> Void)?
    static var askedForTests: ((LinkQuestion) -> Bool)?
    static var policyForTests: PreviewExternalContent?
    /// Forgets the answers, as after a new launch.
    static func forgetAnswersForTests() { answers = [:] }
    #endif

    /// The page's script posts to `kiri`; the content controller keeps
    /// this, not the preview.
    private final class MessageProxy: NSObject, WKScriptMessageHandler {
        weak var owner: MarkdownPreview?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            owner?.received(message.body)
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

    /// A link (`PreviewLink`): a web page goes to the browser and an
    /// address to the mail app; a text file opens in Kiri. Anything else
    /// would open another app, or run one, with something the document's
    /// author chose, so the person is asked first (`LinkQuestion`).
    private func open(_ url: URL) {
        switch PreviewLink(url) {
        case .web:
            launch(url)
        case .file(let file):
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder) else {
                #if DEBUG || KIRI_SELFTEST
                if let opened = Self.openedForTests { return opened(url) }
                #endif
                NSSound.beep()
                return
            }
            let type = UTType(filenameExtension: file.pathExtension)
            let isText = type.map { $0.conforms(to: .text) || $0.conforms(to: .kiriMarkdown) } ?? false
            if isText, !isFolder.boolValue {
                #if DEBUG || KIRI_SELFTEST
                if let opened = Self.openedForTests { return opened(url) }
                #endif
                NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { _, _, _ in }
            } else {
                ask(LinkQuestion(file: file), thenOpen: file)
            }
        case .app:
            // (A kind of link no app on this Mac opens.)
            guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return NSSound.beep() }
            ask(LinkQuestion(link: url, app: app), thenOpen: url)
        }
    }

    /// Hands `url` to the app for it.
    private func launch(_ url: URL) {
        #if DEBUG || KIRI_SELFTEST
        if let opened = Self.openedForTests { return opened(url) }
        #endif
        NSWorkspace.shared.open(url)
    }

    /// Asks, on the window, and opens `url` only on Open.
    private func ask(_ question: LinkQuestion, thenOpen url: URL) {
        #if DEBUG || KIRI_SELFTEST
        if let asked = Self.askedForTests {
            if asked(question) { launch(url) }
            return
        }
        #endif
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.detail
        let openButton = alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        // Return doesn't run a program: that takes a click on Open.
        if question.runs { openButton.keyEquivalent = "" }
        guard let window = webView.window else {
            if alert.runModal() == .alertFirstButtonReturn { launch(url) }
            return
        }
        Task { @MainActor [weak self] in
            if await alert.beginSheetModal(for: window) == .alertFirstButtonReturn { self?.launch(url) }
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

    // Files dragged over the preview go to the window, as over the text:
    // it knows which side of the editors they are over.
    private var filesWindow: (any NSDraggingInfo) -> DocumentNSWindow? {
        { [weak self] info in FileDrop.urls(info.draggingPasteboard).isEmpty ? nil : self?.window as? DocumentNSWindow }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        filesWindow(sender)?.draggingEntered(sender) ?? super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        filesWindow(sender)?.draggingUpdated(sender) ?? super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if let sender, let window = filesWindow(sender) { window.draggingExited(sender) } else { super.draggingExited(sender) }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        filesWindow(sender)?.performDragOperation(sender) ?? super.performDragOperation(sender)
    }
}

/// What a link in the preview would open, put to the person before it
/// does: a file that isn't text (in its app), an app or another program
/// (which runs), or another app's own kind of link.
struct LinkQuestion {
    var title: String
    var detail: String
    /// Opening it runs a program.
    var runs: Bool

    /// The apps that run what they are given.
    private static let runners: Set<String> = ["com.apple.Terminal", "com.apple.JavaLauncher", "com.apple.installer"]

    /// For a file or folder that is there.
    init(file: URL) {
        let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isApplicationKey, .isExecutableKey, .contentTypeKey])
        let app = NSWorkspace.shared.urlForApplication(toOpen: file)
        let isApp = values?.isApplication == true
        runs = isApp || values?.contentType?.conforms(to: .executable) == true
            || (values?.isDirectory != true && values?.isExecutable == true)
            || app.flatMap { Bundle(url: $0)?.bundleIdentifier }.map(Self.runners.contains) == true
        let name = file.lastPathComponent
        if isApp {
            title = "Open the app “\(file.deletingPathExtension().lastPathComponent)”?"
        } else if let app, !runs {
            title = "Open “\(name)” in \(Self.name(of: app))?"
        } else {
            title = "Open “\(name)”?"
        }
        let path = TabNames.abbreviatingHome(file.path, home: NSHomeDirectory())
        detail = Self.shortened(path) + "\n\n"
            + (runs ? "A link in this document points to a program, and opening it runs it. "
                    : "A link in this document opens it outside Kiri. ")
            + "Open it only if you trust the document."
    }

    /// For a link that `app` opens.
    init(link: URL, app: URL) {
        runs = false
        title = "Open this link in \(Self.name(of: app))?"
        detail = Self.shortened(link.absoluteString) + "\n\n"
            + "A link in this document opens another app. Open it only if you trust the document."
    }

    private static func name(of app: URL) -> String { app.deletingPathExtension().lastPathComponent }

    /// The start and the end of a long one.
    private static func shortened(_ text: String) -> String {
        guard text.count > 240 else { return text }
        return String(text.prefix(160)) + "…" + String(text.suffix(60))
    }
}

/// What the page loads from `kiri-preview:` URLs: the images in the
/// document's folder (`kiri-preview://file/…`) and Nunito
/// (`kiri-preview://app/fonts/…`). No other kind of file is read, and an
/// image outside the folder (a document that has no file yet has none)
/// only once the person has let it (`allowsOutside`).
final class PreviewFiles: NSObject, WKURLSchemeHandler {
    weak var owner: MarkdownPreview?
    /// The document's folder.
    var folder: URL?
    var allowsOutside = false

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
        } else if let local = MarkdownPage.fileURL(for: url), serves(local),
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

    /// Whether `file` may be read: it is in the document's folder, or the
    /// person has let files outside it. A refusal is told to the preview,
    /// for its notice.
    private func serves(_ file: URL) -> Bool {
        if allowsOutside || MarkdownPage.isInside(file, folder: folder) { return true }
        owner?.refusedOutside()
        return false
    }

    private func fail(_ task: any WKURLSchemeTask) {
        task.didFailWithError(URLError(.fileDoesNotExist))
    }
}

// MARK: The tab's side

extension DocumentTab {
    /// The tab can show a preview: its language is Markdown (from the
    /// file's name or picked), or it is an SVG file (shown as XML), and it
    /// isn't a large file (read-only).
    var canPreviewMarkdown: Bool {
        (model.language == .markdown || isSVG && model.language == .xml) && !document.isReadOnly
    }

    /// The file is an SVG: its preview is its picture.
    var isSVG: Bool { document.location?.pathExtension.lowercased() == "svg" }

    /// Switches between the text and the preview.
    func setMarkdownPreview(_ on: Bool) {
        if on {
            guard canPreviewMarkdown, !showsMarkdownPreview else { return }
            // In the editor's place, not beside it as well: one web view.
            if previewsBeside { window?.tabs.endSplit() }
            showsMarkdownPreview = true
            Telemetry.track(isSVG ? "svg_preview" : "markdown_preview")
            let preview = markdownPreview ?? MarkdownPreview(tab: self)
            markdownPreview = preview
            // The page is laid out and scrolled at the size it will show at:
            // at another width the same scroll offset is another part of it.
            if preview.webView.superview == nil, container.bounds.width > 0 { preview.webView.frame = container.frame }
            let line = (controller.currentPosition()?.topLine ?? 0) + 1
            preview.show(text: markdownText, file: document.location, line: line,
                         svg: isSVG) { [weak self] in
                guard let self, self.showsMarkdownPreview else { return }
                self.opensInPreview = false
                self.showInSlot(focus: true)
            }
        } else {
            guard showsMarkdownPreview else { return }
            showsMarkdownPreview = false
            opensInPreview = false
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
        if previewsBeside { return textChangedBesidePreview() }
        guard showsMarkdownPreview else { return }
        // (After the language has followed the new file.)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.showsMarkdownPreview else { return }
            guard self.canPreviewMarkdown else { return self.setMarkdownPreview(false) }
            self.markdownPreview?.show(text: self.markdownText, file: self.document.location,
                                       line: nil, svg: self.isSVG)
        }
    }

    private var markdownText: String { controller.textView?.string ?? document.text }

    /// Puts the editor or the preview in the window, if this tab shows.
    /// (The keyboard goes to the preview only on the keyboard's side.)
    private func showInSlot(focus: Bool) {
        guard let window, let slot = window.slot(for: self) else { return }
        slot.show(self)
        if focus, window.tabs.selectedTab === self, let web = markdownPreview?.webView, web.window != nil {
            web.window?.makeFirstResponder(web)
        }
    }

    // MARK: Beside the text

    /// The window shows this tab's preview beside its text (View ▸ Preview
    /// to the Side).
    var previewsBeside: Bool {
        guard let tabs = window?.tabs else { return false }
        return tabs.beside == .preview && tabs.selectedTab === self
    }

    /// The preview beside the text: rendered now, at the part of the file
    /// at the top of the text, and shown on its side once it is.
    func startPreviewBeside() {
        let preview = markdownPreview ?? MarkdownPreview(tab: self)
        markdownPreview = preview
        if preview.webView.superview == nil, container.bounds.width > 0 {
            var frame = container.frame
            frame.size.width = max(frame.width / 2, 200)
            preview.webView.frame = frame
        }
        let line = (controller.currentPosition()?.topLine ?? 0) + 1
        preview.show(text: markdownText, file: document.location, line: line, svg: isSVG) { [weak self] in
            guard let self, self.previewsBeside else { return }
            self.window?.previewSlot(for: self)?.showPreviewBeside(self)
        }
        Telemetry.track(isSVG ? "svg_preview" : "markdown_preview", ["beside": true])
    }

    /// The text changed while its preview shows beside it: the preview
    /// follows, a moment after the last key (each rendering is the whole
    /// file), keeping its place.
    func textChangedBesidePreview() {
        guard previewsBeside else { return }
        besideRender?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.previewsBeside else { return }
            guard self.canPreviewMarkdown else { self.window?.tabs.endSplit(); return }
            self.markdownPreview?.show(text: self.markdownText, file: self.document.location,
                                       line: nil, svg: self.isSVG)
        }
        besideRender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
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
