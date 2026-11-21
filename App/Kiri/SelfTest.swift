#if DEBUG || KIRI_SELFTEST
import AppKit
import KiriKit
import SwiftUI
import os

/// A launch-time smoke test for the document plumbing, run with
/// `Kiri.app/Contents/MacOS/Kiri <file> -KiriSelfTest YES`: types into the
/// editor, checks the window turns dirty, saves, checks the bytes on disk,
/// undoes, reverts and quits. Results go to stdout as `SELFTEST …` lines.
@MainActor enum SelfTest {
    private static var started = false
    private static var typedOnLaunch = false
    private static var openedFolder = false
    private static var arrangedTabs = false
    private static var renderedTabs = false
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "KiriSelfTest") }

    static var perf: Bool { UserDefaults.standard.bool(forKey: "KiriPerfTest") }

    static func run(textView: NSTextView) {
        if UserDefaults.standard.bool(forKey: "KiriBehaviorTest"), !started {
            started = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { behavior(textView) }
            return
        }
        // Screenshot helpers: open Settings or Go to Line at launch.
        if UserDefaults.standard.bool(forKey: "KiriDumpMenus") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                func dump(_ m: NSMenu, _ d: Int) {
                    for i in m.items where !i.isSeparatorItem {
                        let mask = i.keyEquivalentModifierMask
                        let mods = (mask.contains(.control) ? "⌃" : "") + (mask.contains(.option) ? "⌥" : "")
                            + (mask.contains(.shift) ? "⇧" : "") + (mask.contains(.command) ? "⌘" : "")
                        let key = i.keyEquivalent.isEmpty ? "" : " [\(mods)\(i.keyEquivalent)]"
                        // With -KiriDumpMenuActions YES: selectors, tags and state too.
                        let action = UserDefaults.standard.bool(forKey: "KiriDumpMenuActions")
                            ? "  <\(i.action.map { NSStringFromSelector($0) } ?? "-") tag=\(i.tag)\(i.isHidden ? " hidden" : "")\(i.isEnabled ? "" : " disabled")\(i.image == nil ? "" : " image")>" : ""
                        print(String(repeating: "  ", count: d) + i.title + key + action)
                        if let sub = i.submenu, d < 2 { dump(sub, d + 1) }
                    }
                }
                if let main = NSApp.mainMenu { dump(main, 0) }
                fflush(stdout)
                NSApp.terminate(nil)
            }
        }
        // Screenshot helpers: type into the document (makes it dirty), and
        // open the find bar searching for a word.
        if let typed = UserDefaults.standard.string(forKey: "KiriTypeOnLaunch"), !typedOnLaunch {
            typedOnLaunch = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                textView.insertText(typed, replacementRange: textView.selectedRange())
            }
        }
        if let query = UserDefaults.standard.string(forKey: "KiriFind") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                textView.window?.makeFirstResponder(textView)
                let pb = NSPasteboard(name: .find)
                pb.clearContents()
                pb.setString(query, forType: .string)
                for action in [NSTextFinder.Action.showFindInterface, .setSearchString, .nextMatch] {
                    let item = NSMenuItem()
                    item.tag = action.rawValue
                    textView.performTextFinderAction(item)
                }
                let r = (textView.string as NSString).range(of: query)
                if r.location != NSNotFound { textView.setSelectedRange(r) }
                textView.performTextFinderAction({ let i = NSMenuItem(); i.tag = NSTextFinder.Action.nextMatch.rawValue; return i }())
            }
        }
        // Screenshot helper: -KiriForceCaret YES shows the caret although the
        // window isn't key (a background launch), keeps it from breathing so
        // every capture has it at full strength, and says where it is.
        // -KiriCaretAt <n> puts it before the document's nth character.
        if UserDefaults.standard.bool(forKey: "KiriForceCaret"), let ktv = textView as? KiriTextView {
            KiriTextView.forceCaretActive = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                ktv.window?.makeFirstResponder(ktv)
                let at = min(UserDefaults.standard.integer(forKey: "KiriCaretAt"), (ktv.string as NSString).length)
                ktv.setSelectedRange(NSRange(location: at, length: 0))
                Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                    MainActor.assumeIsolated { ktv.effects?.update(animated: false) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let rect = ktv.caretRect(), let window = ktv.window else { return }
                    let ink = ktv.caretInkGaps(at: rect)
                    let bar = EditorEffects.caretFrame(insertion: rect, inkBefore: ink.before, inkAfter: ink.after,
                                                       scale: window.backingScaleFactor)
                    // In window points from the top left, as a capture of the window has them.
                    let inWindow = { (r: NSRect) -> String in
                        let w = ktv.convert(r, to: nil)
                        return String(format: "x=%.2f y=%.2f w=%.2f h=%.2f", w.minX, window.frame.height - w.maxY, w.width, w.height)
                    }
                    print("SELFTEST info caret at \(at): insertion \(inWindow(rect)), bar \(inWindow(bar)), ink before \(ink.before) after \(ink.after), effects \(ktv.effects != nil)")
                    fflush(stdout)
                }
            }
        }
        if let path = UserDefaults.standard.string(forKey: "KiriSnapshot") {
            KiriTextView.forceCaretActive = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                textView.window?.makeFirstResponder(textView)
                // Caret inside line 8, after "greet(".
                let ns = textView.string as NSString
                let r = ns.range(of: "greet()")
                if r.location != NSNotFound { textView.setSelectedRange(NSRange(location: r.location + 6, length: 0)) }
            }
            // In-process window picture (for when screen capture isn't
            // available): renders the window's layer tree to a PNG, then quits.
            // -KiriSnapshotTypeAt <seconds>: type "abc" that long before the picture.
            let typeAt = UserDefaults.standard.double(forKey: "KiriSnapshotTypeAt")
            if typeAt > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 - typeAt) {
                    for ch in ["a", "b", "c"] { textView.insertText(ch, replacementRange: textView.selectedRange()) }
                }
            }
            if typeAt > 0 {
                // Also draw the typed line's fragment directly at that moment
                // (layer snapshots catch fragments mid-redraw).
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    guard let tlm = textView.textLayoutManager,
                          let loc = tlm.location(tlm.documentRange.location, offsetBy: textView.selectedRange().location - 1),
                          let fragment = tlm.textLayoutFragment(for: loc) else { return }
                    let b = fragment.renderingSurfaceBounds
                    let scale: CGFloat = 2
                    guard let ctx = CGContext(data: nil, width: Int(b.width * scale) + 20, height: Int(b.height * scale) + 20,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
                    // Flipped, like the text view.
                    ctx.translateBy(x: 0, y: CGFloat(ctx.height))
                    ctx.scaleBy(x: scale, y: -scale)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                    fragment.draw(at: CGPoint(x: -b.minX + 5, y: -b.minY + 5), in: ctx)
                    NSGraphicsContext.restoreGraphicsState()
                    if let image = ctx.makeImage() {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: path + ".fragment.png"))
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                // SwiftUI's hosting layers don't render this way; the editor
                // (AppKit) does, which is what these pictures are for.
                guard let window = textView.window, let frameView = textView.enclosingScrollView?.superview,
                      let layer = frameView.layer else { NSApp.terminate(nil); return }
                let scale = window.backingScaleFactor
                let size = frameView.bounds.size
                guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.scaleBy(x: scale, y: scale)
                if !frameView.isFlipped { /* layers render bottom-up already */ }
                layer.render(in: ctx)
                if let image = ctx.makeImage() {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    print("SELFTEST snapshot \(path)")
                }
                NSApp.terminate(nil)
            }
        }
        if let path = UserDefaults.standard.string(forKey: "KiriRenderSettings") {
            // Settings laid out offscreen (no glass), to check nothing truncates.
            let renderer = ImageRenderer(content: SettingsView().honeyRoot(HoneyAppearance()))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("SELFTEST rendered settings \(path)")
            }
        }
        // -KiriRenderTabs <folder>: the tab strip in the top bar's row, drawn
        // offscreen at 900 and 480 pt with 1 to 20 tabs, long names, a dirty
        // tab and the selection first, in the middle and last. (Offscreen
        // the strip can't scroll; it is placed where scrolling would put it.)
        if let folder = UserDefaults.standard.string(forKey: "KiriRenderTabs"), !renderedTabs {
            renderedTabs = true
            for width in [900.0, 480.0] {
                let renderer = ImageRenderer(content: TabStripSample.sheet(width: width))
                renderer.scale = 2
                let path = "\(folder)/tabs-\(Int(width)).png"
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    print("SELFTEST rendered tabs \(path)")
                }
            }
            fflush(stdout)
        }
        // -KiriShowSettings YES (opened by EditorScreen): nothing in Settings
        // may take keyboard focus, and so a focus ring, just by opening.
        if UserDefaults.standard.bool(forKey: "KiriShowSettings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let w = NSApp.windows.first(where: { $0.identifier?.rawValue == SettingsView.windowID }) else {
                    report(false, "Settings window opened"); return
                }
                report(w.firstResponder === w, "Settings opens with no control focused (first responder \(w.firstResponder.map { "\(type(of: $0))" } ?? "nil"))")
            }
        }
        // -KiriShowShortcuts YES (opened by EditorScreen) with -KiriShortcutsSize
        // 1000x700: the Keyboard Shortcuts window at that size.
        if let size = UserDefaults.standard.string(forKey: "KiriShortcutsSize")?.split(separator: "x").compactMap({ Double($0) }),
           size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let w = NSApp.windows.first(where: { $0.identifier?.rawValue == ShortcutsView.windowID }) else { return }
                w.setFrame(NSRect(x: w.frame.minX, y: w.frame.maxY - size[1], width: size[0], height: size[1]), display: true)
            }
        }
        // -KiriDumpAccessibility <window title>: what VoiceOver is given for
        // that window ("Settings", "Keyboard Shortcuts", "Style Gallery", or a
        // document's file name), as role, label, value, size, selected state,
        // custom actions and help. With -KiriAXPress <label>, then presses the
        // radio button or button of that name and prints again (the radio
        // groups, or after a button everything). Only press what changes
        // nothing that is saved: the Style Gallery's controls, Hide Sidebar.
        // -KiriDumpDelay <seconds> waits longer than 1.5 s before asking.
        if let title = UserDefaults.standard.string(forKey: "KiriDumpAccessibility") {
            let press = UserDefaults.standard.string(forKey: "KiriAXPress")
            // SwiftUI builds its accessibility elements only once an assistive
            // app has asked this process something, so ask it one question
            // through the accessibility API first (off the main thread, which
            // has to answer it), then read the window's own elements.
            // (Launch arguments are strings: `double(forKey:)` reads them, a cast doesn't.)
            let delay = UserDefaults.standard.string(forKey: "KiriDumpDelay") == nil ? 1.5 : UserDefaults.standard.double(forKey: "KiriDumpDelay")
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                var value: AnyObject?
                AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &value)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == title }) else {
                        print("AX no window “\(title)”"); fflush(stdout); return
                    }
                    // SwiftUI's elements answer these without declaring the protocol.
                    func ask(_ e: Any, _ selector: String) -> Any? {
                        let o = e as AnyObject, sel = NSSelectorFromString(selector)
                        return o.responds(to: sel) ? o.perform(sel)?.takeUnretainedValue() : nil
                    }
                    func children(_ e: Any) -> [Any] { ask(e, "accessibilityChildren") as? [Any] ?? [] }
                    func role(_ e: Any) -> String { ask(e, "accessibilityRole") as? String ?? "-" }
                    func name(_ e: Any) -> String {
                        ["accessibilityLabel", "accessibilityTitle"].compactMap { ask(e, $0) as? String }.first { !$0.isEmpty } ?? ""
                    }
                    func dump(_ e: Any, _ depth: Int, onlyRadio: Bool = false) {
                        let r = role(e)
                        if !onlyRadio || r == NSAccessibility.Role.radioGroup.rawValue || r == NSAccessibility.Role.radioButton.rawValue {
                            let value = ask(e, "accessibilityValue").map { " value=\($0)" } ?? ""
                            var size = ""
                            if let o = e as? NSObject, o.responds(to: NSSelectorFromString("accessibilityFrame")),
                               let frame = (o.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue {
                                size = String(format: " %g×%g at %g,%g", frame.width, frame.height, frame.minX, frame.minY)
                            }
                            var extra = ""
                            if let o = e as? NSObject, o.responds(to: NSSelectorFromString("isAccessibilitySelected")),
                               o.value(forKey: "accessibilitySelected") as? Bool == true { extra += " selected" }
                            if let actions = ask(e, "accessibilityCustomActions") as? [NSAccessibilityCustomAction], !actions.isEmpty {
                                extra += " actions=\(actions.map(\.name))"
                            }
                            if let o = e as? NSObject, o.responds(to: NSSelectorFromString("isAccessibilityFocused")),
                               o.value(forKey: "accessibilityFocused") as? Bool == true { extra += " focused" }
                            if let help = ask(e, "accessibilityHelp") as? String, !help.isEmpty { extra += " help=“\(help)”" }
                            print("AX " + String(repeating: "  ", count: depth) + "\(r) “\(name(e))”\(value)\(size)\(extra)")
                        }
                        if depth < 16 { children(e).forEach { dump($0, depth + 1, onlyRadio: onlyRadio) } }
                    }
                    func find(_ e: Any, _ label: String) -> Any? {
                        if [NSAccessibility.Role.radioButton.rawValue, NSAccessibility.Role.button.rawValue].contains(role(e)),
                           name(e) == label { return e }
                        for c in children(e) { if let hit = find(c, label) { return hit } }
                        return nil
                    }
                    dump(window, 0)
                    // -KiriDumpAgain <seconds>: once more that much later,
                    // to see whether something is still moving.
                    let again = UserDefaults.standard.double(forKey: "KiriDumpAgain")
                    if again > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + again) {
                            print("AX again after \(again) s")
                            dump(window, 0)
                            fflush(stdout)
                        }
                    }
                    if let press {
                        guard let button = find(window, press) else { print("AX no button “\(press)”"); fflush(stdout); return }
                        let pressed = (button as AnyObject).responds(to: NSSelectorFromString("accessibilityPerformPress"))
                        let radio = role(button) == NSAccessibility.Role.radioButton.rawValue
                        _ = (button as AnyObject).perform(NSSelectorFromString("accessibilityPerformPress"))
                        print("AX press “\(press)” (responds: \(pressed))")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            dump(window, 0, onlyRadio: radio)
                            fflush(stdout)
                        }
                    }
                    fflush(stdout)
                }
            }
        }
        // Screenshot helper: -KiriOpenFolder <path> opens a folder window, as
        // `kiri <folder>` does (which can't be used here: it activates the app).
        // -KiriOpenFolderFiles <path:path:…> opens those files as its tabs.
        if let folder = UserDefaults.standard.string(forKey: "KiriOpenFolder"), !openedFolder {
            openedFolder = true
            let files = (UserDefaults.standard.string(forKey: "KiriOpenFolderFiles") ?? "").split(separator: ":")
                .map { KiriCLI.Request.Entry.file(URL(fileURLWithPath: String($0)), line: 0, column: 0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                KiriCLI.open(KiriCLI.Request(entries: [.folder(URL(fileURLWithPath: folder))] + files))
            }
        }
        // Screenshot helpers for the tab strip, run once the launch's files
        // are all up and their tab groups have stopped changing:
        // -KiriWindowSize 480x400 sizes the document windows, -KiriDirtyTab
        // <title> types into that tab, -KiriSelectTab <title> selects it.
        // Prints "SELFTEST arranged" when done.
        if !arrangedTabs, ["KiriWindowSize", "KiriDirtyTab", "KiriSelectTab"].contains(where: { UserDefaults.standard.string(forKey: $0) != nil }) {
            arrangedTabs = true
            Task { @MainActor in
                let clock = ContinuousClock()
                var last: [Int] = [], since = clock.now
                var windows: [NSWindow] = []
                while true {
                    try? await Task.sleep(for: .milliseconds(100))
                    windows = NSApp.windows.filter { $0.isVisible && NSDocumentController.shared.document(for: $0) != nil }
                    let now = windows.map { $0.tabbedWindows?.count ?? 1 }
                    if now != last { last = now; since = clock.now }
                    if !windows.isEmpty, clock.now - since > .seconds(1) { break }
                }
                @MainActor func tab(_ key: String) -> NSWindow? {
                    guard let title = UserDefaults.standard.string(forKey: key) else { return nil }
                    for w in windows where w.title == title { return w }
                    return nil
                }
                if let size = UserDefaults.standard.string(forKey: "KiriWindowSize")?.split(separator: "x").compactMap({ Double($0) }),
                   size.count == 2 {
                    for w in windows {
                        w.setFrame(NSRect(x: w.frame.minX, y: w.frame.maxY - size[1], width: size[0], height: size[1]), display: true)
                    }
                }
                if let w = tab("KiriDirtyTab"), let tv = findTextView(in: w.contentView) {
                    // Typing counts as an edit in the tab that is showing.
                    w.tabGroup?.selectedWindow = w
                    try? await Task.sleep(for: .milliseconds(300))
                    w.makeFirstResponder(tv)
                    tv.insertText(" ", replacementRange: NSRange(location: 0, length: 0))
                    // The edit counts once its undo group closes, which
                    // AppKit does after an event; nothing else sends one
                    // to a background launch.
                    if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                        NSApp.postEvent(e, atStart: false)
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if let w = tab("KiriSelectTab") { w.tabGroup?.selectedWindow = w }
                try? await Task.sleep(for: .milliseconds(100))
                print("SELFTEST arranged \(windows.count) windows, front tab “\(windows.first?.tabGroup?.selectedWindow?.title ?? "")”, edited \(windows.filter(\.isDocumentEdited).map(\.title))")
                fflush(stdout)
            }
        }
        if UserDefaults.standard.bool(forKey: "KiriShowGoToLine") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                (textView.delegate as? EditorController)?.model.showGoToLine = true
            }
        }
        if perf, !started {
            started = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { perfTest(textView) }
            return
        }
        print("SELFTEST info makeNSView windows=\(NSApp.windows.map { "\($0.title)|\($0.isVisible)" })")
        guard enabled, !started else { return }
        started = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { step1(textView) }
    }

    private static func report(_ ok: Bool, _ what: String) {
        print("SELFTEST \(ok ? "PASS" : "FAIL") \(what)")
        fflush(stdout)
    }

    private static func step1(_ initial: NSTextView) {
        print("SELFTEST info documents=\(NSDocumentController.shared.documents.map { "\($0.className) \($0.fileURL?.lastPathComponent ?? "-")" })")
        let tv = NSApp.windows.filter(\.isVisible).compactMap { findTextView(in: $0.contentView) }.first ?? initial
        guard let doc = NSDocumentController.shared.documents.first(where: { $0.fileURL != nil }), let url = doc.fileURL else {
            report(false, "no document with a file"); NSApp.terminate(nil); return
        }
        report(tv.textLayoutManager != nil, "TextKit 2")
        report(!doc.isDocumentEdited, "clean after open")
        let before = (try? Data(contentsOf: url)) ?? Data()
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        let fadingDrawsBefore = FadingLayoutFragment.animatedDraws
        // Type like a person: key events through the window.
        tv.window?.makeFirstResponder(tv)
        for ch in "// added\r" {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: tv.window?.windowNumber ?? 0, context: nil,
                                            characters: String(ch), charactersIgnoringModifiers: String(ch),
                                            isARepeat: false, keyCode: ch == "\r" ? 36 : 0) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        }
        print("SELFTEST info undo=\(String(describing: tv.undoManager)) docUndo=\(String(describing: doc.undoManager)) canUndo=\(tv.undoManager?.canUndo ?? false)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        do {
            // Typing animations on: each letter's fragment redraws through its fade.
            if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
                print("SELFTEST SKIP typed letters animate (display asleep: no display-link frames)")
            } else if (tv as? KiriTextView)?.typingFade.mode ?? .none != .none {
                report(FadingLayoutFragment.animatedDraws - fadingDrawsBefore >= 3,
                       "typed letters animate (\(FadingLayoutFragment.animatedDraws - fadingDrawsBefore) fading draws)")
            }
        }
        report(doc.isDocumentEdited || doc.hasUnautosavedChanges, "dirty after typing (edited=\(doc.isDocumentEdited) unautosaved=\(doc.hasUnautosavedChanges) windowEdited=\(tv.window?.isDocumentEdited ?? false) level=\(tv.undoManager?.groupingLevel ?? -1))")
        doc.save(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let after = (try? Data(contentsOf: url)) ?? Data()
            let expected = String(decoding: before, as: UTF8.self).contains("\r\n") ? "// added\r\n" : "// added\n"
            report(after == before + Data(expected.utf8), "saved bytes = original + typed text (\(after.count) bytes)")
            report(!doc.isDocumentEdited, "clean after save")
            tv.undoManager?.undo()
            report(tv.string.hasSuffix("// added\n") == false, "undo removes the typed text")
            report(doc.isDocumentEdited, "dirty after undo")
            // Put the file back as it was.
            try? before.write(to: url)
            try? doc.revert(toContentsOf: url, ofType: doc.fileType ?? "public.plain-text")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let shown = NSApp.windows.compactMap { findTextView(in: $0.contentView) }.first?.string ?? ""
                report(!doc.isDocumentEdited, "clean after revert")
                report(tv.textLayoutManager != nil, "still TextKit 2 at the end")
                if let tv2 = NSApp.windows.compactMap({ findTextView(in: $0.contentView) }).first,
                   let storage = tv2.textStorage, storage.length > 0 {
                    var colors = Set<ObjectIdentifier>()
                    storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
                        if let c = v as AnyObject? { colors.insert(ObjectIdentifier(c)) }
                    }
                    report(colors.count > 1, "highlighted after revert (\(colors.count) colors)")
                }
                report(Data(shown.utf8) == Data(String(decoding: before, as: UTF8.self)
                    .replacingOccurrences(of: "\r\n", with: "\n").utf8), "revert shows the file on disk")
                NSApp.terminate(nil)
            }
        }
    }

    /// Keystrokes through the event loop, each timed until the edit is
    /// recolored (or, without highlighting, displayed).
    private static func perfEventLoop(_ tv: NSTextView, done: @escaping () -> Void) {
        let clock = ContinuousClock()
        var samples: [Duration] = []
        var start = clock.now
        var waiting = false
        var colored = false
        SyntaxHighlighter.onColored = { _ in colored = true }
        let plain = (tv.delegate as? EditorController)?.model.language == .plainText
        func key(_ ch: String) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: tv.window?.windowNumber ?? 0, context: nil, characters: ch,
                                            charactersIgnoringModifiers: ch, isARepeat: false, keyCode: 0) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        }
        func next() {
            guard samples.count < 60 else {
                SyntaxHighlighter.onColored = nil
                let sorted = samples.sorted()
                let avg = samples.reduce(Duration.zero, +) / samples.count
                print("SELFTEST PERF event-loop keystroke→\(plain ? "display" : "recolor"): avg \(avg), p95 \(sorted[sorted.count * 95 / 100]), max \(sorted.last!)")
                fflush(stdout)
                done()
                return
            }
            colored = false
            waiting = true
            start = clock.now
            key("x")
            poll()
        }
        func poll() {
            DispatchQueue.main.async {
                if waiting && (colored || plain) && !(tv.window?.viewsNeedDisplay ?? false) {
                    waiting = false
                    tv.displayIfNeeded()
                    samples.append(clock.now - start)
                    // Like a fast typist: ~12 keys a second.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { next() }
                } else if clock.now - start > .seconds(2) {
                    waiting = false
                    samples.append(clock.now - start)
                    next()
                } else {
                    poll()
                }
            }
        }
        next()
    }

    /// Typing and scrolling cost on whatever file is open (use a big one).
    private static func perfTest(_ initial: NSTextView) {
        let tv = NSApp.windows.filter(\.isVisible).compactMap { findTextView(in: $0.contentView) }.first ?? initial
        let clock = ContinuousClock()
        let len = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: len / 2, length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
        var worst = Duration.zero, total = Duration.zero
        for _ in 0..<100 {
            let d = clock.measure {
                tv.insertText("x", replacementRange: tv.selectedRange())
                tv.displayIfNeeded()
            }
            worst = max(worst, d); total += d
        }
        print("SELFTEST PERF \(len / 1024) KB typing: avg \(total / 100), worst \(worst)")
        var scrollWorst = Duration.zero
        let step = max(1, len / 40)
        for i in 0..<40 {
            let d = clock.measure {
                tv.scrollRangeToVisible(NSRange(location: min(len - 1, i * step), length: 0))
                tv.enclosingScrollView?.displayIfNeeded()
            }
            scrollWorst = max(scrollWorst, d)
        }
        print("SELFTEST PERF jump-scroll worst \(scrollWorst)")
        fflush(stdout)
        tv.setSelectedRange(NSRange(location: len / 2, length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
        tv.window?.makeFirstResponder(tv)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            perfEventLoop(tv) { NSApp.terminate(nil) }
        }
    }

    /// Step 4/5 behaviour that otherwise was only looked at: focus at launch,
    /// the letter fade's redraw, Go to Line, wrapping, Save, tabs.
    private static func behavior(_ initial: NSTextView) {
        let tv = (NSApp.windows.filter(\.isVisible).compactMap { findTextView(in: $0.contentView) }.first ?? initial)
        guard let ktv = tv as? KiriTextView, let controller = ktv.delegate as? EditorController,
              let window = tv.window else { report(false, "editor found"); NSApp.terminate(nil); return }
        report(window.firstResponder === tv, "editor has keyboard focus at launch")

        // Top bar: 10 pt above the 32 pt row, 10 pt below it; traffic lights
        // centred on the row (26 pt from the top).
        let h = window.frame.height
        if let close = window.standardWindowButton(.closeButton), let sv = close.superview {
            let r = sv.convert(close.frame, to: nil)
            let centerFromTop = h - r.midY
            report(abs(centerFromTop - 26) <= 1.5, "traffic lights centred 26 pt from the top (\(centerFromTop))")
        }
        if let container = ktv.enclosingScrollView?.superview {
            let r = container.convert(container.bounds, to: nil)
            let topGap = h - r.maxY
            report(abs(topGap - 52) <= 1, "editor panel starts 52 pt from the top (\(topGap))")
        }

        // Letter fade: each tick must redraw the letter's fragment.
        ktv.setSelectedRange(NSRange(location: 0, length: 0))
        ktv.insertText("z", replacementRange: ktv.selectedRange())
        ktv.displayIfNeeded()
        let d0 = FadingLayoutFragment.animatedDraws
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            ktv.typingFade.tick(); ktv.layoutSubtreeIfNeeded(); ktv.textLayoutManager?.textViewportLayoutController.layoutViewport(); ktv.displayIfNeeded(); CATransaction.flush()
            let d1 = FadingLayoutFragment.animatedDraws
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                ktv.typingFade.tick(); ktv.layoutSubtreeIfNeeded(); ktv.textLayoutManager?.textViewportLayoutController.layoutViewport(); ktv.displayIfNeeded(); CATransaction.flush()
                let d2 = FadingLayoutFragment.animatedDraws
                if ktv.typingFade.mode == .none { print("SELFTEST SKIP letter fade (off; -letterFade YES to test)") } else {
                report(d1 > d0 && d2 > d1, "letter fade redraws on each tick (\(d0) → \(d1) → \(d2)), mode \(ktv.typingFade.mode), items \(ktv.typingFade.items.map(\.range))")
                }
                ktv.undoManager?.undo()

                findMenu(ktv)

                // Go to Line.
                controller.goTo(line: 5, column: 3)
                report(controller.model.line == 5 && controller.model.column == 3,
                       "Go to Line 5:3 lands on Ln \(controller.model.line), Col \(controller.model.column)")

                // Wrap off and on.
                controller.setWrap(false)
                let off = !(ktv.textContainer?.widthTracksTextView ?? true) && ktv.enclosingScrollView?.hasHorizontalScroller == true
                controller.setWrap(true)
                let on = ktv.textContainer?.widthTracksTextView == true && ktv.enclosingScrollView?.hasHorizontalScroller == false
                report(off && on, "wrap lines off and on")

                // Save through the Save button's path.
                let docs = NSDocumentController.shared.documents
                print("SELFTEST info document(for:)=\(String(describing: NSDocumentController.shared.document(for: window))) wc.document=\(String(describing: window.windowController?.document)) docs=\(docs.map { "\($0.className) wcs=\($0.windowControllers.map { $0.window?.windowNumber ?? -1 })" }) window=\(window.windowNumber)")
                fflush(stdout)
                guard let doc = NSDocumentController.shared.document(for: window) else {
                    report(false, "document for the window"); NSApp.terminate(nil); return
                }
                ktv.insertText(" ", replacementRange: NSRange(location: 0, length: 0))
                // Variant: -KiriSaveDelay <s> waits like a person before pressing Save.
                // (A launch argument is a string: `double(forKey:)` reads it, a cast doesn't.)
                let delay = UserDefaults.standard.string(forKey: "KiriSaveDelay") == nil ? 0.3
                    : UserDefaults.standard.double(forKey: "KiriSaveDelay")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let saver = SaveObserver()
                var finished = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    guard !finished else { return }
                    finished = true
                    report(false, "Save button path saves (no callback within 4 s; sheets: \(window.attachedSheet.map { "\(type(of: $0))" } ?? "none"))")
                    tabs(window)
                }
                saver.save(doc) { saved in
                    _ = saver
                    guard !finished else { return }
                    finished = true
                    report(saved && !doc.isDocumentEdited, "Save button path saves (didSave=\(saved))")
                    tabs(window)
                }
                }
            }
        }
    }

    /// Edit ▸ Find is Kiri's own (see `KiriCommands`): its keys, pressed
    /// through the menu bar, must still drive the editor's find bar.
    private static func findMenu(_ ktv: KiriTextView) {
        guard let scroll = ktv.enclosingScrollView, let edit = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu,
              let find = edit.item(withTitle: "Find")?.submenu else { report(false, "Edit ▸ Find exists"); return }
        report(Set(edit.items.compactMap { $0.submenu == nil ? nil : $0.title }).isDisjoint(with: ["Spelling and Grammar", "Substitutions", "Speech"])
               && edit.item(withTitle: "Transformations") != nil,
               "Edit has Find and Transformations, no Spelling, Substitutions or Speech")
        /// Presses the item with this key equivalent, as the menu bar would.
        func press(_ key: String, _ mods: NSEvent.ModifierFlags) -> Bool {
            guard let i = find.items.firstIndex(where: {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == mods
            }), find.items[i].isEnabled else { return false }
            find.performActionForItem(at: i)
            return true
        }
        EditAction.selfTestTarget = ktv
        defer { EditAction.selfTestTarget = nil }
        // The find pasteboard is shared with every other app: put it back after.
        let findBoard = NSPasteboard(name: .find)
        let findBefore = findBoard.string(forType: .string)
        defer {
            findBoard.clearContents()
            if let findBefore { findBoard.setString(findBefore, forType: .string) }
        }
        ktv.window?.makeFirstResponder(ktv)
        let ns = ktv.string as NSString
        let word = ns.range(of: "func")
        ktv.setSelectedRange(word)
        let e = press("e", .command)
        let f = press("f", .command)
        report(e && f && scroll.isFindBarVisible, "⌘E and ⌘F: the find bar opens (pressed \(e) \(f), visible \(scroll.isFindBarVisible))")
        report(findBoard.string(forType: .string) == "func", "⌘E puts the selection on the find pasteboard")
        if word.location != NSNotFound {
            ktv.window?.makeFirstResponder(ktv)
            ktv.setSelectedRange(NSRange(location: 0, length: 0))
            let g = press("g", .command)
            report(g && ktv.selectedRange() == word, "⌘G selects the next match (\(ktv.selectedRange()) vs \(word))")
            ktv.setSelectedRange(NSRange(location: ns.length, length: 0))
            let back = press("g", [.shift, .command])
            report(back && ktv.selectedRange().length == word.length && ktv.selectedRange().location >= word.location,
                   "⇧⌘G selects the previous match (\(ktv.selectedRange()))")
        }
        func hideFindBar() {
            ktv.window?.makeFirstResponder(ktv)
            let hide = NSMenuItem()
            hide.tag = NSTextFinder.Action.hideFindInterface.rawValue
            ktv.performTextFinderAction(hide)
        }
        hideFindBar()
        let hidden = !scroll.isFindBarVisible
        let replace = press("f", [.option, .command])
        report(hidden && replace && scroll.isFindBarVisible, "⌥⌘F opens the find bar again (was hidden \(hidden), pressed \(replace))")
        report(press("j", .command), "⌘J is in the menu")
        // Edit ▸ Transformations, on a selected word.
        hideFindBar()
        if word.location != NSNotFound, let transformations = edit.item(withTitle: "Transformations")?.submenu,
           let upper = transformations.items.firstIndex(where: { $0.title == "Make Upper Case" }) {
            ktv.setSelectedRange(word)
            transformations.performActionForItem(at: upper)
            let now = (ktv.string as NSString).substring(with: word)
            report(now == "FUNC", "Make Upper Case changes the selected word (\(now))")
            ktv.undoManager?.undo()
            report((ktv.string as NSString).substring(with: word) == "func", "and undo puts it back")
        } else {
            report(false, "Edit ▸ Transformations ▸ Make Upper Case exists")
        }
        // Put the window back as it was for the checks that follow.
        hideFindBar()
        ktv.setSelectedRange(NSRange(location: 0, length: 0))
    }

    private static func tabs(_ window: NSWindow) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kiri-tab-test.txt")
        try? "second tab\n".write(to: url, atomically: true, encoding: .utf8)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let count = window.tabbedWindows?.count ?? 1
                report(count == 2, "second document opens as a tab (\(count) tabs)")
                let second = doc?.windowControllers.first?.window
                report(second?.firstResponder is NSTextView, "new tab's editor has focus")
                window.tabGroup?.selectedWindow = window
                report(window.tabGroup?.selectedWindow === window, "selecting a tab")
                second?.performClose(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    report((window.tabbedWindows?.count ?? 1) == 1, "closing a tab")
                    try? FileManager.default.removeItem(at: url)
                    Task { @MainActor in
                        await tabState(window)
                        await manyFiles(window)
                        await crowdedStrip(window)
                        // The last line of a run that got to its end.
                        print("SELFTEST DONE behavior")
                        fflush(stdout)
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    // MARK: The tab strip follows its tabs

    /// `WindowTabs` learns of changes by observation, not by asking four
    /// times a second: a keystroke, a save, undo, Save As, a tab opening,
    /// closing or coming back all show in its `items` within a run-loop
    /// turn or two. Run with its safety-net timer off, so only the
    /// observation can be what did it.
    private static func tabState(_ window: NSWindow) async {
        guard let model = WindowTabs.model(for: window), let doc = NSDocumentController.shared.document(for: window),
              let tv = findTextView(in: window.contentView) else { report(false, "the window's tab model"); return }
        WindowTabs.safetyNetEnabled = false
        defer { WindowTabs.safetyNetEnabled = true }
        let clock = ContinuousClock()
        let quick = Duration.milliseconds(50)
        func ms(_ d: Duration?) -> String { d.map { "\(Int($0 / .milliseconds(1))) ms" } ?? "never" }
        /// How long until `done`, or nil after 3 s.
        func time(_ done: () -> Bool) async -> Duration? {
            let start = clock.now
            while clock.now - start < .seconds(3) {
                if done() { return clock.now - start }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return nil
        }
        /// How long the tab takes to show `dirty` once the document says so.
        func lag(dirty: Bool) async -> (document: Duration?, tab: Duration?) {
            let start = clock.now
            var document: Duration?
            while clock.now - start < .seconds(3) {
                if document == nil, doc.isDocumentEdited == dirty { document = clock.now - start }
                if document != nil, model.items.first?.dirty == dirty, model.dirty == dirty { return (document, clock.now - start) }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return (document, nil)
        }
        func within(_ t: (document: Duration?, tab: Duration?)) -> Bool {
            guard let d = t.document, let tab = t.tab else { return false }
            return tab - d <= quick
        }

        if doc.isDocumentEdited {
            doc.save(withDelegate: nil, didSave: nil, contextInfo: nil)
            _ = await time { !doc.isDocumentEdited && model.items.first?.dirty == false }
        }
        report(model.items.count == 1 && model.items.first?.dirty == false && !model.dirty,
               "the tab starts clean (\(model.items.map { "\($0.title) dirty=\($0.dirty)" }))")

        // One key, typed like a person: through the event loop.
        window.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "x",
                                        charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        // The tab follows at the end of the run-loop turn that handles the
        // key, which a Debug build spends 15 to 40 ms coloring and laying
        // out: 50 ms after the document at most, and 100 ms after the key.
        let typed = await lag(dirty: true)
        report(within(typed) && typed.tab! <= .milliseconds(100),
               "a keystroke turns the tab dirty within 50 ms of the document (document \(ms(typed.document)), tab \(ms(typed.tab)) after the key; safety net off)")

        doc.save(withDelegate: nil, didSave: nil, contextInfo: nil)
        let saved = await lag(dirty: false)
        report(within(saved), "a save clears the tab's dot within 50 ms of the document (document \(ms(saved.document)), tab \(ms(saved.tab)))")

        tv.undoManager?.undo()
        let undone = await lag(dirty: true)
        report(within(undone), "undo past the save turns the tab dirty again (document \(ms(undone.document)), tab \(ms(undone.tab)))")
        tv.undoManager?.redo()
        let redone = await lag(dirty: false)
        report(within(redone), "redo back to the save clears it (document \(ms(redone.document)), tab \(ms(redone.tab)))")

        // A second tab, renamed with Save As while it shows.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kiri-tabstate-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("first-name.txt"), second = dir.appendingPathComponent("second-name.txt")
        try? "a tab\n".write(to: first, atomically: true, encoding: .utf8)
        let opened: NSDocument? = await withCheckedContinuation { c in
            NSDocumentController.shared.openDocument(withContentsOf: first, display: true) { d, _, _ in
                c.resume(returning: d)
            }
        }
        guard let d2 = opened, await time({ Editors.window(for: d2).map { window.tabbedWindows?.contains($0) ?? false } ?? false }) != nil,
              let w2 = Editors.window(for: d2), let model2 = WindowTabs.model(for: w2) else {
            report(false, "a second tab opens for the tab model checks"); return
        }
        let joined = await time { model2.items.map(\.id) == [window.windowNumber, w2.windowNumber] && model2.selected == w2.windowNumber }
        report(joined != nil, "a new tab's strip shows both tabs, itself selected (\(model2.items.map(\.title)), \(ms(joined)))")
        /// The native tab bar's title bar accessory is there and hidden.
        func barHidden(_ w: NSWindow) -> Bool {
            !w.titlebarAccessoryViewControllers.isEmpty && w.titlebarAccessoryViewControllers.allSatisfy(\.isHidden)
        }
        let hidden2 = await time { barHidden(w2) }
        report(hidden2.map { $0 <= quick } ?? false, "the native tab bar is hidden in the new tab (\(ms(hidden2)))")
        // Its own tab grows in beside the ones it joined; it never showed
        // itself alone with the others arriving around it.
        report(model2.shown == [[window.windowNumber], [window.windowNumber, w2.windowNumber]],
               "a new tab first shows the tabs it joins, then itself (\(model2.shown.map(\.count)))")
        report(model2.tabs.last?.tooltip == d2.fileURL.map { TabNames.abbreviatingHome($0.path, home: NSHomeDirectory()) }
               && model2.tabs.first?.tooltip != nil,
               "tabs carry their paths as tooltips (\(model2.tabs.last?.tooltip ?? "none"))")

        let renameStart = clock.now
        var renameDone: Duration?
        d2.save(to: second, ofType: d2.fileType ?? "public.plain-text", for: .saveAsOperation) { _ in
            MainActor.assumeIsolated { renameDone = clock.now - renameStart }
        }
        let renamed = await time { model2.items.last?.path == d2.fileURL?.path && d2.fileURL?.lastPathComponent == "second-name.txt"
            && model2.items.last?.title == d2.displayName }
        _ = await time { renameDone != nil }
        report(renamed != nil && renameDone != nil && renamed! - renameDone! <= quick,
               "Save As renames the tab within 50 ms of the save (“\(model2.items.last?.title ?? "")”, save \(ms(renameDone)), tab \(ms(renamed)))")

        // Back to the first tab: its strip stopped watching while it was
        // away, and is current the moment it shows.
        window.tabGroup?.selectedWindow = window
        let back = await time { model.selected == window.windowNumber && model.items.count == 2 && model.items.last?.path == d2.fileURL?.path }
        report(back.map { $0 <= quick } ?? false, "a tab that comes back shows the group as it is now (\(ms(back)))")
        let hidden1 = await time { barHidden(window) }
        report(hidden1.map { $0 <= quick } ?? false, "and has the native tab bar hidden (\(ms(hidden1)))")

        // The other tab closes while this one shows.
        w2.performClose(nil)
        let closed = await time { model.items.map(\.id) == [window.windowNumber] }
        report(closed.map { $0 <= .milliseconds(300) } ?? false, "a tab closed elsewhere leaves the strip (\(ms(closed)))")
        _ = await time { (window.tabbedWindows?.count ?? 1) == 1 }
    }

    // MARK: Several files at once

    /// Several files opened in one go are tabs of one window: the front one,
    /// a new one (`kiri -n`) or a folder's. Opened the way the `kiri` command
    /// does (`KiriCLI.open`) and the way Finder and the Open panel do
    /// (straight to the document controller, without waiting in between).
    private static func manyFiles(_ original: NSWindow) async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kiri-many-test-\(getpid())")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func files(_ prefix: String, _ count: Int) -> [URL] {
            (1...count).map { i in
                let url = dir.appendingPathComponent("\(prefix)-\(i).txt")
                try? "\(prefix) \(i)\n".write(to: url, atomically: true, encoding: .utf8)
                return url
            }
        }
        func entries(_ urls: [URL]) -> [KiriCLI.Request.Entry] { urls.map { .file($0, line: 0, column: 0) } }
        func group(_ w: NSWindow) -> Set<ObjectIdentifier> { Set((w.tabbedWindows ?? [w]).map { ObjectIdentifier($0) }) }
        /// "8 of 8 open, tab groups [9]": how many of the files have a window,
        /// and the sizes of the tab groups those windows are in.
        func shape(_ ws: [NSWindow], of count: Int) -> String {
            "\(ws.count) of \(count) open, tab groups \(Set(ws.map(group)).map(\.count).sorted(by: >))"
        }
        /// All of `ws` are tabs of one window.
        func together(_ ws: [NSWindow]) -> Bool { Set(ws.map(group)).count == 1 }

        // The `kiri` command, eight files: tabs of the front window.
        let cli = files("cli", 8)
        KiriCLI.open(KiriCLI.Request(entries: entries(cli)))
        var ws = await settledWindows(cli)
        report(ws.count == 8 && together(ws) && group(original).count == 9 && ws.allSatisfy { group($0) == group(original) },
               "kiri with 8 files: all tabs of the front window (\(shape(ws, of: 8)))")

        // Finder or the Open panel, eight files: the same.
        let finder = files("finder", 8)
        for url in finder {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
        ws = await settledWindows(finder)
        report(ws.count == 8 && together(ws) && group(original).count == 17 && ws.allSatisfy { group($0) == group(original) },
               "8 files opened at once without the kiri command: all tabs of the front window (\(shape(ws, of: 8)))")

        // `kiri -n`, four files: one new window, not the front one.
        let fresh = files("new", 4)
        KiriCLI.open(KiriCLI.Request(newWindow: true, entries: entries(fresh)))
        ws = await settledWindows(fresh)
        let freshGroup = ws.first.map(group) ?? []
        report(ws.count == 4 && together(ws) && freshGroup.count == 4 && freshGroup.isDisjoint(with: group(original)),
               "kiri -n with 4 files: one new window (\(shape(ws, of: 4)); front window has \(group(original).count) tabs)")

        // A folder and three files: one folder window holding the files.
        let inFolder = files("folder", 3)
        KiriCLI.open(KiriCLI.Request(entries: [.folder(dir)] + entries(inFolder)))
        ws = await settledWindows(inFolder)
        var sessions = ws.map { FolderSessions.session(for: $0) }
        let folderGroup = ws.first.map(group) ?? []
        report(ws.count == 3 && together(ws) && folderGroup.count == 3
               && folderGroup.isDisjoint(with: group(original)) && folderGroup.isDisjoint(with: freshGroup)
               && sessions.first??.root.url == dir.standardizedFileURL && sessions.allSatisfy { $0 != nil && $0 === sessions.first! },
               "kiri with a folder and 3 files: one folder window with the files (\(shape(ws, of: 3)), \(sessions.compactMap { $0 }.count) with the sidebar)")

        // Three more files while the folder window is in front: tabs of it.
        let more = files("more", 3)
        KiriCLI.open(KiriCLI.Request(entries: entries(more)))
        ws = await settledWindows(more) + ws
        sessions = ws.map { FolderSessions.session(for: $0) }
        report(ws.count == 6 && together(ws) && ws.first.map(group)?.count == 6
               && sessions.allSatisfy { $0 != nil && $0 === sessions.first! },
               "3 more files join the folder window (\(shape(ws, of: 6)), \(sessions.compactMap { $0 }.count) with the sidebar)")
    }

    // MARK: A strip with more tabs than fit

    /// With the seventeen tabs `manyFiles` left in the first window, the
    /// strip scrolls: whichever tab is selected is whole inside it, and the
    /// buttons after it stay inside the window, at the default width and
    /// at the narrowest. Read from what VoiceOver is given, which has the
    /// frames of the real scroll view (pictures drawn offscreen have none).
    private static func crowdedStrip(_ original: NSWindow) async {
        guard let group = original.tabGroup, group.windows.count >= 12 else {
            report(false, "a crowded tab group to look at (\(original.tabGroup?.windows.count ?? 0) tabs)"); return
        }
        await wakeAccessibility()
        let width = original.frame.width
        defer {
            for w in group.windows { w.setFrame(NSRect(x: w.frame.minX, y: w.frame.minY, width: width, height: w.frame.height), display: true) }
        }
        for narrow in [false, true] {
            if narrow {
                for w in group.windows { w.setFrame(NSRect(x: w.frame.minX, y: w.frame.minY, width: 480, height: w.frame.height), display: true) }
            }
            // The last tab is the one a scroll view could leave cut off:
            // selected, it grows past where the content ended.
            for (position, tab) in [("last", group.windows.last), ("first", group.windows.first), ("middle", group.windows[group.windows.count / 2])] {
                guard let tab else { continue }
                group.selectedWindow = tab
                // In front of Kiri's other windows (the app itself stays in
                // the background): SwiftUI leaves a covered window's
                // views alone until it shows.
                tab.orderFront(nil)
                try? await Task.sleep(for: .milliseconds(100))
                // Nor one that can't be seen at all: behind a locked screen
                // or other apps' windows its strip never hears of the
                // selection (`onChange` waits for the window to show).
                guard tab.occlusionState.contains(.visible) else {
                    print("SELFTEST SKIP \(group.windows.count) tabs at \(Int(tab.frame.width)) pt, \(position) selected (the window is covered or the screen locked: SwiftUI isn't updating it)")
                    continue
                }
                // Long enough for the selection's spring to come to rest.
                try? await Task.sleep(for: .milliseconds(900))
                let list = accessibilityElements(of: tab)
                let strip = list.first { $0.role == NSAccessibility.Role.scrollArea.rawValue && $0.name == "Tabs" }?.frame
                let selected = list.first { $0.role == NSAccessibility.Role.button.rawValue && $0.selected }
                let after = list.filter { ["New Tab", "Save"].contains($0.name) }.map(\.frame)
                let inView = strip.map { s in selected.map { $0.frame.minX >= s.minX - 0.5 && $0.frame.maxX <= s.maxX + 0.5 } ?? false } ?? false
                let room = strip.map { s in after.count == 2 && after.allSatisfy { $0.minX >= s.maxX && $0.maxX <= tab.frame.maxX - Honey.gap + 0.5 } } ?? false
                report(inView && room && selected?.name == tab.title,
                       "\(group.windows.count) tabs at \(Int(tab.frame.width)) pt, \(position) selected: whole in the strip, + and Save in the window (strip \(strip.map { "\($0.minX)…\($0.maxX)" } ?? "none"), “\(selected?.name ?? "none")” \(selected.map { "\($0.frame.minX)…\($0.frame.maxX)" } ?? ""), buttons \(after.map { "\($0.minX)…\($0.maxX)" }))")
            }
        }
    }

    /// What VoiceOver is given for a window, flattened: each element's role,
    /// name, frame on screen and whether it is selected.
    private struct AccessibilityElement {
        let role: String, name: String, frame: NSRect, selected: Bool
    }

    /// SwiftUI builds its accessibility elements once something has asked
    /// this process for them, from another thread.
    private static func wakeAccessibility() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                var value: AnyObject?
                AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &value)
                c.resume()
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    private static func accessibilityElements(of root: Any, depth: Int = 0) -> [AccessibilityElement] {
        // SwiftUI's elements answer these without declaring the protocol.
        func ask(_ selector: String) -> Any? {
            let o = root as AnyObject, sel = NSSelectorFromString(selector)
            return o.responds(to: sel) ? o.perform(sel)?.takeUnretainedValue() : nil
        }
        var list: [AccessibilityElement] = []
        if let o = root as? NSObject, o.responds(to: NSSelectorFromString("accessibilityFrame")),
           let frame = (o.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue {
            let name = ["accessibilityLabel", "accessibilityTitle"].compactMap { ask($0) as? String }.first { !$0.isEmpty } ?? ""
            let selected = o.responds(to: NSSelectorFromString("isAccessibilitySelected"))
                && o.value(forKey: "accessibilitySelected") as? Bool == true
            list.append(AccessibilityElement(role: ask("accessibilityRole") as? String ?? "", name: name, frame: frame,
                                             selected: selected))
        }
        guard depth < 16 else { return list }
        for child in ask("accessibilityChildren") as? [Any] ?? [] { list += accessibilityElements(of: child, depth: depth + 1) }
        return list
    }

    /// The windows of the documents for `urls`, once every one of them has a
    /// window and the tab groups have stopped changing (or after 8 s).
    private static func settledWindows(_ urls: [URL]) async -> [NSWindow] {
        let names = Set(urls.map(\.lastPathComponent))
        func windows() -> [NSWindow] {
            NSDocumentController.shared.documents
                .filter { names.contains($0.fileURL?.lastPathComponent ?? "") }
                .compactMap { Editors.window(for: $0) }
        }
        let clock = ContinuousClock()
        let start = clock.now
        var last: [[Int]] = [], since = clock.now
        while clock.now - start < .seconds(8) {
            let ws = windows()
            let now = ws.map { w in (w.tabbedWindows ?? [w]).map { ObjectIdentifier($0).hashValue }.sorted() }
            if now != last { last = now; since = clock.now }
            if ws.count == names.count, clock.now - since > .milliseconds(700) { return ws }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return windows()
    }

    private static func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
        return nil
    }
}

/// The top bar's row laid out as `EditorScreen.topBar` does, around a tab
/// strip of made-up tabs, for `-KiriRenderTabs`.
private struct TabStripSample: View {
    let caption: String
    let tabs: [HoneyTab<Int>]
    let selected: Int
    var sidebar = false
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(.system(size: 10)).foregroundStyle(Color.honeyMuted).padding(.leading, Honey.gap)
            HStack(spacing: 8) {
                HoneyGlassGroup {
                    HStack(spacing: 8) {
                        if sidebar {
                            Button {} label: { Label("Hide Sidebar", systemImage: "sidebar.left") }.buttonStyle(.honeyIcon)
                        }
                        HoneyTabStrip(tabs, selection: .constant(selected), onClose: { _ in })
                        Button {} label: { Label("New Tab", systemImage: "plus") }.buttonStyle(.honeyIcon)
                    }
                }
                Spacer(minLength: 0)
                HoneyTaskButton("Save", systemImage: "square.and.arrow.down", state: .idle) {}
            }
            .padding(.leading, 84)
            .frame(height: 32)
            .padding(.horizontal, Honey.gap)
            .padding(.vertical, 6)
        }
        .frame(width: width, alignment: .leading)
    }

    static let names = ["Greeter.swift", "README.md", "config.yaml", "package.json", "app.ts", "index.html", "styles.css",
                        "server.ts", "main.rs", "lib.rs", "Notes.txt", "x"] + (1...8).map { "extra-\($0).txt" }

    static func tabs(_ titles: [String], dirty: Set<Int> = [1]) -> [HoneyTab<Int>] {
        titles.enumerated().map { HoneyTab(id: $0.offset, title: $0.element, dirty: dirty.contains($0.offset)) }
    }

    @MainActor static func sheet(width: CGFloat) -> some View {
        let long = ["AppDelegate+NotificationHandling.swift", "a-very-long-configuration-file-name.production.yaml", "x"]
        var rows: [TabStripSample] = [
            TabStripSample(caption: "1 tab", tabs: tabs(["sample.swift"], dirty: []), selected: 0, width: width),
            TabStripSample(caption: "1 tab, unsaved", tabs: tabs(["sample.swift"], dirty: [0]), selected: 0, width: width),
            TabStripSample(caption: "1 long name", tabs: tabs([long[0]], dirty: []), selected: 0, width: width),
        ]
        for count in [4, 8, 12, 20] {
            for selected in Set([0, count / 2, count - 1]).sorted() {
                rows.append(TabStripSample(caption: "\(count) tabs, tab \(selected + 1) selected, tab 2 unsaved",
                                           tabs: tabs(Array(names.prefix(count))), selected: selected, width: width))
            }
        }
        for selected in 0..<3 {
            rows.append(TabStripSample(caption: "long names, tab \(selected + 1) selected", tabs: tabs(long), selected: selected,
                                       width: width))
        }
        // Same names in different folders, as `WindowTabs.tabs` tells them apart.
        let paths = ["/p/api/index.ts", "/p/web/index.ts", "/p/README.md", "/p/a/src/main.swift", "/p/b/src/main.swift"]
        let titles = paths.map { ($0 as NSString).lastPathComponent }
        let details = TabNames.details(titles: titles, paths: paths)
        for selected in [0, 3] {
            rows.append(TabStripSample(caption: "same names, tab \(selected + 1) selected", tabs: titles.indices.map {
                HoneyTab(id: $0, title: titles[$0], detail: details[$0], dirty: $0 == 1)
            }, selected: selected, width: width))
        }
        rows.append(TabStripSample(caption: "folder window, 4 tabs", tabs: tabs(Array(names.prefix(4))), selected: 3,
                                   sidebar: true, width: width))
        rows.append(TabStripSample(caption: "folder window, 12 tabs", tabs: tabs(Array(names.prefix(12))), selected: 6,
                                   sidebar: true, width: width))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { rows[$0] }
        }
        .background(Color.honeyCanvas)
        .environment(\.honeyOffscreen, true)
        .honeyRoot(HoneyAppearance())
    }
}
#endif
