#if DEBUG || KIRI_SELFTEST
import AppKit
import KiriKit
import KiriMarkdown
import WebKit

extension SelfTest {
    private static var markdownStarted = false

    /// The Markdown preview's flags, in a launch with a Markdown file:
    /// `-KiriMarkdownTest YES` runs its checks (`markdownStage`), and
    /// `-KiriMarkdownPreview YES` shows the preview for a picture and stays
    /// (`-KiriMarkdownLine <n>` opens it at line n).
    static func markdownFlags(_ textView: NSTextView) -> Bool {
        let defaults = UserDefaults.standard
        let test = defaults.bool(forKey: "KiriMarkdownTest")
        guard test || defaults.bool(forKey: "KiriMarkdownPreview") else { return false }
        guard !markdownStarted else { return true }
        markdownStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let window = textView.window else { report(false, "a window for the Markdown preview"); quit(); return }
            FrontEditor.shared.selfTestMain(window)
            Task { @MainActor in
                if test {
                    await markdownStage(window)
                    reportStayedInTheBackground()
                    print("SELFTEST DONE markdown")
                    fflush(stdout)
                    quit()
                } else {
                    guard let tab = (window as? DocumentNSWindow)?.tabs.selectedTab else { return }
                    if let line = defaults.string(forKey: "KiriMarkdownLine").flatMap(Int.init) {
                        tab.controller.scroll(toTopLine: line - 1)
                        await settle(200)
                    }
                    tab.setMarkdownPreview(true)
                    for _ in 0..<100 where tab.markdownPreview?.isReady != true { await settle(50) }
                    print("SELFTEST info markdown preview shown (\(tab.markdownPreview?.isReady == true)), text at \((tab.controller.currentPosition()?.topLine ?? -1) + 1), preview at \(tab.markdownPreview?.topLine ?? -1)")
                    fflush(stdout)
                    // (Once Mermaid has drawn, where a file has diagrams.)
                    await settle(3000)
                    print("SELFTEST info preview at \(tab.markdownPreview?.topLine ?? -1)")
                    fflush(stdout)
                }
            }
        }
        return true
    }

    /// The Markdown preview (`MarkdownPreview`): ⌃⌘P shows it in the
    /// editor's place, at the part of the file at the top of the editor;
    /// the page has the front matter as a table first, Nunito, colored
    /// code with a Copy button, GitHub's tables, tasks (their boxes
    /// ticking in the page, `tasksStage`) and alerts, the
    /// file's image, and its Mermaid diagrams drawn (a broken one says
    /// so); links go to the app (recorded here, not opened), and one that
    /// would open another app or run one asks first; pictures from the
    /// internet and from outside the file's folder wait for Accept
    /// (`externalStage`); ⌃⌘P again
    /// brings the text back at the part the preview was scrolled to; dark
    /// restyles the page and the diagrams; another language leaves it.
    /// `-KiriMarkdownTest YES`, with a Markdown file like the one the
    /// checks expect (front matter with `tags` and a nested map, a Swift
    /// block, an image, two diagrams and a broken one, a link to
    /// https://example.com/kiri and one to notes.md, several screens long).
    static func markdownStage(_ window: NSWindow) async {
        guard let documentWindow = window as? DocumentNSWindow, let tab = documentWindow.tabs.selectedTab,
              let slot = documentWindow.editorSlot else {
            report(false, "a document window for the Markdown preview's checks")
            return
        }
        report(tab.canPreviewMarkdown, "a Markdown file can show its preview (\(tab.model.language.name))")
        guard tab.canPreviewMarkdown else { return }
        let board = NSPasteboard.withUniqueName()
        MarkdownPreview.pasteboardForTests = board
        final class Opened { var urls: [URL] = [] }
        let opened = Opened()
        MarkdownPreview.openedForTests = { opened.urls.append($0) }
        defer {
            MarkdownPreview.pasteboardForTests = nil
            MarkdownPreview.openedForTests = nil
            MarkdownPreview.askedForTests = nil
            MarkdownPreview.policyForTests = nil
            MarkdownPreview.forgetAnswersForTests()
            board.releaseGlobally()
        }

        func menuItem() -> NSMenuItem? {
            guard let main = NSApp.mainMenu else { return nil }
            updateMenu(main)
            return main.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "Markdown Preview" }
        }
        /// ⌃⌘P, through the menu bar as a key press goes.
        func press() async -> Bool {
            guard let main = NSApp.mainMenu else { return false }
            updateMenu(main)
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: "\u{10}",
                                           charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35) else { return false }
            let handled = main.performKeyEquivalent(with: e)
            await settle(100)
            return handled
        }
        func ready() async {
            for _ in 0..<160 where !(tab.markdownPreview?.isReady == true && tab.markdownPreview?.webView.superview === slot) {
                await settle(50)
            }
        }
        func editorTop() -> Int { (tab.controller.currentPosition()?.topLine ?? -1) + 1 }

        let item = menuItem()
        report(item?.isEnabled == true && item?.keyEquivalent == "p" && item?.keyEquivalentModifierMask == [.control, .command],
               "View ▸ Markdown Preview is on for a Markdown file, on ⌃⌘P (\(item?.isEnabled ?? false))")

        // Opened at the part of the file at the top of the editor.
        tab.controller.scroll(toTopLine: 41)
        await settle(200)
        let textTop = editorTop()
        let pressed = await press()
        await ready()
        guard let preview = tab.markdownPreview else {
            report(false, "⌃⌘P shows the preview (pressed \(pressed))")
            return
        }
        let web = preview.webView
        report(pressed && tab.showsMarkdownPreview && preview.isReady && web.superview === slot && tab.container.superview == nil,
               "⌃⌘P shows the preview in the editor's place (pressed \(pressed), shown \(tab.showsMarkdownPreview), ready \(preview.isReady))")
        report(menuItem()?.state == .on, "the menu item is ticked while the preview shows")
        report(abs(preview.topLine - textTop) <= 6 && preview.topLine > 1,
               "the preview opens at the part of the file at the top of the text (text \(textTop), preview \(preview.topLine))")
        report((web.value(forKey: "drawsBackground") as? Bool) == false, "the web view draws no background of its own")
        let delegate = web.navigationDelegate as? NSObject
        report(delegate === preview
               && delegate?.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")) == true,
               "the preview is the web view's navigation delegate and decides on navigations")

        // The diagrams: Mermaid loads, two are drawn and the broken one says so.
        var diagrams: [String: Any]?
        for _ in 0..<60 {
            diagrams = await pageJSON(web, """
                return { drawn: document.querySelectorAll('figure.mermaid.drawn > svg').length,
                         failed: document.querySelectorAll('figure.mermaid.failed .mermaid-error').length,
                         mermaid: !!window.mermaid };
                """)
            if diagrams?["drawn"] as? Int == 2, diagrams?["failed"] as? Int == 1 { break }
            await settle(250)
        }
        report(diagrams?["drawn"] as? Int == 2 && diagrams?["failed"] as? Int == 1,
               "Mermaid draws the two diagrams and the broken one shows an error (\(diagrams ?? [:]))")
        // Where the page really is, at the size it shows at, the diagrams drawn.
        await settle(300)
        let live = await pageJSON(web, "return { top: kiriPreview.topLine() };")?["top"] as? Int ?? -1
        report(abs(live - textTop) <= 6 && live > 1 && preview.topLine == live,
               "the preview shows the part of the file at the top of the text, also once the diagrams are drawn (text \(textTop), page \(live), told \(preview.topLine))")

        // The page.
        let pageScript = """
            await document.fonts.ready;
            const page = document.getElementById('kiri-page');
            const img = page.querySelector('img');
            if (img && !img.complete) await new Promise(r => { img.onload = img.onerror = r; setTimeout(r, 3000); });
            const first = page.firstElementChild;
            const fm = first && first.classList.contains('front-matter') ? first : null;
            const code = page.querySelector('.code');
            const syn = code ? code.querySelector('span[class^="syn-"]') : null;
            const node = page.querySelector('figure.mermaid.drawn svg .node rect, figure.mermaid.drawn svg .node polygon');
            const root = getComputedStyle(document.documentElement);
            return {
              frontMatter: !!fm, frontMatterRaw: fm ? fm.classList.contains('raw') : null,
              frontMatterText: fm ? fm.textContent.replace(/\\s+/g, ' ').slice(0, 200) : '',
              nunito: [...document.fonts].filter(f => f.family.replace(/"/g, '') === 'Nunito' && f.status === 'loaded').length,
              bodyFont: getComputedStyle(document.body).fontFamily,
              synSpans: code ? code.querySelectorAll('span[class^="syn-"]').length : 0,
              synColor: syn ? getComputedStyle(syn).color : '', codeColor: code ? getComputedStyle(code.querySelector('code')).color : '',
              copy: code ? !!code.querySelector('button.copy') : false,
              image: img ? img.naturalWidth : -1, imageSrc: img ? img.src : '',
              background: [getComputedStyle(document.documentElement).backgroundColor, getComputedStyle(document.body).backgroundColor],
              tables: page.querySelectorAll('.table table').length, tasks: page.querySelectorAll('li.task').length,
              done: page.querySelectorAll('li.task.done').length, alert: !!page.querySelector('.alert.alert-note'),
              strike: !!page.querySelector('del, s'), h1: (page.querySelector('h1') || {}).textContent || '',
              error: (page.querySelector('.mermaid-error') || {}).textContent || '',
              scheme: root.colorScheme, fg: root.getPropertyValue('--fg').trim(), nodeFill: node ? getComputedStyle(node).fill : '',
              href: location.href, scripts: document.querySelectorAll('script').length,
            };
            """
        let page = await pageJSON(web, pageScript) ?? [:]
        let fmText = page["frontMatterText"] as? String ?? ""
        report(page["frontMatter"] as? Bool == true && page["frontMatterRaw"] as? Bool == false
               && fmText.contains("front matter") && fmText.contains("ErikHellman"),
               "the front matter is a table first on the page, its tags and nested map in it (“\(fmText.prefix(120))”)")
        report((page["nunito"] as? Int ?? 0) >= 1 && (page["bodyFont"] as? String ?? "").contains("Nunito"),
               "the page is set in Nunito, from the app (\(page["nunito"] ?? "-") faces loaded, \(page["bodyFont"] ?? "-"))")
        report((page["synSpans"] as? Int ?? 0) >= 5 && page["synColor"] as? String != page["codeColor"] as? String
               && page["copy"] as? Bool == true,
               "the Swift block is colored (\(page["synSpans"] ?? 0) spans) and has a Copy button")
        report((page["image"] as? Int ?? 0) == 240, "the image next to the file loads (\(page["image"] ?? "-"), \(page["imageSrc"] ?? ""))")
        let background = page["background"] as? [String] ?? []
        report(background.allSatisfy { $0 == "rgba(0, 0, 0, 0)" } && background.count == 2,
               "the page is transparent: the paper shows through (\(background))")
        report(page["tables"] as? Int == 1 && page["tasks"] as? Int == 3 && page["done"] as? Int == 2
               && page["alert"] as? Bool == true && page["strike"] as? Bool == true,
               "GitHub's table, task list, alert and strikethrough (\(page["tables"] ?? "-"), \(page["tasks"] ?? "-"), \(page["done"] ?? "-"), \(page["alert"] ?? "-"))")
        report((page["error"] as? String ?? "").hasPrefix("This diagram has a mistake"),
               "the broken diagram says what is wrong (“\((page["error"] as? String ?? "").prefix(90))”)")
        report(page["scripts"] as? Int == 0, "the page has no scripts of its own")

        // Copy, on a pasteboard of the test's own.
        _ = await pageJSON(web, "document.querySelector('.code button.copy').click(); return {};")
        for _ in 0..<20 where board.string(forType: .string) == nil { await settle(50) }
        let copied = board.string(forType: .string) ?? ""
        report(copied.hasPrefix("struct Greeter") && copied.contains("func greet()"),
               "Copy puts the block's code on the pasteboard (“\(copied.prefix(30))”)")

        // Task boxes tick and untick in the page only.
        await tasksStage(tab, preview)

        // Links go to the app, and the page stays.
        _ = await pageJSON(web, "document.querySelector('a[href=\"https://example.com/kiri\"]').click(); return {};")
        for _ in 0..<20 where opened.urls.isEmpty { await settle(50) }
        _ = await pageJSON(web, "document.querySelector('a[href=\"notes.md\"]').click(); return {};")
        for _ in 0..<20 where opened.urls.count < 2 { await settle(50) }
        let after = await pageJSON(web, "return { href: location.href, blocks: document.querySelectorAll('[data-line]').length };")
        report(opened.urls.first?.absoluteString == "https://example.com/kiri",
               "a web link goes to the browser (\(opened.urls.map(\.absoluteString)))")
        let relative = opened.urls.dropFirst().first.flatMap { MarkdownPage.fileURL(for: $0) }
        report(relative?.lastPathComponent == "notes.md" && relative?.deletingLastPathComponent().path
                   == tab.document.location?.deletingLastPathComponent().standardizedFileURL.path,
               "a link to a file next to it goes to that file (\(relative?.path ?? "none"))")
        report(after?["href"] as? String == page["href"] as? String && (after?["blocks"] as? Int ?? 0) > 50,
               "the page stays as it was after a link (\(after?["href"] ?? "-"))")

        // Scrolled, and back to the text at that part of the file.
        _ = await pageJSON(web, "window.scrollTo(0, document.documentElement.scrollHeight * 0.6); return {};")
        await settle(600)
        let scrolledTo = preview.topLine
        let pressedBack = await press()
        await settle(300)
        let backTop = editorTop()
        report(pressedBack && !tab.showsMarkdownPreview && tab.container.superview === slot && web.superview == nil,
               "⌃⌘P again brings the text back (\(pressedBack), \(tab.showsMarkdownPreview))")
        report(scrolledTo > textTop + 40 && abs(backTop - scrolledTo) <= 3,
               "the text comes back at the part the preview was scrolled to (preview \(scrolledTo), text \(backTop))")
        report(menuItem()?.state == .off, "the menu item is unticked with the text back")

        // Not scrolled: the text stays where it was.
        _ = await press()
        await ready()
        let reopenedTop = preview.topLine
        _ = await press()
        await settle(300)
        report(abs(editorTop() - backTop) <= 1,
               "switching there and back without scrolling leaves the text where it was (\(backTop) → \(editorTop()), preview \(reopenedTop))")

        // Dark restyles the page and the diagrams.
        _ = await press()
        await ready()
        let light = await pageJSON(web, pageScript) ?? [:]
        ThemePreview.shared.show(.appearance(.dark))
        var dark: [String: Any] = [:]
        for _ in 0..<40 {
            await settle(150)
            dark = await pageJSON(web, pageScript) ?? [:]
            if dark["scheme"] as? String == "dark", dark["nodeFill"] as? String != light["nodeFill"] as? String { break }
        }
        report(light["scheme"] as? String == "light" && dark["scheme"] as? String == "dark"
               && dark["fg"] as? String != light["fg"] as? String,
               "dark restyles the page (\(light["fg"] ?? "-") → \(dark["fg"] ?? "-"))")
        report(!(dark["nodeFill"] as? String ?? "").isEmpty && dark["nodeFill"] as? String != light["nodeFill"] as? String,
               "dark draws the diagrams again in its colors (\(light["nodeFill"] ?? "-") → \(dark["nodeFill"] ?? "-"))")
        ThemePreview.shared.end()
        await settle(800)

        // Links that leave Kiri, and pictures from elsewhere.
        if let inside = page["imageSrc"] as? String, !inside.isEmpty {
            await externalStage(tab, preview, inside: inside) { opened.urls }
        } else {
            report(false, "an image next to the file, for the checks of pictures from elsewhere")
        }

        // Another language leaves the preview, and the menu item is off.
        tab.model.language = .plainText
        await settle(400)
        let offItem = menuItem()
        report(offItem?.isEnabled == false, "View ▸ Markdown Preview is off for a file that isn't Markdown")
        if tab.showsMarkdownPreview {
            print("SELFTEST SKIP picking another language leaves the preview (SwiftUI's onChange doesn't run in an occluded window)")
            tab.setMarkdownPreview(false)
        } else {
            report(tab.container.superview === slot, "picking another language leaves the preview for the text")
        }
        tab.model.language = .markdown
        await settle(200)
    }

    /// Task lists in the preview: a click or Space ticks and unticks a
    /// task's box in the page, never the file, and a new rendering of the
    /// text keeps what was ticked. The file is shown as it was afterwards.
    private static func tasksStage(_ tab: DocumentTab, _ preview: MarkdownPreview) async {
        let web = preview.webView
        let fileText = tab.controller.textView?.string ?? tab.document.text
        let tasksScript = """
            const tasks = [...document.querySelectorAll('#kiri-page li.task')];
            return { done: tasks.filter(t => t.classList.contains('done')).length,
                     aria: tasks.filter(t => t.querySelector(':scope > .check')?.getAttribute('aria-checked') === 'true').length,
                     focusable: tasks.filter(t => t.querySelector(':scope > .check')?.tabIndex === 0).length,
                     boxes: tasks.map(t => {
                       const done = t.classList.contains('done');
                       const aria = t.querySelector(':scope > .check')?.getAttribute('aria-checked') === 'true';
                       return done !== aria ? '?' : done ? 'x' : '-';
                     }).join('') };
            """
        let before = await pageJSON(web, tasksScript) ?? [:]
        let clicked = await pageJSON(web, """
            const tasks = [...document.querySelectorAll('#kiri-page li.task')];
            const i = tasks.findIndex(t => !t.classList.contains('done'));
            tasks[i].querySelector(':scope > .check').click();
            return Object.assign({ index: i }, (() => { \(tasksScript) })());
            """) ?? [:]
        report(clicked["done"] as? Int == 3 && clicked["aria"] as? Int == 3 && clicked["focusable"] as? Int == 3,
               "a click ticks a task's box, and each box takes the keyboard (\(clicked))")
        let keyed = await pageJSON(web, """
            const check = document.querySelector('#kiri-page li.task > .check');
            check.focus();
            check.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true, cancelable: true }));
            \(tasksScript)
            """) ?? [:]
        report(keyed["done"] as? Int == 2 && keyed["aria"] as? Int == 2, "Space unticks a ticked box (\(keyed))")
        preview.show(text: fileText + "\n\nOne more line.\n", file: tab.document.location, line: nil)
        await settle(600)
        let rerendered = await pageJSON(web, "return { more: document.body.textContent.includes('One more line.') };")
        let kept = await pageJSON(web, tasksScript) ?? [:]
        // Which boxes, not how many: the file's own may count the same.
        let boxes = keyed["boxes"] as? String
        report(rerendered?["more"] as? Bool == true && boxes != nil && kept["boxes"] as? String == boxes
                   && boxes != before["boxes"] as? String,
               "a new rendering keeps what was ticked and unticked in the page (file \(before["boxes"] ?? "?"), page \(boxes ?? "?"), new rendering \(kept["boxes"] ?? "?"))")
        report((tab.controller.textView?.string ?? tab.document.text) == fileText && !tab.document.isDocumentEdited,
               "ticking a box leaves the file as it was")
        // Back as the file has them, for the checks after these.
        // (The click and Space undo each other when they were on the first.)
        if let ticked = clicked["index"] as? Int, ticked > 0 {
            _ = await pageJSON(web, """
                const checks = document.querySelectorAll('#kiri-page li.task > .check');
                checks[0].click(); checks[\(ticked)].click();
                return {};
                """)
        }
        preview.show(text: fileText, file: tab.document.location, line: nil)
        await settle(600)
    }

    /// What leaves Kiri from a preview. Links: one to an app, to a folder
    /// and to another app's kind of link ask first (answered here, and
    /// nothing is opened: `opened` is what would have been). Pictures: one
    /// from the internet and one from outside the file's folder are held
    /// back, with the tab's notice, until Accept; Deny leaves them out;
    /// Always Deny and Always Allow do so without a notice. The setting
    /// is the test's own (`policyForTests`), the saved one stays. The
    /// preview shows a text of the test's own meanwhile, with the image
    /// `inside` (a URL of the page, in the file's folder), and the file's
    /// again afterwards.
    private static func externalStage(_ tab: DocumentTab, _ preview: MarkdownPreview, inside: String,
                                      opened: () -> [URL]) async {
        let web = preview.webView
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("kiri-preview-outside-\(UUID().uuidString)")
        let picture = folder.appendingPathComponent("outside.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 40, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)
        guard (try? files.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let png = bitmap?.representation(using: .png, properties: [:]), (try? png.write(to: picture)) != nil else {
            report(false, "a picture outside the file's folder, for the checks of pictures from elsewhere")
            return
        }
        defer { try? files.removeItem(at: folder) }

        final class Asked {
            var questions: [LinkQuestion] = []
            var answer = false
        }
        let asked = Asked()
        MarkdownPreview.askedForTests = { asked.questions.append($0); return asked.answer }
        MarkdownPreview.policyForTests = .ask
        MarkdownPreview.forgetAnswersForTests()
        /// As the setting changing tells every preview.
        func settingChanged() {
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        }
        /// The pictures' widths (0: not loaded) and the page's policy.
        func pictures() async -> [String: Any] {
            await pageJSON(web, """
                const width = (alt) => { const i = document.querySelector('img[alt="' + alt + '"]'); return i ? i.naturalWidth : -1; };
                const meta = document.querySelector('meta[http-equiv="Content-Security-Policy"]');
                return { inside: width('inside'), outside: width('outside'), remote: width('remote'),
                         policy: meta ? meta.content : '' };
                """) ?? [:]
        }
        func until(_ done: @autoclosure () -> Bool) async {
            for _ in 0..<60 where !done() { await settle(50) }
        }
        /// The width of the picture named `name`, once it is `width` (or
        /// what it is after three seconds).
        func width(of name: String, is width: Int) async -> Int {
            var got = -2
            for _ in 0..<60 {
                got = await pictures()[name] as? Int ?? -2
                if got == width { break }
                await settle(50)
            }
            return got
        }
        let saved = UserDefaults.standard.string(forKey: Prefs.previewExternalKey)

        // (127.0.0.1:9: nothing listens there, and nothing leaves this Mac.)
        let text = """
            # Elsewhere

            ![inside](\(inside)) ![outside](<\(picture.path)>) ![remote](http://127.0.0.1:9/kiri-test.png)

            [app](/System/Applications/Calculator.app) [folder](<\(folder.path)/>)
            [settings](x-apple.systempreferences:com.apple.preference.security)
            """
        preview.show(text: text, file: tab.document.location, line: 1)
        await until(tab.previewNotice != nil)
        let insideWidth = await width(of: "inside", is: 240)

        // Links.
        func click(_ name: String) async {
            _ = await pageJSON(web, "[...document.querySelectorAll('a')].find(a => a.textContent === '\(name)').click(); return {};")
        }
        let before = opened().count
        await click("app")
        await until(asked.questions.count == 1)
        let app = asked.questions.last
        report(asked.questions.count == 1 && app?.runs == true && app?.title == "Open the app “Calculator”?"
               && opened().count == before,
               "a link to an app asks first, says it runs, and opens nothing on Cancel (“\(app?.title ?? "no question")”, \(app?.runs ?? false))")
        await click("folder")
        await until(asked.questions.count == 2)
        let inFinder = asked.questions.last
        report(asked.questions.count == 2 && inFinder?.runs == false && opened().count == before,
               "a link to a folder asks before another app shows it (“\(inFinder?.title ?? "no question")”)")
        await click("settings")
        await until(asked.questions.count == 3)
        let other = asked.questions.last
        report(asked.questions.count == 3 && other?.title.hasPrefix("Open this link in ") == true && opened().count == before,
               "another app's kind of link asks first (“\(other?.title ?? "no question")”)")
        asked.answer = true
        await click("settings")
        await until(opened().count == before + 1)
        report(opened().last?.scheme == "x-apple.systempreferences" && asked.questions.count == 4,
               "Open hands the link to its app (\(opened().last?.absoluteString ?? "nothing"))")
        asked.answer = false

        // Ask: held back, with the notice.
        var shown = await pictures()
        report(tab.previewNotice == PreviewHeldBack(remote: true, outside: true),
               "a file with a picture from the internet and one from outside its folder shows the notice (\(String(describing: tab.previewNotice)))")
        report(insideWidth == 240 && shown["outside"] as? Int == 0 && shown["remote"] as? Int == 0
               && !(shown["policy"] as? String ?? "http").contains("http"),
               "until then only the picture in the file's folder loads (\(shown))")

        // Accept: the page loads them, and the notice goes.
        preview.answerExternal(accept: true)
        var outside = await width(of: "outside", is: 120)
        shown = await pictures()
        report(outside == 120 && tab.previewNotice == nil && (shown["policy"] as? String ?? "").contains("https:"),
               "Accept loads them and takes the notice away (\(shown), \(String(describing: tab.previewNotice)))")

        // Deny: nothing loads, and the notice goes.
        MarkdownPreview.forgetAnswersForTests()
        settingChanged()
        await until(tab.previewNotice != nil)
        let askedAgain = tab.previewNotice != nil
        preview.answerExternal(accept: false)
        await settle(300)
        shown = await pictures()
        report(askedAgain && tab.previewNotice == nil && shown["outside"] as? Int == 0
               && !(shown["policy"] as? String ?? "http").contains("http"),
               "Deny leaves them out and takes the notice away (asked \(askedAgain), \(shown))")

        // Always Deny and Always Allow: no notice.
        MarkdownPreview.forgetAnswersForTests()
        MarkdownPreview.policyForTests = .deny
        settingChanged()
        await settle(400)
        shown = await pictures()
        report(tab.previewNotice == nil && shown["outside"] as? Int == 0 && shown["remote"] as? Int == 0,
               "Always Deny loads none of them and shows no notice (\(shown))")
        MarkdownPreview.policyForTests = .allow
        settingChanged()
        outside = await width(of: "outside", is: 120)
        report(outside == 120 && tab.previewNotice == nil, "Always Allow loads them and shows no notice (\(outside))")
        report(UserDefaults.standard.string(forKey: Prefs.previewExternalKey) == saved,
               "none of it wrote the saved preference (\(saved ?? "not set"))")

        // The file's own text again.
        MarkdownPreview.policyForTests = nil
        MarkdownPreview.forgetAnswersForTests()
        settingChanged()
        preview.show(text: tab.controller.textView?.string ?? tab.document.text, file: tab.document.location, line: nil)
        await settle(400)
    }

    /// Runs `body` (a function body that returns something JSON can hold)
    /// in Kiri's world of the page.
    private static func pageJSON(_ web: WKWebView, _ body: String) async -> [String: Any]? {
        let text: String? = await withCheckedContinuation { done in
            web.callAsyncJavaScript("return JSON.stringify(await (async () => { \(body) })())", arguments: [:], in: nil,
                                    in: .defaultClient) { result in
                done.resume(returning: (try? result.get()) as? String)
            }
        }
        guard let data = text?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
#endif
