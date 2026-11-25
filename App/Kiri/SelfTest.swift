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
    private static var openedLater = false
    private static var renderedTabs = false
    private static var renderedFind = false
    private static var renderedChrome = false
    private static var renderedSave = false
    private static var renderedSettings = false
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "KiriSelfTest") }

    static var perf: Bool { UserDefaults.standard.bool(forKey: "KiriPerfTest") }

    static func run(textView: NSTextView) {
        if isTestLaunch { closeDocumentsWhenStopped() }
        if UserDefaults.standard.bool(forKey: "KiriBehaviorTest"), !started {
            started = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { behavior(textView) }
            return
        }
        // -KiriSidebarTest YES: the folder sidebar's checks alone (they are
        // part of -KiriBehaviorTest too).
        if UserDefaults.standard.bool(forKey: "KiriSidebarTest"), !started {
            started = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let window = textView.window else { report(false, "a window for the sidebar checks"); quit(); return }
                FrontEditor.shared.selfTestMain(window)
                Task { @MainActor in
                    await sidebarStage(window)
                    reportStayedInTheBackground()
                    print("SELFTEST DONE sidebar")
                    fflush(stdout)
                    quit()
                }
            }
            return
        }
        // -KiriSettingsTest YES: Settings' checks alone (part of
        // -KiriBehaviorTest too).
        if UserDefaults.standard.bool(forKey: "KiriSettingsTest"), !started {
            started = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let window = textView.window else { report(false, "a window for Settings' checks"); quit(); return }
                FrontEditor.shared.selfTestMain(window)
                Task { @MainActor in
                    await settingsStage(window)
                    reportStayedInTheBackground()
                    print("SELFTEST DONE settings")
                    fflush(stdout)
                    quit()
                }
            }
            return
        }
        // -KiriWhatsNewTest YES (with -KiriShowWhatsNew <notes>): What's
        // new's checks alone (`WhatsNewSelfTest.swift`).
        if UserDefaults.standard.bool(forKey: "KiriWhatsNewTest"), !started {
            started = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let window = textView.window else { report(false, "a window for What's new's checks"); quit(); return }
                FrontEditor.shared.selfTestMain(window)
                Task { @MainActor in
                    await whatsNewStage(window, textView: textView)
                    reportStayedInTheBackground()
                    print("SELFTEST DONE whats-new")
                    fflush(stdout)
                    quit()
                }
            }
            return
        }
        // The command palette's flags (`PaletteSelfTest.swift`).
        if paletteFlags(textView) { return }
        // The feedback window's flags (`FeedbackSelfTest.swift`).
        if feedbackFlags(textView) { return }
        if let phase = UserDefaults.standard.string(forKey: "KiriRelaunchTest") {
            guard !started else { return }
            started = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { relaunch(phase, textView) }
            return
        }
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
                // -KiriDumpMenusFront YES: the menus as they are with the
                // document window in front. A background launch has no main
                // window, and SwiftUI brings a menu up to date only when it
                // is about to open, so the test says the one and does the
                // other. (The symbols macOS gives items by itself are not
                // back yet after that; the plain dump has them.)
                let front = UserDefaults.standard.bool(forKey: "KiriDumpMenusFront")
                if front { FrontEditor.shared.selfTestMain(textView.window) }
                DispatchQueue.main.asyncAfter(deadline: .now() + (front ? 0.5 : 0)) {
                    if let main = NSApp.mainMenu {
                        if front { updateMenu(main) }
                        dump(main, 0)
                    }
                    fflush(stdout)
                    quit()
                }
            }
        }
        // Screenshot helper: type into the document (makes it dirty).
        if let typed = UserDefaults.standard.string(forKey: "KiriTypeOnLaunch"), !typedOnLaunch {
            typedOnLaunch = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                textView.insertText(typed, replacementRange: textView.selectedRange())
                // An event closes the undo group, and the document then
                // knows it is edited (the tab's dot, the Save pill).
                if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        }
        // Screenshot helpers: -KiriFind <word> opens the Honey find bar on
        // that query, at its first match from the caret. -KiriFindReplace
        // <text> opens the replace row with that in it, -KiriFindRegex YES
        // and -KiriFindCase YES set the toggles, -KiriFindNext <n> goes on n
        // matches. (On a pasteboard of its own: the shared find pasteboard
        // is the person's.)
        if let query = UserDefaults.standard.string(forKey: "KiriFind") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard let find = (textView.delegate as? EditorController)?.model.find else { return }
                find.board = NSPasteboard.withUniqueName()
                textView.window?.makeFirstResponder(textView)
                let replacement = UserDefaults.standard.string(forKey: "KiriFindReplace")
                find.show(replace: replacement != nil)
                find.options = SearchOptions(matchCase: UserDefaults.standard.bool(forKey: "KiriFindCase"),
                                             regularExpression: UserDefaults.standard.bool(forKey: "KiriFindRegex"))
                find.replacement = replacement ?? ""
                find.query = query
                for _ in 0..<UserDefaults.standard.integer(forKey: "KiriFindNext") { find.step(forward: true) }
                print("SELFTEST info find “\(query)”: \(find.label)")
                fflush(stdout)
            }
        }
        // -KiriRenderFind <folder>: the find bar in its
        // states, drawn offscreen (no window, so no glass: the solid Honey
        // fill stands in for it).
        if let folder = UserDefaults.standard.string(forKey: "KiriRenderFind"), !renderedFind {
            renderedFind = true
            for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                let renderer = ImageRenderer(content: FindBarSample.sheet(scheme))
                renderer.scale = 2
                let path = "\(folder)/find-bar-\(Honey.theme.id)-\(name).png"
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    print("SELFTEST rendered find \(path)")
                }
            }
            fflush(stdout)
        }
        // -KiriRenderStatus <folder> and -KiriRenderHint <folder>: the status
        // bar in its states (at rest, each item hovered, focused, faded over
        // text, a selection, a long file, panels too narrow for all of it)
        // and the first-run hint in panels of the sizes a window can give
        // it, drawn offscreen in light and dark.
        if !renderedChrome {
            renderedChrome = true
            for (key, name) in [("KiriRenderStatus", "status-bar"), ("KiriRenderHint", "start-hint")] {
                guard let folder = UserDefaults.standard.string(forKey: key) else { continue }
                for (mode, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                    let renderer = key == "KiriRenderStatus" ? ImageRenderer(content: AnyView(StatusBarSample.sheet(scheme)))
                        : ImageRenderer(content: AnyView(StartHintSample.sheet(scheme)))
                    renderer.scale = 2
                    let path = "\(folder)/\(name)-\(Honey.theme.id)-\(mode).png"
                    if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                        print("SELFTEST rendered \(name) \(path)")
                    }
                }
            }
            fflush(stdout)
        }
        // -KiriEditorSnapshot <png>: the editor's own layers (text, selection,
        // current line, find and Go to Line marks) on the panel's color,
        // drawn to a file 3 s after launch. For when the screen can't be
        // captured; the SwiftUI chrome around the editor is not in it.
        if let path = UserDefaults.standard.string(forKey: "KiriEditorSnapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let frameView = textView.enclosingScrollView?.superview, let layer = frameView.layer else { return }
                (textView as? KiriTextView)?.marksIfLoaded?.update()
                let scale: CGFloat = 2, size = frameView.bounds.size
                guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                textView.effectiveAppearance.performAsCurrentDrawingAppearance {
                    ctx.setFillColor(NSColor.honey(Honey.surface).cgColor)
                }
                ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
                ctx.scaleBy(x: scale, y: scale)
                layer.render(in: ctx)
                if let image = ctx.makeImage() {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path))
                    let origin = textView.enclosingScrollView?.contentView.bounds.origin ?? .zero
                    print("SELFTEST editor snapshot \(path) (scrolled to \(origin.y), top inset \(textView.enclosingScrollView?.contentInsets.top ?? 0))")
                    fflush(stdout)
                }
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
                      let layer = frameView.layer else { quit(); return }
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
                quit()
            }
        }
        // -KiriRenderSettings <folder>: Settings laid out offscreen (no
        // glass, and switches and menus as AppKit's placeholders), to check
        // nothing truncates, in every color theme, light and dark, and the
        // swatches alone at their size and at half of it. (A path ending in
        // .png: the window as it is, once.)
        if let path = UserDefaults.standard.string(forKey: "KiriRenderSettings"), !renderedSettings {
            renderedSettings = true
            func write(_ image: NSImage?, _ path: String) {
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("SELFTEST rendered settings \(path)")
            }
            if path.hasSuffix(".png") {
                let renderer = ImageRenderer(content: SettingsView(scrolls: false).honeyRoot(HoneyAppearance()))
                renderer.scale = 2
                write(renderer.nsImage, path)
            } else {
                let chosen = Honey.theme
                ThemeController.selfTestHoldsTheme = true
                for (mode, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                    for theme in Honey.Theme.all {
                        // For this picture only; the saved theme comes back below.
                        Honey.theme = theme
                        let renderer = ImageRenderer(content: SettingsView(scrolls: false)
                            .environment(\.honeyOffscreen, true).environment(\.colorScheme, scheme).honeyRoot(HoneyAppearance()))
                        renderer.scale = 2
                        write(renderer.nsImage, "\(path)/settings-\(theme.id)-\(mode).png")
                    }
                    Honey.theme = chosen
                    for scale in [1.0, 0.5] {
                        let renderer = ImageRenderer(content: ThemePicker(chosen: chosen.id).frame(width: 552)
                            .padding(24).background(Color.honeySurface)
                            .environment(\.honeyOffscreen, true).environment(\.colorScheme, scheme).honeyRoot(HoneyAppearance()))
                        renderer.scale = 2 * scale
                        write(renderer.nsImage, "\(path)/swatches-\(mode)-\(scale == 1 ? "full" : "half").png")
                    }
                }
                ThemeController.selfTestHoldsTheme = false
                Honey.theme = chosen
            }
            fflush(stdout)
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
        themeFadeDemo()
        // -KiriRenderSave <folder>: the Save button's states in the top bar's
        // row, in every color theme, light and dark, one sheet for each
        // (offscreen: the solid Honey fills stand in for the glass).
        if let folder = UserDefaults.standard.string(forKey: "KiriRenderSave"), !renderedSave {
            renderedSave = true
            let chosen = Honey.theme
            for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                let blocks: [NSImage] = Honey.Theme.all.compactMap { theme in
                    // For this picture only; the saved theme comes back below.
                    Honey.theme = theme
                    let renderer = ImageRenderer(content: SaveButtonSample.block(theme, scheme))
                    renderer.scale = 2
                    return renderer.nsImage
                }
                let path = "\(folder)/save-button-\(name).png"
                if let png = contactSheet(blocks, columns: 2) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("SELFTEST rendered save \(path)")
                }
            }
            Honey.theme = chosen
            print("SELFTEST info Save widths: resting \(SaveButtonSample.width(.idle, pending: false)), pill \(SaveButtonSample.width(.idle, pending: true)), a plain label pill \(SaveButtonSample.plainPillWidth)")
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
        // Screenshot helper: -KiriOpenLater <path:path:…> opens those files
        // one after another, 1.5 s apart, as ⌘O does (which can't be used
        // here: the Open panel needs the app in front).
        if let later = UserDefaults.standard.string(forKey: "KiriOpenLater"), !openedLater {
            openedLater = true
            for (i, path) in later.split(separator: ":").enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 * Double(i + 1)) {
                    print("SELFTEST info opening \(path) at \(ProcessInfo.processInfo.systemUptime)")
                    fflush(stdout)
                    NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: String(path)), display: true) { _, _, _ in }
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
            // -KiriSidebarKeep <path:path:…> then double-clicks those files'
            // rows (each opens to stay), -KiriSidebarType <path:path:…> does
            // the same and types a line into each (unsaved changes), and
            // -KiriSidebarClick <path:path:…> clicks those, one after
            // another (each shows in the preview tab).
            func paths(_ key: String) -> [URL] {
                (UserDefaults.standard.string(forKey: key) ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            }
            var clicks = paths("KiriSidebarKeep").map { ($0, true, false) } + paths("KiriSidebarType").map { ($0, true, true) }
                + paths("KiriSidebarClick").map { ($0, false, false) }
            let root = URL(fileURLWithPath: folder).standardizedFileURL
            // After those: -KiriSidebarRename <path> puts the Rename… field
            // on that file's row and -KiriSidebarNewFile <folder> the New
            // File… field in that folder; -KiriSidebarName <name> then gives
            // that name (one that is taken shows the reason; pictures only
            // use such a name, so nothing is made or renamed).
            func name() {
                guard let window = NSApp.windows.first(where: { $0.isVisible && FolderSessions.session(for: $0)?.root.url == root }),
                      let session = FolderSessions.session(for: window) else { return }
                if let path = UserDefaults.standard.string(forKey: "KiriSidebarRename") {
                    session.beginRename(URL(fileURLWithPath: path).standardizedFileURL, in: window)
                } else if let path = UserDefaults.standard.string(forKey: "KiriSidebarNewFile") {
                    session.beginNewFile(in: URL(fileURLWithPath: path).standardizedFileURL, in: window)
                } else {
                    return
                }
                if let name = UserDefaults.standard.string(forKey: "KiriSidebarName") { session.commitEdit(name) }
                // -KiriSidebarTypeName <name> types it into the field as
                // keys instead (with -KiriSidebarTypeReturn YES, then
                // Return: only in a folder that is the test's to change).
                if let name = UserDefaults.standard.string(forKey: "KiriSidebarTypeName") {
                    let end = UserDefaults.standard.bool(forKey: "KiriSidebarTypeReturn") ? "\r" : ""
                    Task { @MainActor in
                        for _ in 0..<40 where fieldEditor(of: window) == nil { try? await Task.sleep(for: .milliseconds(50)) }
                        let typed = await typeKeys(name + end, in: window)
                        print("SELFTEST info typed “\(name)” into the sidebar's name field: \(typed); the field holds “\(fieldEditor(of: window)?.string ?? "no field")”, editing \(String(describing: session.editing)), cursor \(session.cursor?.lastPathComponent ?? "none")")
                        fflush(stdout)
                    }
                }
            }
            func click() {
                guard !clicks.isEmpty else { name(); return }
                guard let window = NSApp.windows.first(where: { $0.isVisible && FolderSessions.session(for: $0)?.root.url == root }) else { return }
                let (url, keep, type) = clicks.removeFirst()
                SidebarOpen.open(url, keep: keep, from: window) { shown in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if type, let text = shown.flatMap({ findTextView(in: $0.contentView) }) {
                            text.insertText("unsaved ", replacementRange: NSRange(location: 0, length: 0))
                        }
                        click()
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                KiriCLI.open(KiriCLI.Request(entries: [.folder(URL(fileURLWithPath: folder))] + files)) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { click() }
                }
            }
        }
        // Screenshot helpers for the tab strip, run once the launch's files
        // are all up and their windows' tabs have stopped changing:
        // -KiriWindowSize 480x400 sizes the document windows, -KiriDirtyTab
        // <title> types into that tab, -KiriSelectTab <title> selects it.
        // Prints "SELFTEST arranged" when done.
        if !arrangedTabs, ["KiriWindowSize", "KiriDirtyTab", "KiriSelectTab"].contains(where: { UserDefaults.standard.string(forKey: $0) != nil }) {
            arrangedTabs = true
            Task { @MainActor in
                let clock = ContinuousClock()
                var last: [Int] = [], since = clock.now
                var windows: [DocumentNSWindow] = []
                while true {
                    try? await Task.sleep(for: .milliseconds(100))
                    windows = DocumentWindow.all.filter(\.isVisible)
                    let now = windows.map { $0.tabs.list.count }
                    if now != last { last = now; since = clock.now }
                    if !windows.isEmpty, clock.now - since > .seconds(1) { break }
                }
                @MainActor func tab(_ key: String) -> DocumentTab? {
                    guard let title = UserDefaults.standard.string(forKey: key) else { return nil }
                    for w in windows { for t in w.tabs.list where t.document.displayName == title { return t } }
                    return nil
                }
                if let size = UserDefaults.standard.string(forKey: "KiriWindowSize")?.split(separator: "x").compactMap({ Double($0) }),
                   size.count == 2 {
                    for w in windows {
                        w.setFrame(NSRect(x: w.frame.minX, y: w.frame.maxY - size[1], width: size[0], height: size[1]), display: true)
                    }
                }
                if let t = tab("KiriDirtyTab"), let w = t.window {
                    // Typing counts as an edit in the tab that is showing.
                    w.tabs.select(t)
                    try? await Task.sleep(for: .milliseconds(300))
                    let tv = t.container.textView
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
                if let t = tab("KiriSelectTab") { t.window?.tabs.select(t) }
                try? await Task.sleep(for: .milliseconds(100))
                let edited = windows.flatMap(\.tabs.list).filter { $0.document.isDocumentEdited }.map(\.document.displayName)
                print("SELFTEST arranged \(windows.count) windows, front tab “\(windows.first?.tabs.selectedTab?.document.displayName ?? "")”, edited \(edited)")
                fflush(stdout)
            }
        }
        // Screenshot helpers for the status bar: -KiriStatusRest YES keeps it
        // at rest, as while typing. (-KiriStatusShow <item>:<hover|focus>
        // draws an item hovered or focused; `EditorStatusBar` reads it.)
        if UserDefaults.standard.bool(forKey: "KiriStatusRest") {
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                MainActor.assumeIsolated { (textView.delegate as? EditorController)?.model.statusRest.activity() }
            }
        }
        // -KiriScrollerInfo YES (with -wrapLines NO and a file with long
        // lines): where the horizontal scroller is against the status capsule.
        if UserDefaults.standard.bool(forKey: "KiriScrollerInfo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { scrollerInfo(textView) }
        }
        // -KiriShowGoToLine YES opens Go to Line (the palette with its
        // colon); -KiriGoToLine <text> also types that after the colon
        // (the line shows as it is typed).
        if UserDefaults.standard.bool(forKey: "KiriShowGoToLine") || UserDefaults.standard.string(forKey: "KiriGoToLine") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let model = (textView.delegate as? EditorController)?.model else { return }
                model.goToLine.open()
                if let text = UserDefaults.standard.string(forKey: "KiriGoToLine") { model.palette.text = ":" + text }
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

    /// Called before the app has opened anything. A launch with a Debug
    /// flag types into documents, saves and closes them, so it has to be
    /// one that leaves saved state alone (`-ApplePersistenceIgnoreState
    /// YES`): AppKit then neither restores the person's windows nor reopens
    /// their unsaved documents into the test, and keeps the test's own
    /// recovery copies in the temporary folder. Without it, nothing runs.
    static func guardLaunch() {
        guard isTestLaunch else { return }
        stayInTheBackground()
        // (A copy under another bundle identifier has state of its own:
        // the relaunch tests, which need AppKit to reopen things, run so.)
        guard UserDefaults.standard.bool(forKey: "ApplePersistenceIgnoreState") || !isKiriItself else {
            print("SELFTEST FAIL refusing to run: launch with -ApplePersistenceIgnoreState YES, so the test can't touch your windows or unsaved documents")
            fflush(stdout)
            exit(2)
        }
        watchRelaunch()
    }

    /// A test launch never becomes the front app: the person is working
    /// in another one, and a test that came forward would take the
    /// keyboard from them. AppKit activates an app by itself when it opens
    /// the files it was launched with (`-[NSApplication _doOpenFile:…]`,
    /// from `finishLaunching`) and when it reopens windows, and Kiri does
    /// for a `kiri` request. In a test launch every way of asking is
    /// turned into nothing, before anything is opened: the public calls,
    /// and `_activateWithInfo:`, which AppKit's own requests go through.
    /// (A click on one of the test's windows still brings it forward:
    /// that is the person's doing.) `-KiriTraceActivation YES` prints who
    /// asked.
    private static func stayInTheBackground() {
        func replace(_ type: AnyClass, _ selector: String, with block: Any) {
            guard let method = class_getInstanceMethod(type, NSSelectorFromString(selector)) else { return }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        func asked(_ how: String) {
            activationRequests += 1
            guard UserDefaults.standard.bool(forKey: "KiriTraceActivation") else { return }
            print("SELFTEST info activation asked (\(how)) and refused, by:\n" + Thread.callStackSymbols.dropFirst(2).prefix(14).joined(separator: "\n"))
            fflush(stdout)
        }
        let withInfo: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in asked("_activateWithInfo:") }
        replace(NSApplication.self, "_activateWithInfo:", with: withInfo)
        let ignoring: @convention(block) (AnyObject, Bool) -> Void = { _, _ in asked("activateIgnoringOtherApps:") }
        replace(NSApplication.self, "activateIgnoringOtherApps:", with: ignoring)
        let plain: @convention(block) (AnyObject) -> Void = { _ in asked("activate") }
        replace(NSApplication.self, "activate", with: plain)
        let event: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in asked("activateUsingEvent:") }
        replace(NSApplication.self, "activateUsingEvent:", with: event)
        let running: @convention(block) (AnyObject, UInt) -> Bool = { _, _ in asked("NSRunningApplication activateWithOptions:"); return false }
        replace(NSRunningApplication.self, "activateWithOptions:", with: running)
        let from: @convention(block) (AnyObject, AnyObject?, UInt) -> Bool = { _, _, _ in
            asked("NSRunningApplication activateFromApplication:options:"); return false
        }
        replace(NSRunningApplication.self, "activateFromApplication:options:", with: from)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                activations += 1
                // What brought it: a click on one of its windows is a mouse event.
                let event = NSApp.currentEvent.map { "\($0.type.rawValue == 13 ? "an AppKit event, subtype \($0.subtype.rawValue)" : "event type \($0.type.rawValue)")" } ?? "no event"
                print("SELFTEST info this test launch became the front app (\(event); modal: \(NSApp.modalWindow != nil); key window: \(NSApp.keyWindow?.title ?? "none"))")
                fflush(stdout)
            }
        }
    }

    /// How often this launch was asked to come forward (and didn't), and
    /// how often it became the front app all the same.
    nonisolated(unsafe) private static var activationRequests = 0
    private static var activations = 0

    /// The last check of a run: it stayed behind the app the person is in.
    static func reportStayedInTheBackground() {
        report(activations == 0 && !NSApp.isActive,
               "the test launch never became the front app (asked \(activationRequests) times, came forward \(activations) times; a click on one of its windows counts)")
    }

    /// A test that is stopped (`kill`) leaves no recovery copies behind: its
    /// documents are closed first. If the main thread is stuck and can't do
    /// that, the process goes anyway two seconds later.
    private static func closeDocumentsWhenStopped() {
        guard stopSources.isEmpty else { return }
        signal(SIGTERM, SIG_IGN)
        let close = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        close.setEventHandler {
            discardDocuments()
            exit(0)
        }
        let giveUp = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        giveUp.setEventHandler { @Sendable in
            Thread.sleep(forTimeInterval: 2)
            _exit(1)
        }
        for source in [close, giveUp] { source.resume() }
        stopSources = [close, giveUp]
    }

    private static var stopSources: [DispatchSourceSignal] = []

    /// Sets (or with nil takes away) a setting among this launch's
    /// arguments, which is where one given on the command line lives:
    /// `UserDefaults.standard` answers with it, and nothing is saved.
    static func setArgument(_ key: String, _ value: String?) {
        let domain = UserDefaults.argumentDomain
        var arguments = UserDefaults.standard.volatileDomain(forName: domain)
        arguments[key] = value
        UserDefaults.standard.removeVolatileDomain(forName: domain)
        UserDefaults.standard.setVolatileDomain(arguments, forName: domain)
    }

    /// This launch has a Debug flag (`-Kiri…`): it is a test or a picture.
    static let isTestLaunch = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-Kiri") }
    /// This is Kiri under its own bundle identifier, sharing the person's
    /// preferences, saved state and recovery records.
    static let isKiriItself = Bundle.main.bundleIdentifier == "se.hellsoft.kiri"

    /// Closes every document as it is: nothing is saved, and AppKit deletes
    /// their recovery copies.
    private static func discardDocuments() {
        for document in NSDocumentController.shared.documents { document.close() }
    }

    /// The end of a run: quits without the unsaved-changes prompt, which
    /// nobody is there to answer.
    static func quit() {
        discardDocuments()
        NSApp.terminate(nil)
    }

    /// SwiftUI brings a menu up to date when it is about to open or a key
    /// is looked up in it, which nothing does in a background launch.
    static func updateMenu(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items { if let sub = item.submenu { updateMenu(sub) } }
    }

    /// Pictures side by side in rows of `columns`, as one PNG.
    static func contactSheet(_ images: [NSImage], columns: Int) -> Data? {
        guard let first = images.first else { return nil }
        let cell = images.reduce(first.size) { NSSize(width: max($0.width, $1.size.width), height: max($0.height, $1.size.height)) }
        let rows = (images.count + columns - 1) / columns
        let size = NSSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // In points, before the context is made: it draws at 2x then.
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for (i, image) in images.enumerated() {
            let origin = NSPoint(x: CGFloat(i % columns) * cell.width, y: size.height - CGFloat(i / columns + 1) * cell.height)
            image.draw(in: NSRect(origin: origin, size: image.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func report(_ ok: Bool, _ what: String) {
        print("SELFTEST \(ok ? "PASS" : "FAIL") \(what)")
        fflush(stdout)
    }

    private static func step1(_ initial: NSTextView) {
        print("SELFTEST info documents=\(NSDocumentController.shared.documents.map { "\($0.className) \($0.fileURL?.lastPathComponent ?? "-")" })")
        let tv = NSApp.windows.filter(\.isVisible).compactMap { findTextView(in: $0.contentView) }.first ?? initial
        guard let doc = NSDocumentController.shared.documents.first(where: { $0.fileURL != nil }), let url = doc.fileURL else {
            report(false, "no document with a file"); quit(); return
        }
        report(tv.textLayoutManager != nil, "TextKit 2")
        report(!doc.isDocumentEdited, "clean after open")
        probeDocument(doc)
        let before = (try? Data(contentsOf: url)) ?? Data()
        let untouched = FileState(url)
        let expected = String(decoding: before, as: UTF8.self).contains("\r\n") ? "// added\r\n" : "// added\n"
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
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
        report(doc.isDocumentEdited && tv.window?.isDocumentEdited == true, "dirty after typing (edited=\(doc.isDocumentEdited) unautosaved=\(doc.hasUnautosavedChanges) windowEdited=\(tv.window?.isDocumentEdited ?? false) level=\(tv.undoManager?.groupingLevel ?? -1))")
        noWriteBeforeSave(doc, url, untouched: untouched, saved: before + Data(expected.utf8)) {
        doc.save(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let after = (try? Data(contentsOf: url)) ?? Data()
            report(after == before + Data(expected.utf8), "saved bytes = original + typed text (\(after.count) bytes)")
            report(!doc.isDocumentEdited, "clean after save")
            report(doc.autosavedContentsFileURL == nil && recoveryCopy.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false,
                   "the save deleted the recovery copy")
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
                report(NSDocumentController.shared.documents.contains { $0 === doc }
                       && ((tv as? KiriTextView)?.delegate as? EditorController)?.document === doc,
                       "the revert read the file into the document that was open")
                Task { @MainActor in
                    await saveStages(doc)
                    quit()
                }
            }
        }
        }
        }
    }

    /// The first document's recovery copy, which its save has to delete.
    private static var recoveryCopy: URL?

    /// A file as it is on disk: what a write of any kind would change.
    struct FileState: Equatable {
        let data: Data?
        let modified: Date?
        let inode: Int?

        init(_ url: URL) {
            data = try? Data(contentsOf: url)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            modified = attributes?[.modificationDate] as? Date
            inode = (attributes?[.systemFileNumber] as? NSNumber)?.intValue
        }
    }

    /// Saving is explicit: typing leaves the file alone, and so does an
    /// autosave, which writes a recovery copy somewhere else and leaves the
    /// document edited. `saved` is what Save would write.
    private static func noWriteBeforeSave(_ doc: NSDocument, _ url: URL, untouched: FileState, saved: Data,
                                          then next: @escaping @MainActor () -> Void) {
        report(FileState(url) == untouched, "the file is untouched after typing (bytes, modification date, inode)")
        doc.autosave(withImplicitCancellability: false) { error in
            MainActor.assumeIsolated {
                let now = FileState(url)
                report(error == nil && now == untouched,
                       "the file is untouched after an autosave (bytes \(now.data == untouched.data), modification date \(now.modified == untouched.modified), inode \(now.inode == untouched.inode), error \(error.map { "\($0)" } ?? "none"))")
                let copy = doc.autosavedContentsFileURL
                recoveryCopy = copy
                print("SELFTEST info recovery copy \(copy?.path ?? "none")")
                report(copy != nil && copy?.standardizedFileURL != url.standardizedFileURL
                       && copy.flatMap { try? Data(contentsOf: $0) } == saved,
                       "the autosave wrote the text to a recovery copy somewhere else")
                report(doc.isDocumentEdited, "the document is still edited after the autosave")
                next()
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
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            await perfRecoveryCopy(tv)
            perfEventLoop(tv) {
                Task { @MainActor in
                    await perfFind(tv)
                    quit()
                }
            }
        }
    }

    /// The recovery copy is written on the main thread, a few seconds after
    /// an edit: how long that holds it, on whatever file is open.
    private static func perfRecoveryCopy(_ tv: NSTextView) async {
        guard let doc = tv.window.flatMap({ NSDocumentController.shared.document(for: $0) }) else { return }
        let clock = ContinuousClock()
        // The document knows of the typing above when its undo group
        // closes: at the end of the event with a real key. Here there was
        // no event, so one is posted for the run loop to end.
        let asked = clock.now
        if let nudge = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(nudge, atStart: false)
        }
        while !doc.hasUnautosavedChanges, clock.now - asked < .seconds(8) { try? await Task.sleep(for: .milliseconds(50)) }
        let start = clock.now
        var last = start, held = Duration.zero
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeSources.rawValue, true, 0) { _, _ in
            held = max(held, clock.now - last); last = clock.now
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let failed: Error? = await withCheckedContinuation { done in
            doc.autosave(withImplicitCancellability: false) { error in
                nonisolated(unsafe) let error = error
                done.resume(returning: error)
            }
        }
        held = max(held, clock.now - last)
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        let copy = doc.autosavedContentsFileURL
        let size = copy.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
        func ms(_ d: Duration) -> String { String(format: "%.1f ms", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
        let took = ms(clock.now - start), heldFor = ms(held)
        var line = "SELFTEST PERF recovery copy: \(size / 1024) KB there after \(took), main thread held at most \(heldFor)"
        if let failed { line += " (failed: \(failed.localizedDescription))" }
        if copy == nil { line += " (no copy; waited \(ms(start - asked)) for the document to know of its changes: edited \(doc.isDocumentEdited), to keep \(doc.hasUnautosavedChanges), undo level \(doc.undoManager?.groupingLevel ?? -1))" }
        print(line)
        fflush(stdout)
    }

    /// The find bar on whatever file is open (use a big one): how long a
    /// change of the query keeps the main thread, how long the main thread
    /// is ever held while the search runs, when the count is there, and
    /// what a keystroke in the document costs with the bar open.
    private static func perfFind(_ tv: NSTextView) async {
        guard let ktv = tv as? KiriTextView, let find = (ktv.delegate as? EditorController)?.model.find else { return }
        find.board = NSPasteboard.withUniqueName()
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> String { String(format: "%.1f ms", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
        find.show()
        for query in ["e", "le", "let", "let x", "zzzz-not-here", "func", "\\w+\\("] {
            find.options.regularExpression = query.hasPrefix("\\")
            let start = clock.now
            find.query = query
            let set = clock.now - start
            // While the search runs elsewhere the main thread keeps turning:
            // the longest it took to come back from a 2 ms sleep.
            var held = Duration.zero, last = clock.now
            while find.isSearching, clock.now - start < .seconds(10) {
                try? await Task.sleep(for: .milliseconds(2))
                held = max(held, clock.now - last - .milliseconds(2))
                last = clock.now
            }
            let found = clock.now - start
            let draw = clock.measure { ktv.marks.update() }
            print("SELFTEST PERF find “\(query)”: “\(find.label)”, query set in \(ms(set)), count after \(ms(found)), main thread held at most \(ms(held)), highlights drawn in \(ms(draw)) (\(ktv.marks.shownMatches) in sight)")
        }
        find.options.regularExpression = false
        find.query = "let"
        while find.isSearching { try? await Task.sleep(for: .milliseconds(5)) }
        var worst = Duration.zero, total = Duration.zero
        ktv.window?.makeFirstResponder(ktv)
        for _ in 0..<50 {
            let d = clock.measure {
                tv.insertText("x", replacementRange: tv.selectedRange())
                tv.displayIfNeeded()
            }
            worst = max(worst, d); total += d
            try? await Task.sleep(for: .milliseconds(30))
        }
        print("SELFTEST PERF typing in the document with the find bar open: avg \(ms(total / 50)), worst \(ms(worst))")
        let step = clock.measure { find.step(forward: true) }
        let all = clock.measure { find.replacement = "LET"; find.replaceAll() }
        print("SELFTEST PERF Find Next \(ms(step)); Replace All \(ms(all)) (“\(find.label)”)")
        fflush(stdout)
    }

    /// Step 4/5 behaviour that otherwise was only looked at: focus at launch,
    /// Go to Line, wrapping, Save, tabs.
    private static func behavior(_ initial: NSTextView) {
        let tv = (NSApp.windows.filter(\.isVisible).compactMap { findTextView(in: $0.contentView) }.first ?? initial)
        guard let ktv = tv as? KiriTextView, let controller = ktv.delegate as? EditorController,
              let window = tv.window else { report(false, "editor found"); quit(); return }
        report(window.firstResponder === tv, "editor has keyboard focus at launch")
        // The menus act on the window in front, which in a background
        // launch no window ever is.
        FrontEditor.shared.selfTestMain(window)

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

        ktv.setSelectedRange(NSRange(location: 0, length: 0))
        Task { @MainActor in
            await findStage(ktv, controller)
            await goToLineStage(ktv, controller)
            await statusBarStage(ktv, controller)
            transformations(ktv)
            afterBars(ktv, controller, window)
        }
    }

    /// What `behavior` goes on with after the find bar and Go to Line.
    private static func afterBars(_ ktv: KiriTextView, _ controller: EditorController, _ window: NSWindow) {
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
            report(false, "document for the window"); quit(); return
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

    // MARK: Find and Go to Line

    /// A turn of the run loop and a little more: SwiftUI and the layers
    /// catch up, and the undo group of what was just done closes (AppKit
    /// closes it after an event; nothing else sends one to a background
    /// launch).
    static func settle(_ milliseconds: Int = 60) async {
        if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(e, atStart: false)
        }
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// Key presses through the window, as typing sends them, then a moment
    /// for them to arrive. Only while the keyboard is in a bar's field (or
    /// on one of its buttons, with `anywhere`): never into the document,
    /// but for Escape.
    @discardableResult
    static func typeKeys(_ text: String, in window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                                 anywhere: Bool = false) async -> Bool {
        guard anywhere && (text == "\u{1b}" || !(window.firstResponder is KiriTextView)) || fieldEditor(of: window) != nil else {
            report(false, "the keyboard is in a bar's field for typing “\(text.unicodeScalars.map { $0.value < 32 ? "⌃" : String($0) }.joined())” (first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil"))")
            return false
        }
        let codes: [Character: UInt16] = ["\r": 36, "\u{1b}": 53, "\t": 48]
        for ch in text {
            // ⇧Tab arrives as the back-tab character.
            let characters = ch == "\t" && modifiers.contains(.shift) ? "\u{19}" : String(ch)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: String(ch), isARepeat: false,
                                            keyCode: codes[ch] ?? 0) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        }
        await settle(150)
        return true
    }

    /// The field of a bar that has the keyboard, if one has.
    static func fieldEditor(of window: NSWindow) -> NSTextView? {
        (window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0 : nil }
    }

    /// Whether the editor shows `range` where nothing floats over it: below
    /// the bar at the top and above the status capsule.
    private static func isClear(_ range: NSRange, in ktv: KiriTextView) -> Bool {
        guard let scroll = ktv.enclosingScrollView, let visible = ktv.visibleCharacters(),
              let rect = ktv.rects(for: range.location..<NSMaxRange(range), near: visible).first else { return false }
        let clip = scroll.contentView.bounds, insets = scroll.contentInsets
        return rect.minY >= clip.minY + insets.top - 0.5 && rect.maxY <= clip.maxY - insets.bottom + 0.5
    }

    /// Kiri's own find bar (`FindController`, shown by `FindBar`): the Edit ▸
    /// Find keys pressed through the menu bar, the count, next and previous
    /// around the ends, the highlights, replace and Replace All with undo,
    /// and what the bar's own field does with Return, Tab and Escape.
    private static func findStage(_ ktv: KiriTextView, _ controller: EditorController) async {
        guard let window = ktv.window, let scroll = ktv.enclosingScrollView, let storage = ktv.textStorage,
              let edit = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu,
              let menu = edit.item(withTitle: "Find")?.submenu else { report(false, "Edit ▸ Find exists"); return }
        let find = controller.model.find
        report(Set(edit.items.compactMap { $0.submenu == nil ? nil : $0.title }).isDisjoint(with: ["Spelling and Grammar", "Substitutions", "Speech"])
               && edit.item(withTitle: "Transformations") != nil,
               "Edit has Find and Transformations, no Spelling, Substitutions or Speech")
        /// Presses the item with this key equivalent, as the menu bar would.
        func press(_ key: String, _ mods: NSEvent.ModifierFlags) -> Bool {
            guard let i = menu.items.firstIndex(where: {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == mods
            }), menu.items[i].isEnabled else { return false }
            menu.performActionForItem(at: i)
            return true
        }
        /// Where `needle` is in the text, found without `TextSearch`.
        func occurrences(_ needle: String, in text: String? = nil, options: NSString.CompareOptions = [.caseInsensitive]) -> [NSRange] {
            let ns = (text ?? ktv.string) as NSString
            var found: [NSRange] = [], from = 0
            while from < ns.length {
                let r = ns.range(of: needle, options: options, range: NSRange(location: from, length: ns.length - from))
                guard r.location != NSNotFound else { break }
                found.append(r)
                from = NSMaxRange(r)
            }
            return found
        }
        func origin() -> NSPoint { scroll.contentView.bounds.origin }
        EditAction.selfTestTarget = ktv
        defer { EditAction.selfTestTarget = nil }
        let original = ktv.string
        let funcs = occurrences("func"), counts = occurrences("count")
        guard funcs.count >= 2, counts.count >= 3, !occurrences("import").isEmpty else {
            report(false, "the test file has “func” twice, “count” three times and an “import” (\(funcs.count), \(counts.count))"); return
        }
        let couldUndo = ktv.undoManager?.canUndo ?? false

        // ⌘E, once on the pasteboard every app shares: written, checked and
        // put back before anything else can run.
        let shared = NSPasteboard(name: .find)
        let sharedBefore = shared.string(forType: .string)
        window.makeFirstResponder(ktv)
        ktv.setSelectedRange(funcs[0])
        let e = press("e", .command)
        let onShared = shared.string(forType: .string)
        shared.clearContents()
        if let sharedBefore { shared.setString(sharedBefore, forType: .string) }
        report(e && onShared == "func" && find.query == "func" && !find.isOpen,
               "⌘E makes the selection the query and puts it on the find pasteboard, without opening the bar (“\(onShared ?? "nil")”, open \(find.isOpen))")
        // From here on a pasteboard of the test's own.
        let board = NSPasteboard.withUniqueName()
        find.board = board
        defer {
            find.board = NSPasteboard(name: .find)
            board.releaseGlobally()
        }

        // ⌘F: Kiri's bar, not AppKit's, and nothing moves.
        let before = origin()
        let f = press("f", .command)
        report(f && find.isOpen && !scroll.isFindBarVisible && find.query == "func",
               "⌘F opens Kiri's find bar with the selected word as the query, and no system find bar (open \(find.isOpen), system bar \(scroll.isFindBarVisible), query “\(find.query)”)")
        report(find.status == .found(current: 0, total: funcs.count, more: false) && find.label == "1 of \(funcs.count)",
               "the count reads “1 of \(funcs.count)” (\(find.label))")
        report(origin() == before && scroll.contentInsets.top == FindBar.obstruction(replace: false),
               "opening the bar leaves the text where it was (\(before.y) → \(origin().y), room to scroll under the bar \(scroll.contentInsets.top))")
        ktv.marks.update()
        let inSight = ktv.visibleCharacters().map { v in funcs.filter { $0.location < v.range.upperBound && NSMaxRange($0) > v.range.lowerBound }.count } ?? -1
        var background = false
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if value != nil { background = true }
        }
        report(ktv.marks.shownMatches == inSight && inSight > 0 && !background && (ktv.undoManager?.canUndo ?? false) == couldUndo,
               "every match in sight is highlighted, by layers: nothing in the text's attributes or in undo (\(ktv.marks.shownMatches) of \(inSight) in sight)")

        // Next and previous, around the ends, each clear of what floats.
        window.makeFirstResponder(ktv)
        ktv.setSelectedRange(NSRange(location: 0, length: 0))
        let g = press("g", .command)
        report(g && ktv.selectedRange() == funcs[0] && find.label == "1 of \(funcs.count)" && isClear(funcs[0], in: ktv),
               "⌘G selects the next match (\(ktv.selectedRange()) vs \(funcs[0]), “\(find.label)”)")
        let g2 = press("g", .command)
        report(g2 && ktv.selectedRange() == funcs[1] && find.label == "2 of \(funcs.count)" && isClear(funcs[1], in: ktv),
               "⌘G again selects the one after (\(ktv.selectedRange()), “\(find.label)”)")
        ktv.setSelectedRange(NSRange(location: storage.length, length: 0))
        let back = press("g", [.shift, .command])
        report(back && ktv.selectedRange() == funcs.last && find.label == "\(funcs.count) of \(funcs.count)",
               "⇧⌘G selects the previous match (\(ktv.selectedRange()), “\(find.label)”)")
        let wrapped = press("g", .command)
        let first = ktv.selectedRange()
        let wrappedBack = press("g", [.shift, .command])
        report(wrapped && wrappedBack && first == funcs[0] && ktv.selectedRange() == funcs.last,
               "next from the last match is the first, previous from the first the last (\(first), \(ktv.selectedRange()))")
        ktv.marks.update()
        report(ktv.marks.currentRects.count == 1, "the current match has its outline (\(ktv.marks.currentRects.count) rects)")

        // As the query is typed: the first match from the caret, and a
        // match on line 1 comes out from under the bar.
        find.query = "import"
        let top = occurrences("import")[0]
        report(ktv.selectedRange() == top && find.label.hasPrefix("1 of ") && isClear(top, in: ktv) && origin().y < 0,
               "a query finds as it is typed, and a match on line 1 is shown below the bar (scrolled to \(origin().y), selection \(ktv.selectedRange()))")
        // A match a few lines down, found with the file's first lines
        // under the bar: line 1 comes out whole, not with its top under
        // the bar's edge, in both of the bar's heights.
        func headClear() -> Bool { isClear(NSRange(location: 0, length: 1), in: ktv) }
        func headTop() -> String {
            guard let visible = ktv.visibleCharacters(), let r = ktv.rects(for: 0..<1, near: visible).first else { return "out of sight" }
            return "line 1 starts \(r.minY - origin().y) pt down, the bar's room is \(scroll.contentInsets.top)"
        }
        if !occurrences("warmly").isEmpty, !occurrences("keeps").isEmpty {
            controller.scrollOrigin = .zero
            ktv.setSelectedRange(NSRange(location: 0, length: 0))
            find.query = "keeps"
            report(isClear(ktv.selectedRange(), in: ktv) && headClear(),
                   "a match on line 3 found from the top brings line 1 out whole from under the bar (\(headTop()))")
            find.showsReplace = true
            await settle()
            report(scroll.contentInsets.top == FindBar.obstruction(replace: true) && headClear(),
                   "opening the replace row at the top of the file keeps line 1 clear of the taller bar (\(headTop()))")
            controller.scrollOrigin = .zero
            ktv.setSelectedRange(NSRange(location: 0, length: 0))
            find.query = "warmly"
            report(isClear(ktv.selectedRange(), in: ktv) && headClear(),
                   "and so does a match on line 3 found with the replace row showing (\(headTop()))")
            find.showsReplace = false
            await settle()
            report(scroll.contentInsets.top == FindBar.obstruction(replace: false) && headClear(),
                   "closing the replace row leaves line 1 clear (\(headTop()))")
            // (The bar took the keyboard in the meantime; the checks after
            // this one have it in the editor.)
            window.makeFirstResponder(ktv)
            ktv.setSelectedRange(top)
        } else {
            report(false, "the test file has “keeps” and “warmly” on its third line")
        }
        let selected = ktv.selectedRange()
        find.query = "zzzz-not-here"
        ktv.marks.update()
        report(find.status == .none && find.label == "No matches" && ktv.selectedRange() == selected && ktv.marks.shownMatches == 0,
               "a query that isn't there says “No matches” and leaves the selection alone (“\(find.label)”)")
        find.options.regularExpression = true
        find.query = "func ("
        report(find.status == .invalid && find.label == "Invalid pattern", "an invalid regular expression says so (“\(find.label)”)")
        find.query = "func \\w+\\("
        report(find.status == .found(current: 0, total: funcs.count, more: false) && ktv.selectedRange().length > 5,
               "a regular expression finds (“\(find.label)”, selection \(ktv.selectedRange()))")
        find.options.regularExpression = false
        find.query = "greeter"
        let anyCase = find.label
        find.options.matchCase = true
        let thisCase = find.label
        find.options.matchCase = false
        report(anyCase.hasSuffix("of \(occurrences("greeter").count)") && thisCase.hasSuffix("of \(occurrences("greeter", options: []).count)")
               && occurrences("greeter").count > occurrences("greeter", options: []).count,
               "match case narrows the search (“\(anyCase)”, with match case “\(thisCase)”)")
        find.query = ""
        ktv.marks.update()
        report(find.status == .idle && find.label.isEmpty && ktv.marks.shownMatches == 0, "no query, no count and no highlights")

        // The highlights follow the document as it is edited.
        find.query = "count"
        ktv.insertText("count ", replacementRange: NSRange(location: 0, length: 0))
        await settle()
        report(find.matches.map { NSRange(location: $0.lowerBound, length: $0.count) } == occurrences("count") && find.matches.count == counts.count + 1,
               "the matches follow an edit to the document (\(find.matches.count) after typing one more)")
        ktv.undoManager?.undo()
        await settle()
        report(ktv.string == original && find.matches.count == counts.count, "and its undo (\(find.matches.count))")

        // Replace: one match at a time, each its own undo step.
        report(press("f", [.option, .command]) && find.showsReplace && scroll.contentInsets.top == FindBar.obstruction(replace: true),
               "⌥⌘F shows the replace row (room under the bar \(scroll.contentInsets.top))")
        find.replacement = "n"
        // (The bar takes the keyboard when it opens; here the editor has it.)
        await settle(300)
        window.makeFirstResponder(ktv)
        ktv.setSelectedRange(NSRange(location: 0, length: 0))
        find.step(forward: true)
        func replaced(_ n: Int) -> String {
            var text = original as NSString
            for r in counts.prefix(n).reversed() { text = text.replacingCharacters(in: r, with: "n") as NSString }
            return text as String
        }
        // (The document's own flag: the window's follows it later.)
        let document = NSDocumentController.shared.document(for: window)
        let cleanBefore = document?.isDocumentEdited == false
        find.replaceCurrent()
        await settle()
        let afterOne = ktv.string, selectionAfterOne = ktv.selectedRange(), editedAfterOne = document?.isDocumentEdited == true
        find.replaceCurrent()
        await settle()
        let afterTwo = ktv.string
        report(afterOne == replaced(1) && afterTwo == replaced(2)
               && selectionAfterOne == NSRange(location: counts[1].location - 4, length: counts[1].length)
               && find.label == "1 of \(counts.count - 2)",
               "Replace changes the current match and goes on to the next (selection \(selectionAfterOne), “\(find.label)”)")
        ktv.undoManager?.undo()
        await settle()
        let undoneOnce = ktv.string
        ktv.undoManager?.undo()
        await settle()
        report(undoneOnce == replaced(1) && ktv.string == original && find.matches.count == counts.count,
               "each Replace is one undo step (\(find.matches.count) matches again)")
        report(cleanBefore && editedAfterOne && document?.isDocumentEdited == false,
               "a Replace is an edit of the document, and its undo leaves it clean again (clean \(cleanBefore), edited \(editedAfterOne), then \(document?.isDocumentEdited ?? true))")

        // A replacement that holds the query is not found again.
        find.replacement = "countcount"
        ktv.setSelectedRange(NSRange(location: 0, length: 0))
        find.step(forward: true)
        find.replaceCurrent()
        await settle()
        report(ktv.selectedRange() == NSRange(location: counts[1].location + 5, length: 5),
               "after a Replace the search goes on behind what was put in (\(ktv.selectedRange()))")
        ktv.undoManager?.undo()
        await settle()

        // Replace All: one undo step for all of them, and it says how many.
        find.replacement = "n"
        find.replaceAll()
        await settle()
        report(ktv.string == replaced(counts.count) && find.label == "Replaced \(counts.count)" && document?.isDocumentEdited == true,
               "Replace All replaces every match, says how many, and the document is edited (“\(find.label)”)")
        ktv.undoManager?.undo()
        await settle()
        report(ktv.string == original && document?.isDocumentEdited == false, "and one undo puts them all back, the document clean again")
        find.options.regularExpression = true
        find.query = "(\\w+): String"
        find.replacement = "$1 = \\t$1"
        let pattern = try? NSRegularExpression(pattern: "(\\w+): String")
        let expected = pattern?.stringByReplacingMatches(in: original, range: NSRange(location: 0, length: (original as NSString).length),
                                                         withTemplate: "$1 = \t$1")
        find.replaceAll()
        await settle()
        report(expected != nil && expected != original && ktv.string == expected, "a regular expression replaces with $1 templates (“\(find.label)”)")
        ktv.undoManager?.undo()
        await settle()
        find.options.regularExpression = false
        find.replacement = ""
        guard ktv.string == original else { report(false, "the text is back as it was after the replace checks"); return }

        // Closing: the match stays selected, the keyboard is the editor's,
        // the highlights and the room under the bar are gone.
        find.query = "func"
        window.makeFirstResponder(ktv)
        ktv.setSelectedRange(NSRange(location: 0, length: 0))
        find.step(forward: true)
        find.close()
        ktv.marks.update()
        report(!find.isOpen && window.firstResponder === ktv && ktv.selectedRange() == funcs[0] && scroll.contentInsets.top == 0
               && ktv.marks.shownMatches == 0 && origin().y >= 0,
               "closing leaves the match selected in the editor and takes the highlights away (selection \(ktv.selectedRange()), \(ktv.marks.shownMatches) highlights)")
        let closedNext = press("g", .command)
        report(closedNext && !find.isOpen && ktv.selectedRange() == funcs[1], "⌘G finds the next match with the bar closed (\(ktv.selectedRange()))")
        report(press("j", .command), "⌘J is in the menu")

        // The bar and Go to Line take each other's place.
        let goToLine = controller.model.goToLine
        find.show()
        goToLine.open()
        let onlyGoToLine = goToLine.isOpen && !find.isOpen
        find.show()
        report(onlyGoToLine && find.isOpen && !goToLine.isOpen, "the find bar and Go to Line never show together")
        find.close()

        // The bar itself: SwiftUI has to be drawing the window for these.
        let wasEdited = document?.isDocumentEdited ?? false
        window.makeFirstResponder(ktv)
        ktv.setSelectedRange(funcs[0])
        ktv.scrollRangeToVisible(funcs[0])
        _ = press("f", .command)
        await settle(400)
        if let field = fieldEditor(of: window) {
            report(field.string == "func" && field.selectedRange() == NSRange(location: 0, length: 4),
                   "⌘F puts the keyboard in the find field with its text selected (“\(field.string)”, \(field.selectedRange()))")
            ktv.marks.update()
            report(ktv.selectedRange() == NSRange(location: funcs[0].location, length: 0) && ktv.marks.currentRects.count == 1,
                   "while the keyboard is in the bar the current match is marked, not selected in grey (selection \(ktv.selectedRange()), “\(find.label)”, \(ktv.marks.currentRects.count) outlined)")
            await typeKeys("count", in: window)
            report(find.query == "count" && find.label == "\(counts.firstIndex { $0.location >= funcs[0].location }.map { $0 + 1 } ?? 1) of \(counts.count)",
                   "typing in the field searches as it is typed (“\(find.query)”, “\(find.label)”)")
            report(document?.isDocumentEdited == wasEdited && ktv.string == original && (ktv.undoManager?.canUndo ?? false) == couldUndo,
                   "typing in the find field is not an edit of the document (edited \(document?.isDocumentEdited ?? true), can undo \(ktv.undoManager?.canUndo ?? false))")
            let start = find.label
            await typeKeys("\r", in: window)
            let afterReturn = find.label
            await typeKeys("\r", in: window, modifiers: .shift)
            report(afterReturn != start && find.label == start && fieldEditor(of: window) != nil,
                   "Return in the field goes to the next match and ⇧Return back, the keyboard staying in the field (“\(start)” → “\(afterReturn)” → “\(find.label)”)")
            let viaMenu = press("g", .command)
            report(viaMenu && find.label == afterReturn, "⌘G works while the keyboard is in the find field (“\(find.label)”)")
            if !NSApp.isFullKeyboardAccessEnabled {
                // Nothing else in the bar takes the keyboard: Tab stays, and
                // what is typed next is still the query, not the document.
                await typeKeys("\t", in: window)
                await typeKeys("\t", in: window, modifiers: .shift)
                let stays = fieldEditor(of: window) != nil
                if stays { await typeKeys("s", in: window) }
                report(stays && find.query.hasSuffix("s") && ktv.string == original,
                       "Tab in the find field alone stays in it (query “\(find.query)”)")
                find.query = "count"
            }
            _ = press("f", [.option, .command])
            await settle(300)
            await typeKeys("\t", in: window)
            await typeKeys("xy", in: window)
            let inReplace = find.replacement
            // Return in the replace field replaces the current match.
            await typeKeys("\r", in: window)
            let replacedByReturn = ktv.string
            ktv.undoManager?.undo()
            await settle()
            report(replacedByReturn != original && occurrences("count", in: replacedByReturn).count == counts.count - 1
                   && occurrences("xy", in: replacedByReturn).count == occurrences("xy", in: original).count + 1 && ktv.string == original,
                   "Return in the replace field replaces the current match, and undo puts it back")
            await typeKeys("\t", in: window, modifiers: .shift)
            await typeKeys("q", in: window)
            report(inReplace == "xy" && find.query == "q",
                   "Tab goes from the find field to the replace field and ⇧Tab back (replace “\(inReplace)”, find “\(find.query)”)")
            if !NSApp.isFullKeyboardAccessEnabled {
                await typeKeys("\t", in: window)
                await typeKeys("\t", in: window)
                await typeKeys("r", in: window)
                let around = find.query
                await typeKeys("\t", in: window, modifiers: .shift)
                await typeKeys("z", in: window)
                report(around == "r" && find.replacement == "z" && ktv.string == original,
                       "and round within the bar at its ends, never into the document (find “\(around)”, replace “\(find.replacement)”)")
                await typeKeys("\t", in: window)
            }
            find.query = "func"
            // With Full Keyboard Access, Tab also stops at buttons: after the fields.
            if NSApp.isFullKeyboardAccessEnabled {
                await wakeAccessibility()
                var order = [focusedName(in: window)]
                for _ in 0..<10 {
                    await typeKeys("\t", in: window, anywhere: true)
                    order.append(focusedName(in: window))
                }
                report(Array(order.prefix(10)) == ["Find", "Replace with", "Match Case", "Regular Expression", "Previous Match", "Next Match",
                                                   "Close Find", "Replace", "Replace All", "Hide Replace"],
                       "Tab goes through the bar: find field, replace field, then the buttons (\(order))")
                find.show()
                await settle(300)
            } else {
                print("SELFTEST SKIP Tab through the bar's buttons (Full Keyboard Access is off: System Settings ▸ Keyboard ▸ Keyboard navigation)")
            }
            let current = find.label
            await typeKeys("\u{1b}", in: window)
            report(!find.isOpen && window.firstResponder === ktv && ktv.selectedRange().length == 4 && funcs.contains(ktv.selectedRange()),
                   "Escape closes the bar and returns to the editor with the current match selected (“\(current)”, selection \(ktv.selectedRange()))")
            // Escape with the keyboard in the editor closes the bar too.
            find.show()
            await settle(300)
            window.makeFirstResponder(ktv)
            await typeKeys("\u{1b}", in: window, anywhere: true)
            report(!find.isOpen && window.firstResponder === ktv, "Escape in the editor closes the bar over it (open \(find.isOpen))")
        } else if window.occlusionState.contains(.visible) {
            report(false, "⌘F puts the keyboard in the find field (first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil"))")
        } else {
            print("SELFTEST SKIP the find field's keys: Return, Tab, Escape (the window is covered or the screen locked: SwiftUI isn't drawing the bar)")
        }
        // Put the window back as it was for the checks that follow.
        find.close()
        find.replacement = ""
        find.showsReplace = false
        window.makeFirstResponder(ktv)
        ktv.setSelectedRange(NSRange(location: 0, length: 0))
        controller.scrollOrigin = .zero
    }

    /// Go to Line (`GoToLineController`), which is the command palette
    /// with a colon typed (⌘L opens it so): the line shows while its
    /// number is typed, Return keeps it, Escape goes back to the selection
    /// and the scroll position from before, and so does taking the colon away.
    private static func goToLineStage(_ ktv: KiriTextView, _ controller: EditorController) async {
        guard let window = ktv.window, let scroll = ktv.enclosingScrollView else { return }
        let model = controller.model, goToLine = model.goToLine, palette = model.palette
        func origin() -> NSPoint { scroll.contentView.bounds.origin }
        func caretIsClear() -> Bool { isClear(ktv.selectedRange(), in: ktv) }
        let lines = controller.lineCount
        guard lines >= 12 else { report(false, "the test file has a dozen lines (\(lines))"); return }
        window.makeFirstResponder(ktv)
        let selection = NSRange(location: 3, length: 4)
        ktv.setSelectedRange(selection)
        controller.scrollOrigin = .zero
        let before = origin()
        /// Whether the last line is out of sight at the top of the document.
        let scrolls = ktv.frame.height > scroll.contentView.bounds.height - scroll.contentInsets.bottom

        goToLine.open()
        report(goToLine.isOpen && palette.isOpen && palette.text == ":" && palette.mode == .line && palette.rows.isEmpty
               && palette.lineStatus?.isTarget == false && palette.lineStatus?.isProblem == false
               && origin() == before && ktv.selectedRange() == selection && scroll.contentInsets.top == CommandPalette.lineObstruction,
               "Go to Line opens the palette with its colon typed, without moving anything (\(before.y) → \(origin().y); “\(palette.lineStatus?.text ?? "")”)")
        palette.text = ":\(lines)"
        ktv.marks.update()
        report(model.line == lines && caretIsClear() && ktv.marks.showsLine && (!scrolls || origin().y > before.y)
               && palette.lineStatus?.text == "Go to line \(lines)" && palette.lineStatus?.isTarget == true && palette.lastAnnouncement == "Go to line \(lines)",
               "typing a line number shows that line, marked, before Return, and the palette says where Return goes (Ln \(model.line), scrolled to \(origin().y), marked \(ktv.marks.showsLine), “\(palette.lineStatus?.text ?? "")”)")
        palette.text = ":1"
        report(model.line == 1 && caretIsClear() && origin().y < 0, "line 1 is shown below the palette (Ln \(model.line), scrolled to \(origin().y))")
        palette.text = ":99999"
        report(model.line == lines && !goToLine.isInvalid && palette.lineStatus?.text == "Go to line \(lines)",
               "a number past the end is the last line (Ln \(model.line))")
        palette.text = ":9x"
        report(goToLine.isInvalid && model.line == lines && goToLine.isOpen && palette.lineStatus == .init(text: "Not a line", isProblem: true),
               "what isn't a line number is said not to be one and goes nowhere (“\(palette.lineStatus?.text ?? "")”)")
        palette.commit()
        report(goToLine.isOpen && goToLine.isInvalid && palette.isOpen, "and Return does nothing with it")
        palette.text = ":"
        report(!goToLine.isInvalid && ktv.selectedRange() == selection && origin() == before,
               "clearing the number goes back to where the editor was (selection \(ktv.selectedRange()), \(origin().y))")
        palette.text = ":12"
        palette.cancel()
        ktv.marks.update()
        report(!goToLine.isOpen && !palette.isOpen && ktv.selectedRange() == selection && origin() == before && window.firstResponder === ktv
               && scroll.contentInsets.top == 0 && !ktv.marks.showsLine,
               "Escape restores the selection and the scroll position (selection \(ktv.selectedRange()), \(origin().y))")
        goToLine.open()
        palette.text = ":5:3"
        let previewed = (model.line, model.column)
        let says = palette.lineStatus?.text
        palette.commit()
        report(previewed == (5, 3) && says == "Go to line 5, column 3" && !goToLine.isOpen && !palette.isOpen && model.line == 5 && model.column == 3
               && ktv.selectedRange().length == 0 && window.firstResponder === ktv && scroll.contentInsets.top == 0,
               ":5:3 previews and Return keeps Ln \(model.line), Col \(model.column) with the keyboard in the editor (“\(says ?? "")”)")

        // The colon typed into a palette that is open begins it, and
        // taking it away goes back: the list is there again.
        ktv.setSelectedRange(selection)
        controller.scrollOrigin = .zero
        palette.open()
        let listed = !palette.rows.isEmpty && !goToLine.isOpen && scroll.contentInsets.top == 0
        palette.text = ":12"
        let inLine = goToLine.isOpen && model.line == 12 && palette.rows.isEmpty && scroll.contentInsets.top == CommandPalette.lineObstruction
        palette.text = "12"
        report(listed && inLine && !goToLine.isOpen && palette.isOpen && palette.mode == .everything && ktv.selectedRange() == selection && origin() == before
               && scroll.contentInsets.top == 0,
               "a colon typed into the open palette shows the line, and taking the colon away puts the selection back (\(listed), \(inLine), selection \(ktv.selectedRange()))")
        palette.cancel()

        // The field itself: SwiftUI has to be drawing the window for these.
        ktv.setSelectedRange(selection)
        controller.scrollOrigin = .zero
        goToLine.open()
        await settle(400)
        if fieldEditor(of: window) != nil {
            // (The caret is after the colon: what is typed is added to it.)
            for _ in 0..<50 where fieldEditor(of: window)?.selectedRange() != NSRange(location: 1, length: 0) { try? await Task.sleep(for: .milliseconds(20)) }
            await typeKeys("7", in: window)
            let typed = model.line, text = palette.text
            await typeKeys("\u{1b}", in: window)
            report(typed == 7 && text == ":7" && !goToLine.isOpen && !palette.isOpen && ktv.selectedRange() == selection && origin() == before && window.firstResponder === ktv,
                   "typed into the field after the colon: 7 previews line 7, Escape goes back (Ln \(typed), “\(text)”, selection \(ktv.selectedRange()))")
            goToLine.open()
            await settle(400)
            for _ in 0..<50 where fieldEditor(of: window)?.selectedRange() != NSRange(location: 1, length: 0) { try? await Task.sleep(for: .milliseconds(20)) }
            await typeKeys("8\r", in: window)
            report(!goToLine.isOpen && !palette.isOpen && model.line == 8 && window.firstResponder === ktv,
                   "typed into the field: 8 and Return go to line 8 (Ln \(model.line))")
        } else if window.occlusionState.contains(.visible) {
            report(false, "Go to Line puts the keyboard in the palette's field (first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil"))")
        } else {
            print("SELFTEST SKIP Go to Line's field: typing, Return, Escape (the window is covered or the screen locked: SwiftUI isn't drawing it)")
        }
        palette.cancel()
        window.makeFirstResponder(ktv)
        ktv.setSelectedRange(NSRange(location: 0, length: 0))
        controller.scrollOrigin = .zero
    }

    // MARK: The status bar and the first-run hint

    /// Whether Kiri is cutting motion down in this run (the Motion setting,
    /// or the system's Reduce Motion): then the status bar doesn't rest.
    private static var reducedMotion: Bool {
        let level = UserDefaults.standard.string(forKey: Prefs.motionKey).flatMap(HoneyMotionLevel.init(rawValue:)) ?? .system
        return HoneyAppearance(motion: level).reduced(systemReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Nor does it for someone who asked for more contrast.
    private static var increasedContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    /// The status bar: its items' names for VoiceOver, the position button
    /// opening Go to Line, a width that holds wherever the caret is, the
    /// indentation Shift Left and Right use, and resting while the text is
    /// scrolled (`StatusBarRest`; the typing half is in `startHintStage`).
    private static func statusBarStage(_ ktv: KiriTextView, _ controller: EditorController) async {
        guard let window = ktv.window, let scroll = ktv.enclosingScrollView,
              let container = scroll.superview as? EditorContainerView else { report(false, "the editor's container"); return }
        let model = controller.model, rest = model.statusRest
        let lines = controller.lineCount, length = (ktv.string as NSString).length
        guard lines >= 12 else { report(false, "the test file has a dozen lines (\(lines))"); return }
        window.makeFirstResponder(ktv)
        let visible = window.occlusionState.contains(.visible)
        await wakeAccessibility()
        func elements() -> [AccessibilityElement] { accessibilityElements(of: window) }
        func bar() -> AccessibilityElement? { elements().first { $0.name == "Status bar" } }

        // What VoiceOver is given. (The elements are there in a window that
        // isn't being drawn too, as they were when it opened.)
        let list = elements()
        let menus = list.filter { $0.role == NSAccessibility.Role.popUpButton.rawValue || $0.role == NSAccessibility.Role.menuButton.rawValue }
            .map(\.name)
        // (The language is a button: it opens the language picker.)
        let language = list.first { $0.role == NSAccessibility.Role.button.rawValue && $0.name == "Language" }
        let named = ["Encoding, ", "Line endings, "].allSatisfy { prefix in menus.contains { $0.hasPrefix(prefix) && $0.count > prefix.count } }
            && language?.value.isEmpty == false
        let current = !visible || language?.value == model.language.name && menus.contains("Encoding, UTF-8") && menus.contains("Line endings, LF")
        report(named && current, "the status bar's menus and its language say what they are and their value (\(menus), Language “\(language?.value ?? "none")”)")
        let position = list.first { $0.role == NSAccessibility.Role.button.rawValue && $0.name == "Go to Line" }
        let indentation = list.first { $0.value.hasPrefix("Indentation, ") || $0.name.hasPrefix("Indentation, ") }
        report(position?.value.hasPrefix("Line ") == true && indentation != nil,
               "the position is a button with the line and column as its value, the indentation a text (“\(position?.value ?? "none")”, “\(indentation.map { $0.value + $0.name } ?? "none")”)")
        report(list.filter { ["Status bar"].contains($0.name) }.count == 1 && (position.map { $0.frame.height >= 24 } ?? false),
               "the status bar is one group, its button 24 pt high (\(position.map { "\($0.frame.width)×\($0.frame.height)" } ?? "none"))")

        // The button does what Edit ▸ Go to Line… does.
        if let position {
            position.press()
            await settle(150)
            report(model.goToLine.isOpen && model.palette.isOpen && model.palette.text == ":", "pressing the position opens Go to Line")
            model.palette.cancel()
        }

        // The width holds wherever the caret is. Drawn offscreen from the
        // window's own model, and on screen where SwiftUI is drawing.
        var places: [(name: String, text: String, offscreen: CGFloat, onScreen: CGFloat?)] = []
        func measure(_ name: String) async {
            let text = StatusText.position(line: model.line, column: model.column, selected: model.selectedLength)
            var onScreen: CGFloat?
            if visible {
                await settle(250)
                onScreen = bar()?.frame.width
            }
            places.append((name, text, StatusBarSample.width(model), onScreen))
        }
        controller.goTo(line: 1, column: 1)
        await measure("line 1, column 1")
        controller.goTo(line: 9, column: 1)
        await measure("line 9")
        controller.goTo(line: 10, column: 4)
        await measure("line 10")
        controller.goTo(line: lines, column: 9999)
        await measure("the last line")
        ktv.setSelectedRange(NSRange(location: 0, length: length))
        await measure("everything selected")
        ktv.setSelectedRange(NSRange(location: 3, length: 5))
        await measure("five characters selected")
        let texts = places.map(\.text)
        report(texts[0] == "Ln 1, Col 1" && texts[1] == "Ln 9, Col 1" && texts[2] == "Ln 10, Col 4" && texts[3].hasPrefix("Ln \(lines), Col ")
               && texts[4] == "Ln 1, Sel \(length)" && texts[5] == "Ln 1, Sel 5",
               "the position reads line and column, and a selection's length in the column's place (\(texts))")
        let offscreen = Set(places.map(\.offscreen))
        report(offscreen.count == 1 && (offscreen.first ?? 0) > 100,
               "the status bar is the same width at line 1, 9, 10, the last line and with a selection, drawn offscreen (\(places.map { "\($0.name): \($0.offscreen)" }))")
        if visible {
            let onScreen = Set(places.compactMap(\.onScreen))
            report(onScreen.count == 1 && places.allSatisfy { $0.onScreen != nil },
                   "and in the window (\(places.map { "\($0.name): \($0.onScreen.map { "\($0)" } ?? "none")" }))")
        } else {
            print("SELFTEST SKIP the status bar's width in the window (the window is covered or the screen locked: SwiftUI isn't updating it)")
        }
        let reserve = StatusText.Reserve(lineCount: lines, longestLine: LineIndex(ktv.string).longestLine, length: length)
        report(model.positionReserve == reserve, "the room it keeps is for the file's last line, longest line and length (\(model.positionReserve.texts))")

        // The indentation: what Shift Right puts in.
        let indent = IndentStyle.detect(in: ktv.string)
        ktv.setSelectedRange(NSRange(location: 0, length: 0))
        let unshifted = ktv.string
        controller.shiftLines(right: true)
        let shifted = ktv.string == indent.unit + unshifted
        await settle()
        ktv.undoManager?.undo()
        await settle()
        report(model.indent == indent && indent == .spaces(4) && shifted,
               "the status bar names the indentation Shift Right uses (“\(model.indent.label)”)")

        // Resting: scrolling fades it, the pointer coming near brings it
        // back, and an open menu or the keyboard on it keeps it solid.
        func shown() -> Double { StatusBarRest.opacity(resting: rest.isResting, reducedMotion: reducedMotion, increasedContrast: increasedContrast) }
        func scrollByHand() { NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll) }
        let size = container.bounds.size
        let top = EditorStatusBar.bottomPadding + HoneyStatusMetrics.barHeight
        scrollByHand()
        let scrolled = shown()
        container.pointerMoved(to: NSPoint(x: size.width / 2, y: top + StatusBarRest.reach + 20))
        container.pointerMoved(to: NSPoint(x: size.width / 2 + rest.barWidth / 2 + StatusBarRest.reach + 20, y: 20))
        let far = shown()
        container.pointerMoved(to: NSPoint(x: size.width / 2 + rest.barWidth / 2 + StatusBarRest.reach - 10, y: top + StatusBarRest.reach - 10))
        let near = shown()
        if reducedMotion || increasedContrast {
            report(scrolled == 1 && far == 1 && near == 1, "with reduced motion or increased contrast the status bar stays solid while scrolling (\(scrolled))")
        } else {
            report(scrolled == Honey.restOpacity && far == Honey.restOpacity && near == 1,
                   "scrolling rests the status bar (what its view is told to draw: \(Honey.restOpacity)), and the pointer within \(Int(StatusBarRest.reach)) pt brings it back (scrolled \(scrolled), pointer far \(far), near \(near))")
        }
        let menu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        scrollByHand()
        let menuOpen = shown()
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        rest.focusChanged(inside: true)
        scrollByHand()
        let focused = shown()
        rest.focusChanged(inside: false)
        report(menuOpen == 1 && focused == 1, "an open menu and the keyboard on one of its items keep it solid (\(menuOpen), \(focused))")

        ktv.setSelectedRange(NSRange(location: 0, length: 0))
        controller.scrollOrigin = .zero
        fflush(stdout)
    }

    /// With wrapping off the horizontal scroller and the status capsule
    /// share the bottom edge: where each is, measured from the frames (for
    /// when nothing can look). Says so when the text is no wider than the
    /// editor and there is no scroller to measure.
    private static func scrollerInfo(_ textView: NSTextView) {
        guard let scroll = textView.enclosingScrollView, let container = scroll.superview as? EditorContainerView,
              let rest = (textView.delegate as? EditorController)?.model.statusRest else { return }
        scroll.tile()
        guard let scroller = scroll.horizontalScroller, scroll.hasHorizontalScroller, scroller.frame.height > 0 else {
            print("SELFTEST info horizontal scroller: none laid out (wrapping \(scroll.hasHorizontalScroller ? "off, but no line is wider than the editor" : "on"))")
            return
        }
        let frame = scroller.convert(scroller.bounds, to: container)
        let fromBottom = container.isFlipped ? container.bounds.maxY - frame.maxY : frame.minY
        let capsule = NSRect(x: (container.bounds.width - rest.barWidth) / 2, y: EditorStatusBar.bottomPadding, width: rest.barWidth,
                             height: HoneyStatusMetrics.barHeight)
        let band = NSRect(x: frame.minX, y: fromBottom, width: frame.width, height: frame.height)
        print("SELFTEST info horizontal scroller: \(frame.height) pt high, from \(fromBottom) to \(band.maxY) pt above the panel's bottom, x \(frame.minX)…\(frame.maxX) of \(container.bounds.width); the status capsule is from \(capsule.minY) to \(capsule.maxY) pt, x \(capsule.minX)…\(capsule.maxX); they \(band.intersects(capsule) ? "OVERLAP" : "don't overlap") (\(scroll.scrollerStyle == .overlay ? "overlay" : "legacy") scrollers, bottom inset \(scroll.contentInsets.bottom), scroller insets \(scroll.scrollerInsets.bottom))")
        fflush(stdout)
    }

    /// The first-run hint: in a new untitled document and nowhere else,
    /// its lines real buttons that leave the keyboard and the clicks around
    /// them to the editor, gone with the first key typed and not back after
    /// undo. The first key also rests the status bar, which comes back
    /// after its pause. And where the `kiri` command counts as installed.
    ///
    /// It ends by closing its two tabs while each is the one showing, which
    /// once threw from `WindowTabs.invalidate`.
    private static func startHintStage(_ original: NSWindow) async {
        guard let ktv = findTextView(in: original.contentView) as? KiriTextView,
              let controller = ktv.delegate as? EditorController else { report(false, "the first window's editor"); return }
        let clock = ContinuousClock()
        func wait(_ seconds: Double = 3, until done: () -> Bool) async -> Bool {
            let start = clock.now
            while clock.now - start < .seconds(seconds) {
                if done() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return done()
        }
        /// A document's window, text view and controller, once it is a tab
        /// of some window and showing.
        func editor(of doc: NSDocument) async -> (NSWindow, KiriTextView, EditorController)? {
            var found: (NSWindow, KiriTextView, EditorController)?
            _ = await wait {
                guard let t = documentTab(of: doc), let w = t.window, w.tabs.list.count > 1, isShowing(doc),
                      t.controller.document != nil else { return false }
                found = (w, t.container.textView, t.controller)
                return true
            }
            return found
        }

        // Where the command counts as installed (`CLIInstaller.status`).
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kiri-cli-test-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mine = dir.appendingPathComponent("mine").path, other = dir.appendingPathComponent("other").path
        for script in [mine, other] { FileManager.default.createFile(atPath: script, contents: Data("#!/bin/sh\n".utf8)) }
        func link(_ name: String, to target: String) -> String {
            let path = dir.appendingPathComponent(name).path
            try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
            return path
        }
        let states = [CLIInstaller.status(link: dir.appendingPathComponent("none").path, script: mine),
                      CLIInstaller.status(link: link("to-mine", to: mine), script: mine),
                      CLIInstaller.status(link: link("to-other", to: other), script: mine),
                      CLIInstaller.status(link: link("to-gone", to: dir.appendingPathComponent("gone").path), script: mine),
                      CLIInstaller.status(link: other, script: mine)]
        let resolved = URL(fileURLWithPath: other).resolvingSymlinksInPath().path
        report(states == [.missing, .installed, .other(resolved), .missing, .other(resolved)],
               "the kiri command is installed when its link is this copy's, another copy's when it leads elsewhere, missing when it leads nowhere (\(states))")

        report(!controller.model.showsStartHint && !ktv.string.isEmpty, "a file with text in it has no first-run hint")

        // A new untitled document, as ⌘N or ⌘T makes one.
        guard let doc = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true),
              let (window, tv, c) = await editor(of: doc) else { report(false, "a new untitled document opens as a tab"); return }
        await settle(300)
        let model = c.model
        report(model.showsStartHint && tv.string.isEmpty, "a new untitled document shows the first-run hint")
        report(window.firstResponder === tv, "the editor has the keyboard in it: the hint takes none (first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil"))")

        // Its lines, as VoiceOver is given them.
        let tool = CommandLineTool.shared.status
        let expected = ["Open a file, \(Keys.open.spoken)", "Open a folder, \(Keys.openFolder.spoken)", "Everything else, \(Keys.palette.spoken)"]
            + (tool == .missing ? ["Install the kiri command"] : [])
        await wakeAccessibility()
        func hint(_ w: NSWindow) -> (group: AccessibilityElement?, lines: [AccessibilityElement]) {
            let list = accessibilityElements(of: w)
            guard let group = list.first(where: { $0.name == "Getting started" }) else { return (nil, []) }
            return (group, list.filter { $0.role == NSAccessibility.Role.button.rawValue && group.frame.contains($0.frame) })
        }
        let shown = hint(window)
        let drawn = window.occlusionState.contains(.visible)
        if shown.group != nil {
            report(shown.lines.map(\.name) == expected && expected[0] == "Open a file, Command O" && shown.lines.allSatisfy { $0.frame.height >= 24 },
                   "the hint's lines are buttons named with their keys, the kiri command \(tool == .missing ? "among them" : "left out: it is installed") (\(shown.lines.map(\.name)))")
            // Clicks: a line takes its own, the paper beside the hint is the editor's.
            if let group = shown.group, let first = shown.lines.first, let content = window.contentView {
                func hit(_ onScreen: NSPoint) -> NSView? {
                    let inWindow = window.convertPoint(fromScreen: onScreen)
                    return content.hitTest(content.superview?.convert(inWindow, from: nil) ?? inWindow)
                }
                let onLine = hit(NSPoint(x: first.frame.midX, y: first.frame.midY))
                let beside = hit(NSPoint(x: group.frame.minX - 30, y: group.frame.midY))
                let above = hit(NSPoint(x: group.frame.midX, y: group.frame.maxY + 30))
                func isEditor(_ v: NSView?) -> Bool { v.map { $0 === tv || $0.isDescendant(of: tv) } ?? false }
                report(!isEditor(onLine) && onLine != nil && isEditor(beside) && isEditor(above),
                       "a click on a line is the line's, a click beside or above the hint the editor's (on a line: \(onLine == nil ? "nothing" : isEditor(onLine) ? "the editor" : "the hint"), beside: \(isEditor(beside) ? "the editor" : "not the editor"), above: \(isEditor(above) ? "the editor" : "not the editor"))")
            }
            // One line pressed: the one that opens no panel and changes
            // nothing. The palette opens over the paper with the keyboard,
            // the hint out of its way, and Escape brings the hint back.
            if let everything = shown.lines.first(where: { $0.name.hasPrefix("Everything else") }) {
                FrontEditor.shared.selfTestMain(window)
                everything.press()
                let opened = await wait(2) { model.palette.isOpen && fieldEditor(of: window) != nil }
                let hidden = await wait(1) { hint(window).group == nil }
                let listed = model.palette.rows.contains { $0.title == "Keyboard Shortcuts" && $0.shortcut != nil }
                model.palette.cancel()
                let back = await wait(1) { hint(window).group != nil }
                report(opened && hidden && listed && back && model.showsStartHint && window.firstResponder === tv && tv.string.isEmpty,
                       "pressing “Everything else” opens the palette with the keyboard in it, the hint out of its way; Keyboard Shortcuts is in its list with its key, and Escape brings the hint back (\(opened), \(hidden), \(listed), \(back))")
            } else {
                report(false, "the hint has its Everything else line")
            }
        } else if drawn {
            report(false, "the hint's lines are in the window")
        } else {
            print("SELFTEST SKIP the hint's lines and clicks (the window is covered or the screen locked: SwiftUI isn't drawing it)")
        }

        // The first key typed, through the event loop.
        let rest = model.statusRest
        window.makeFirstResponder(tv)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "x",
                                        charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        let typed = await wait(2) { tv.string == "x" }
        let start = clock.now
        report(typed && !model.showsStartHint, "the first key typed starts the document and ends the hint (“\(tv.string)”)")
        let whileTyping = StatusBarRest.opacity(resting: rest.isResting, reducedMotion: reducedMotion, increasedContrast: increasedContrast)
        let back = await wait(StatusBarRest.pause + 1) { !rest.isResting }
        let after = clock.now - start
        if reducedMotion || increasedContrast {
            report(whileTyping == 1, "with reduced motion or increased contrast the status bar stays solid while typing (\(whileTyping))")
        } else {
            report(whileTyping == Honey.restOpacity && back && after >= .seconds(StatusBarRest.pause - 0.25) && after <= .seconds(StatusBarRest.pause + 0.5),
                   "typing rests the status bar (what its view is told to draw: \(Honey.restOpacity)) and it comes back after its pause (\(whileTyping), back after \(after))")
        }
        await settle()
        tv.undoManager?.undo()
        await settle(150)
        let gone = hint(window).group == nil
        report(tv.string.isEmpty && !model.showsStartHint, "undo back to an empty document doesn't bring the hint back")
        if drawn {
            report(gone, "and its lines are gone from the window")
        }
        // A file that is empty on disk is a file: no hint.
        let empty = dir.appendingPathComponent("empty.txt")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        let opened: NSDocument? = await withCheckedContinuation { c in
            NSDocumentController.shared.openDocument(withContentsOf: empty, display: true) { d, _, _ in c.resume(returning: d) }
        }
        if let opened, let (_, emptyText, emptyController) = await editor(of: opened) {
            await settle(200)
            report(emptyText.string.isEmpty && !emptyController.model.showsStartHint, "an empty file has no first-run hint")
        } else {
            report(false, "an empty file opens as a tab")
        }

        // Closing the tab that is showing (⌘W): its strip is watching the
        // tabs at that moment. The untitled one is clean again after
        // the undo, so neither asks anything.
        let before = documents(in: original).count
        for document in [opened, doc].compactMap({ $0 }) {
            guard let w = DocumentWindow.window(of: document) else { continue }
            show(document)
            await settle(300)
            FrontEditor.shared.selfTestMain(w)
            FileAction.close()
            await settle(300)
        }
        let left = await wait(2) { documents(in: original).count == before - 2 }
        report(left, "File ▸ Close closes the tab that is showing, an untitled one too (\(before) tabs, then \(documents(in: original).count))")
    }

    /// Edit ▸ Transformations, on a selected word.
    private static func transformations(_ ktv: KiriTextView) {
        guard let edit = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu else { return }
        EditAction.selfTestTarget = ktv
        defer { EditAction.selfTestTarget = nil }
        ktv.window?.makeFirstResponder(ktv)
        let word = (ktv.string as NSString).range(of: "func")
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
        ktv.setSelectedRange(NSRange(location: 0, length: 0))
    }

    private static func tabs(_ window: NSWindow) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kiri-tab-test.txt")
        try? "second tab\n".write(to: url, atomically: true, encoding: .utf8)
        let url2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kiri-tab-test-2.txt")
        try? "third tab\n".write(to: url2, atomically: true, encoding: .utf8)
        let firstDocument = shownDocument(in: window)
        // Opening a file never makes a window, also in a window that has
        // tabs already: counted as each file opens, and once all are in.
        let windowsBefore = NSApp.windows.count, documentWindowsBefore = DocumentWindow.all.count
        let windowObjects = Set(NSApp.windows.map { ObjectIdentifier($0) })
        var counts: [Int] = []
        let slot = (window as? DocumentNSWindow)?.editorSlot
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, _ in
            counts.append(NSApp.windows.count)
            // Its text fades in on the editor's own layer, begun as it opens.
            let fading = slot?.tab?.document === doc && slot?.tab?.container.layer?.animation(forKey: "kiriArrival") != nil
            report(fading, "the new tab's text fades in on the paper, the fade begun as the file opens")
            NSDocumentController.shared.openDocument(withContentsOf: url2, display: true) { doc2, _, _ in
            counts.append(NSApp.windows.count)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let count = documents(in: window).count
                report(count == 3, "two more documents open as tabs (\(count) tabs)")
                counts.append(NSApp.windows.count)
                report(counts.allSatisfy { $0 == windowsBefore } && DocumentWindow.all.count == documentWindowsBefore
                       && NSApp.windows.allSatisfy { windowObjects.contains(ObjectIdentifier($0)) },
                       "opening a file, in a window with one tab and in one with two, makes no window: NSApp.windows stays at \(windowsBefore) (\(counts))")
                report(window.firstResponder === editorText(of: doc2) && isShowing(doc2), "new tab's editor has focus")
                show(firstDocument)
                report(isShowing(firstDocument) && window.firstResponder === editorText(of: firstDocument), "selecting a tab")
                closeTab(of: doc)
                closeTab(of: doc2)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    report(documents(in: window).count == 1 && NSApp.windows.count == windowsBefore, "closing a tab")
                    try? FileManager.default.removeItem(at: url)
                    try? FileManager.default.removeItem(at: url2)
                    Task { @MainActor in
                        await tabState(window)
                        await moveAndMerge(window)
                        await frontWindow(window)
                        await toggleCommentStage(window)
                        await paletteStage(window)
                        await dropStage(window)
                        await sidebarStage(window)
                        await themeFadeStage(window)
                        await themePreviewStage(window)
                        await settingsStage(window)
                        await manyFiles(window)
                        await crowdedStrip(window)
                        await startHintStage(window)
                        // The last line of a run that got to its end.
                        reportStayedInTheBackground()
                        print("SELFTEST DONE behavior")
                        fflush(stdout)
                        quit()
                    }
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

        await saveButtonShows(window, unsaved: true)

        doc.save(withDelegate: nil, didSave: nil, contextInfo: nil)
        let saved = await lag(dirty: false)
        report(within(saved), "a save clears the tab's dot within 50 ms of the document (document \(ms(saved.document)), tab \(ms(saved.tab)))")
        await saveButtonShows(window, unsaved: false)

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
        guard let d2 = opened, await time({ DocumentWindow.window(of: d2) === window }) != nil,
              let t1 = model.list.first, let t2 = model.tab(for: d2) else {
            report(false, "a second tab opens for the tab model checks"); return
        }
        let model2 = model
        let joined = await time { model.items.map(\.id) == [t1.id, t2.id] && model.selected == t2.id }
        report(joined != nil, "a new tab shows in the window's strip after the first, selected (\(model.items.map(\.title)), \(ms(joined)))")
        // No system tabs: no window of its own, nor a tab bar of macOS's.
        report(window.tabbingMode == .disallowed && window.tabbedWindows == nil && DocumentWindow.all.count == 1
               && window.titlebarAccessoryViewControllers.isEmpty,
               "the new tab is in the window, not a window joined to it: no system tab group or tab bar (\(DocumentWindow.all.count) windows)")
        // Its own tab grows in beside the one there; the strip never
        // showed it alone.
        report(Array(model.shown.suffix(2)) == [[t1.id], [t1.id, t2.id]],
               "the strip goes from the one tab to both in one step (\(model.shown.suffix(2).map(\.count)))")
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

        // Back to the first tab: it shows at once, its editor with it.
        model.select(t1)
        let back = await time { model.selected == t1.id && model.items.count == 2 && model.items.last?.path == d2.fileURL?.path
            && findTextView(in: window.contentView) === t1.container.textView }
        report(back.map { $0 <= quick } ?? false, "a tab selected again shows at once, with its own editor, and the strip as it is now (\(ms(back)))")

        // The other tab closes while this one shows.
        model.close(t2.id)
        let closed = await time { model.items.map(\.id) == [t1.id] }
        report(closed.map { $0 <= .milliseconds(300) } ?? false, "a tab closed while another shows leaves the strip (\(ms(closed)))")
    }

    /// Window ▸ Move Tab to New Window and Merge All Windows move tabs whole
    /// (the editor goes along), and a click on a tab in the strip selects it.
    private static func moveAndMerge(_ original: NSWindow) async {
        guard let window = original as? DocumentNSWindow, let first = shownDocument(in: window) else {
            report(false, "the first window, for Move Tab and Merge"); return
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kiri-move-test-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = ["move-a.txt", "move-b.txt"].map { name -> URL in
            let url = dir.appendingPathComponent(name)
            try? "\(name)\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            KiriCLI.open(KiriCLI.Request(entries: urls.map { .file($0, line: 0, column: 0) })) { c.resume() }
        }
        let clock = ContinuousClock()
        func wait(_ seconds: Double = 3, until done: () -> Bool) async -> Bool {
            let start = clock.now
            while clock.now - start < .seconds(seconds) {
                if done() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return done()
        }
        guard await wait(until: { documents(in: window).count == 3 }), let moved = documents(in: window).last,
              let editor = editorText(of: moved) else {
            report(false, "two files open as tabs for Move Tab and Merge (\(documents(in: window).count) tabs)"); return
        }
        defer { for url in urls { NSDocumentController.shared.document(for: url)?.close() } }
        FrontEditor.shared.selfTestMain(window)
        WindowAction.moveTabToNewWindow()
        var other: NSWindow?
        let movedOut = await wait {
            other = DocumentWindow.window(of: moved)
            return other.map { $0 !== window && $0.isVisible } ?? false
        }
        report(movedOut && documents(in: other) == [moved] && documents(in: window).count == 2 && editorText(of: moved) === editor
               && DocumentWindow.all.count == 2,
               "Window ▸ Move Tab to New Window gives the tab a window of its own, its editor with it, and the others stay (\(documents(in: window).count) tabs left, \(DocumentWindow.all.count) windows)")
        show(first)
        FrontEditor.shared.selfTestMain(window)
        WindowAction.mergeAllWindows()
        let merged = await wait { DocumentWindow.all.count == 1 && documents(in: window).count == 3 }
        report(merged && documents(in: window).last === moved && isShowing(first) && editorText(of: moved) === editor
               && other.map { !$0.isVisible } ?? false,
               "Window ▸ Merge All Windows brings the other window's tabs in after this window's, which keeps the tab it showed, and the other window closes (\(DocumentWindow.all.count) windows, \(documents(in: window).count) tabs)")

        // A click on a tab in the strip, as a mouse down and up in the
        // window (posted to this app only; the pointer doesn't move).
        let target = documents(in: window)[1]
        await wakeAccessibility()
        let tab = accessibilityElements(of: window).first {
            $0.role == NSAccessibility.Role.button.rawValue && $0.name == target.displayName && $0.frame.minY > window.frame.maxY - 60
        }
        if let tab, window.occlusionState.contains(.visible) {
            let point = window.convertPoint(fromScreen: NSPoint(x: tab.frame.midX, y: tab.frame.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseDown ? 1 : 0) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            let clicked = await wait(2) { isShowing(target) }
            report(clicked, "a click on a tab in the strip shows it (the drag that pulls a tab out doesn't get in the way of a click)")
        } else {
            print("SELFTEST SKIP a click on a tab in the strip (the window is covered or the screen locked: SwiftUI isn't updating it)")
        }
        show(first)
    }

    /// Save says what the tab's dot says, by its shape and to VoiceOver:
    /// one button named Save, a 30 pt circle with "No unsaved changes" for
    /// its value while there is nothing to save, the wider pill with
    /// "Unsaved changes" once there is. Read from what VoiceOver is given,
    /// which SwiftUI keeps current only for a window that can be seen.
    private static func saveButtonShows(_ window: NSWindow, unsaved: Bool) async {
        await wakeAccessibility()
        func buttons() -> [AccessibilityElement] {
            accessibilityElements(of: window).filter { $0.name == "Save" && $0.role == NSAccessibility.Role.button.rawValue }
        }
        func shaped(_ e: AccessibilityElement?) -> Bool {
            guard let e, e.frame.height >= 24 else { return false }
            return unsaved ? e.frame.width >= 60 : abs(e.frame.width - HoneyTaskButton.height) <= 1
        }
        // Long enough for the spring to come to rest, and a little more.
        var named = buttons()
        for _ in 0..<8 where !shaped(named.first) {
            try? await Task.sleep(for: .milliseconds(150))
            named = buttons()
        }
        let visible = window.occlusionState.contains(.visible)
        let state = unsaved ? "unsaved" : "saved"
        // What it says.
        let said = named.count == 1 && named[0].value == (unsaved ? "Unsaved changes" : "No unsaved changes")
        if said || visible {
            report(said, "Save says “\(unsaved ? "Unsaved changes" : "No unsaved changes")” while the tab is \(state) (\(named.count) named Save, value “\(named.first?.value ?? "")”)")
        } else {
            print("SELFTEST SKIP what Save says while the tab is \(state) (the window is covered or the screen locked: SwiftUI isn't updating it)")
        }
        // Its shape, from the frame VoiceOver is given. After a change
        // that was animated that frame catches up some time after the
        // spring has, and in a window that draws no frames (covered, the
        // screen locked) not at all, so only a run with Motion: Off can
        // say the shape is wrong.
        let size = "\(named.first?.frame.width ?? 0) × \(named.first?.frame.height ?? 0) pt"
        let what = "Save is \(unsaved ? "the pill" : "a 30 pt circle") while the tab is \(state)"
        if shaped(named.first) || UserDefaults.standard.string(forKey: Prefs.motionKey) == HoneyMotionLevel.off.rawValue {
            report(shaped(named.first), "\(what) (\(size))")
        } else {
            print("SELFTEST SKIP \(what) (the frame VoiceOver is given hasn't followed the spring yet, \(size); -motion off checks the shape)")
        }
    }

    // MARK: The menus act on the window in front

    /// The menu items are the app's, and each document window has an editor
    /// of its own: Find, Save and the rest go to the one in front
    /// (`FrontEditor`), wherever in that window the keyboard is, and are
    /// off when the window in front isn't a document's.
    private static func frontWindow(_ original: NSWindow) async {
        guard let main = NSApp.mainMenu, let file = main.item(withTitle: "File")?.submenu,
              let find = main.item(withTitle: "Edit")?.submenu?.item(withTitle: "Find")?.submenu,
              let first = (findTextView(in: original.contentView) as? KiriTextView)?.delegate as? EditorController else {
            report(false, "the File and Edit ▸ Find menus"); return
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kiri-front-test-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("front.txt")
        try? "second window\n".write(to: url, atomically: true, encoding: .utf8)
        // In a window of its own, as `kiri -n` opens it.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            KiriCLI.open(KiriCLI.Request(newWindow: true, entries: [.file(url, line: 0, column: 0)])) { c.resume() }
        }
        let opened = NSDocumentController.shared.document(for: url)
        let clock = ContinuousClock()
        func wait(_ seconds: Double = 3, until done: () -> Bool) async -> Bool {
            let start = clock.now
            while clock.now - start < .seconds(seconds) {
                if done() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return done()
        }
        var second: (window: NSWindow, text: KiriTextView, controller: EditorController)?
        _ = await wait {
            guard let doc = opened, let w = Editors.window(for: doc), w !== original, let tv = editorText(of: doc),
                  let c = tv.delegate as? EditorController, c.document === doc else { return false }
            second = (w, tv, c)
            return true
        }
        guard let doc = opened, let second else { report(false, "a second document opens for the menu checks"); return }
        /// The menus as they would be with `window` in front and about to open.
        func front(_ window: NSWindow?) async {
            FrontEditor.shared.selfTestMain(window)
            await settle(250)
            updateMenu(main)
        }
        func item(_ title: String, in menu: NSMenu) -> NSMenuItem? { menu.items.first { $0.title == title } }
        @discardableResult func choose(_ title: String, in menu: NSMenu) -> Bool {
            guard let i = menu.items.firstIndex(where: { $0.title == title }), menu.items[i].isEnabled else { return false }
            menu.performActionForItem(at: i)
            return true
        }
        first.model.find.close()

        // Find: the front window's bar, also with the keyboard in its field.
        await front(second.window)
        let found = choose("Find…", in: find)
        await settle(200)
        report(found && second.controller.model.find.isOpen && !first.model.find.isOpen,
               "Edit ▸ Find… opens the find bar of the window in front, not the other's")
        let inField = await wait(1.5) { fieldEditor(of: second.window) != nil }
        let replaced = choose("Find and Replace…", in: find)
        await settle(200)
        if inField || second.window.occlusionState.contains(.visible) {
            report(inField && replaced && second.controller.model.find.showsReplace && !first.model.find.isOpen,
                   "with the keyboard in the find field, Find and Replace… still goes to that window's bar")
        } else {
            print("SELFTEST SKIP the Find items with the keyboard in the find field (the window is covered or the screen locked: SwiftUI isn't giving the field the keyboard)")
            report(replaced && second.controller.model.find.showsReplace && !first.model.find.isOpen,
                   "Find and Replace… goes to the bar of the window in front")
        }
        second.controller.model.find.close()

        // Save and Revert: the front window's document.
        report(item("Save", in: file)?.isEnabled == true && item("Revert to Saved", in: file)?.isEnabled == false,
               "File ▸ Save is on for the document in front, Revert to Saved off while it has no changes")
        second.window.makeFirstResponder(second.text)
        second.text.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
        await settle(250)
        updateMenu(main)
        let revertOn = item("Revert to Saved", in: file)?.isEnabled == true
        // The other window's document, which the Save must leave alone.
        let other = NSDocumentController.shared.document(for: original)
        let otherEdited = other?.isDocumentEdited, otherFile = other?.fileURL.map { FileState($0) }
        let saved = choose("Save", in: file)
        let clean = await wait { !doc.isDocumentEdited }
        report(revertOn && saved && clean && (try? String(contentsOf: url, encoding: .utf8)) == "edited second window\n"
               && other != nil && other?.isDocumentEdited == otherEdited && other?.fileURL.map { FileState($0) } == otherFile,
               "once it has changes Revert to Saved is on, and File ▸ Save saves the document in front, only that one")

        // No document window in front: Settings, a panel, or nothing.
        await front(NSWindow())
        report(FrontEditor.shared.editor == nil && FrontEditor.shared.document == nil
               && item("Save", in: file)?.isEnabled == false && item("Save As…", in: file)?.isEnabled == false
               && item("Revert to Saved", in: file)?.isEnabled == false,
               "with a window in front that isn't a document's, the document items are off")
        // And the way AppKit says it: the notifications.
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: second.window)
        let byNotification = FrontEditor.shared.editor === second.controller.model
        NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: second.window)
        report(byNotification && FrontEditor.shared.editor == nil, "the front window is followed by its becoming and resigning main")

        // ⌘S as a key, the way it mostly comes: nobody has opened the File
        // menu since this window came forward, and the items were last
        // drawn off (no document window in front). The key has to find
        // Save on all the same.
        FrontEditor.shared.selfTestMain(second.window)
        second.text.insertText("keyed ", replacementRange: NSRange(location: 0, length: 0))
        await settle(250)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: second.window.windowNumber, context: nil, characters: "s",
                                   charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)
        let saveBefore = item("Save", in: file)?.isEnabled
        // Through the app's own event queue, as a pressed key comes.
        if let key { NSApp.postEvent(key, atStart: false) }
        let keyed = await wait { !doc.isDocumentEdited }
        report(saveBefore == false && keyed && (try? String(contentsOf: url, encoding: .utf8)) == "keyed edited second window\n",
               "⌘S saves the document in front though the File menu was last drawn with Save off and hasn't been opened since")
        let start = clock.now
        for _ in 0..<20 { MainMenu.refresh() }
        let each = (clock.now - start) / 20
        report(each < .milliseconds(4), "bringing the menus up to date before a key costs \(each.formatted(.units(allowed: [.microseconds])))")
        FrontEditor.shared.selfTestMain(nil)

        second.window.performClose(nil)
        _ = await wait { DocumentWindow.all.count == 1 }
        await front(original)
    }

    // MARK: Toggle Comment

    /// A key pressed with the keyboard in `window`, through the app's own
    /// event queue, as a pressed key comes (it reaches only this instance).
    private static func pressKey(_ characters: String, unmodified: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags,
                                 in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, characters: characters, charactersIgnoringModifiers: unmodified,
                                        isARepeat: false, keyCode: code) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }

    /// ⌘/ as a key: comments the lines the selection touches and
    /// uncomments them again, as one undo step each, with the selection on
    /// the same text; off in a format without comments. And ⌘? (⇧⌘/),
    /// where Keyboard Shortcuts went to make room.
    private static func toggleCommentStage(_ window: NSWindow) async {
        guard let main = NSApp.mainMenu, let format = main.item(withTitle: "Format")?.submenu,
              let help = main.items.last?.submenu,
              let ktv = findTextView(in: window.contentView) as? KiriTextView,
              let controller = ktv.delegate as? EditorController else { report(false, "the Format and Help menus"); return }
        let clock = ContinuousClock()
        func wait(_ seconds: Double = 2, until done: () -> Bool) async -> Bool {
            let start = clock.now
            while clock.now - start < .seconds(seconds) {
                if done() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return done()
        }
        func shortcutsWindow() -> NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue == ShortcutsView.windowID && $0.isVisible }
        }
        /// Presses a menu item's key as this keyboard has it. macOS moves
        /// some keys for the layout in use (⌘/ is ⌘´ on a Swedish one),
        /// so the key is read from the item, and the key code and Shift
        /// that give its character are looked up in the layout.
        func press(_ item: NSMenuItem?) -> String {
            guard let item, !item.keyEquivalent.isEmpty else { return "no key" }
            let key = item.keyEquivalent
            var flags = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            var code: UInt16?
            for shift in [false, true] where code == nil {
                // (Not the keypad's keys, from 65 on.)
                code = (0..<65 as Range<UInt16>).first { c in
                    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: c)?
                        .characters(byApplyingModifiers: shift ? .shift : []) == key
                }
                if code != nil, shift { flags.insert(.shift) }
            }
            pressKey(key, unmodified: key, code: code ?? 44, flags, in: window)
            return "\(flags.contains(.shift) ? "⇧" : "")⌘\(key), key code \(code.map(String.init) ?? "not in this layout")"
        }
        FrontEditor.shared.selfTestMain(window)
        window.makeFirstResponder(ktv)
        await settle(250)
        updateMenu(main)
        func mask(_ item: NSMenuItem?) -> NSEvent.ModifierFlags { item?.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) ?? [] }
        let toggle = format.item(withTitle: "Toggle Comment"), shortcuts = help.item(withTitle: "Keyboard Shortcuts")
        // On a U.S. keyboard they are "/" and "?"; another layout may have
        // them elsewhere, and the menu then says where.
        let us = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "",
                                  charactersIgnoringModifiers: "", isARepeat: false, keyCode: 44)?.characters(byApplyingModifiers: []) == "/"
        report(Keys.toggleComment.key == "/" && Keys.toggleComment.modifiers == .command && Keys.shortcuts.key == "?"
               && Keys.shortcuts.modifiers == .command && toggle?.isEnabled == true && mask(toggle) == .command
               && mask(shortcuts) == .command && (!us || toggle?.keyEquivalent == "/" && shortcuts?.keyEquivalent == "?")
               && toggle?.keyEquivalent.isEmpty == false && shortcuts?.keyEquivalent.isEmpty == false,
               "Format ▸ Toggle Comment is on ⌘/ and Help ▸ Keyboard Shortcuts on ⌘? (in the menus of this keyboard: ⌘\(toggle?.keyEquivalent ?? "none"), ⌘\(shortcuts?.keyEquivalent ?? "none"))")

        // Two lines, from inside the first to inside the second.
        let original = ktv.string, ns = original as NSString
        let name = ns.range(of: "let name: String"), count = ns.range(of: "var count")
        guard controller.model.language == .swift, name.location != NSNotFound, count.location != NSNotFound,
              count.location > name.location else {
            report(false, "the Swift sample has the lines the comment test selects"); return
        }
        let selection = NSRange(location: name.location + 4, length: count.location + 3 - name.location - 4)
        let selected = ns.substring(with: selection)
        let block = ns.lineRange(for: selection)
        let lines = ns.substring(with: block).components(separatedBy: "\n").dropLast()
        let indent = lines.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        let expected = lines.map { String($0.prefix(indent)) + "// " + $0.dropFirst(indent) }.joined(separator: "\n") + "\n"
        ktv.setSelectedRange(selection)
        let editedBefore = NSDocumentController.shared.document(for: window)?.isDocumentEdited

        let pressed = press(toggle)
        let commented = await wait { ktv.string != original }
        let after = ktv.string as NSString
        let commentedBlock = after.length >= block.location + (expected as NSString).length
            ? after.substring(with: NSRange(location: block.location, length: (expected as NSString).length)) : ""
        report(commented && commentedBlock == expected && after.length == ns.length + 3 * lines.count
               && after.substring(with: ktv.selectedRange()) == selected.replacingOccurrences(of: "\n    ", with: "\n    // ")
               && shortcutsWindow() == nil,
               "⌘/ comments the lines the selection touches, the marker at their least indentation, the selection on the same text, and doesn't open Keyboard Shortcuts (pressed \(pressed); “\(commentedBlock.replacingOccurrences(of: "\n", with: "⏎"))”, selected “\(after.substring(with: ktv.selectedRange()).replacingOccurrences(of: "\n", with: "⏎"))”)")
        await settle()
        let actionName = ktv.undoManager?.undoActionName
        ktv.undoManager?.undo()
        let undone = ktv.string == original
        ktv.undoManager?.redo()
        report(actionName == "Toggle Comment" && undone && (ktv.string as NSString).substring(with: NSRange(location: block.location, length: (expected as NSString).length)) == expected,
               "it is one undo step called Toggle Comment (“\(actionName ?? "")”), and redo brings it back")

        // Again: every line is commented now, so the markers come off.
        ktv.setSelectedRange(NSRange(location: selection.location + 3, length: selection.length + 3 * (lines.count - 1)))
        _ = press(format.item(withTitle: "Toggle Comment"))
        let uncommented = await wait { ktv.string == original }
        report(uncommented && ktv.selectedRange() == selection,
               "⌘/ again uncomments them, the selection back where it was (\(ktv.selectedRange()) of \(selection))")
        await settle()
        // Back to the text and the undo state the stage started with.
        ktv.undoManager?.undo()
        ktv.undoManager?.undo()
        await settle()
        report(ktv.string == original && NSDocumentController.shared.document(for: window)?.isDocumentEdited == editedBefore,
               "undone twice, the document is as it was")

        // A format without comments: the item is off and the key does nothing.
        controller.model.language = .plainText
        await settle(250)
        updateMenu(main)
        let offForPlainText = format.item(withTitle: "Toggle Comment")?.isEnabled == false
        ktv.setSelectedRange(selection)
        _ = press(format.item(withTitle: "Toggle Comment"))
        await settle(300)
        report(offForPlainText && ktv.string == original && shortcutsWindow() == nil,
               "in plain text Toggle Comment is off and ⌘/ changes nothing")
        controller.model.language = .swift
        await settle(250)
        updateMenu(main)

        // ⌘?: the Keyboard Shortcuts window. (The item's key is "?" with
        // Command, as AppKit's own Help items have it: an item on "/" with
        // Shift and Command is never matched by a pressed ⇧⌘/, whose
        // character is "?", and the press falls through to ⌘/.)
        _ = press(help.item(withTitle: "Keyboard Shortcuts"))
        let opened = await wait { shortcutsWindow() != nil }
        report(opened && ktv.string == original, "⌘? (⇧⌘/ as the keyboard sends it) opens Keyboard Shortcuts and leaves the text alone")
        shortcutsWindow()?.close()
        _ = await wait { shortcutsWindow() == nil }
        ktv.setSelectedRange(NSRange(location: 0, length: 0))
        window.makeFirstResponder(ktv)
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
        func group(_ w: NSWindow) -> Set<ObjectIdentifier> { Set(documents(in: w).map { ObjectIdentifier($0) }) }
        /// "8 of 8 open, windows of [9] tabs": how many of the files have a tab,
        /// and how many tabs the windows they are in have.
        func shape(_ ws: [NSWindow], of count: Int) -> String {
            "\(ws.count) of \(count) open, windows of \(Set(ws.map(group)).map(\.count).sorted(by: >)) tabs"
        }
        /// All of `ws` are tabs of one window.
        func together(_ ws: [NSWindow]) -> Bool { Set(ws.map(group)).count == 1 }

        // The `kiri` command, eight files: tabs of the front window.
        let cli = files("cli", 8)
        KiriCLI.open(KiriCLI.Request(entries: entries(cli)))
        var ws = await settledWindows(cli)
        let order = documents(in: original).suffix(8).map { $0.fileURL?.lastPathComponent ?? "" }
        report(ws.count == 8 && together(ws) && group(original).count == 9 && ws.allSatisfy { group($0) == group(original) }
               && order == cli.map(\.lastPathComponent),
               "kiri with 8 files: all tabs of the front window, in order (\(shape(ws, of: 8)); \(order.first ?? "")…\(order.last ?? ""))")

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
        let group = documents(in: original)
        guard group.count >= 12, let tabs = WindowTabs.model(for: original) else {
            report(false, "a crowded strip to look at (\(group.count) tabs)"); return
        }
        await wakeAccessibility()
        let width = original.frame.width
        defer {
            original.setFrame(NSRect(x: original.frame.minX, y: original.frame.minY, width: width, height: original.frame.height), display: true)
        }
        for narrow in [false, true] {
            if narrow {
                original.setFrame(NSRect(x: original.frame.minX, y: original.frame.minY, width: 480, height: original.frame.height), display: true)
            }
            // The last tab is the one a scroll view could leave cut off:
            // selected, it grows past where the content ended.
            for (position, doc) in [("last", group.last), ("first", group.first), ("middle", group[group.count / 2])] {
                guard let doc, let tab = tabs.tab(for: doc) else { continue }
                tabs.select(tab)
                // In front of Kiri's other windows (the app itself stays in
                // the background): SwiftUI leaves a covered window's
                // views alone until it shows.
                original.orderFront(nil)
                try? await Task.sleep(for: .milliseconds(100))
                // Nor one that can't be seen at all: behind a locked screen
                // or other apps' windows its strip never hears of the
                // selection (`onChange` waits for the window to show).
                guard original.occlusionState.contains(.visible) else {
                    print("SELFTEST SKIP \(group.count) tabs at \(Int(original.frame.width)) pt, \(position) selected (the window is covered or the screen locked: SwiftUI isn't updating it)")
                    continue
                }
                // Long enough for the selection's spring to come to rest.
                try? await Task.sleep(for: .milliseconds(900))
                let list = accessibilityElements(of: original)
                let strip = list.first { $0.role == NSAccessibility.Role.scrollArea.rawValue && $0.name == "Tabs" }?.frame
                let selected = list.first { $0.role == NSAccessibility.Role.button.rawValue && $0.selected }
                let after = list.filter { ["New Tab", "Save"].contains($0.name) }.map(\.frame)
                let inView = strip.map { s in selected.map { $0.frame.minX >= s.minX - 0.5 && $0.frame.maxX <= s.maxX + 0.5 } ?? false } ?? false
                let room = strip.map { s in after.count == 2 && after.allSatisfy { $0.minX >= s.maxX && $0.maxX <= original.frame.maxX - Honey.gap + 0.5 } } ?? false
                report(inView && room && selected?.name == doc.displayName,
                       "\(group.count) tabs at \(Int(original.frame.width)) pt, \(position) selected: whole in the strip, + and Save in the window (strip \(strip.map { "\($0.minX)…\($0.maxX)" } ?? "none"), “\(selected?.name ?? "none")” \(selected.map { "\($0.frame.minX)…\($0.frame.maxX)" } ?? ""), buttons \(after.map { "\($0.minX)…\($0.maxX)" }))")
            }
        }
    }

    /// What VoiceOver is given for a window, flattened: each element's role,
    /// name, frame on screen and whether it is selected.
    struct AccessibilityElement {
        let role: String, name: String, value: String, frame: NSRect, selected: Bool, focused: Bool
        let object: AnyObject

        /// Presses it, as VoiceOver would.
        @MainActor func press() {
            _ = object.perform(NSSelectorFromString("accessibilityPerformPress"))
        }

        /// What VoiceOver's "increment" does to an adjustable element.
        @MainActor func increment() {
            _ = object.perform(NSSelectorFromString("accessibilityPerformIncrement"))
        }

        /// The names of its custom actions (VoiceOver's Actions menu).
        @MainActor var actions: [String] {
            let selector = NSSelectorFromString("accessibilityCustomActions")
            guard object.responds(to: selector) else { return [] }
            return (object.perform(selector)?.takeUnretainedValue() as? [NSAccessibilityCustomAction] ?? []).map(\.name)
        }
    }

    /// The name of the control VoiceOver is told has the keyboard.
    private static func focusedName(in window: NSWindow) -> String {
        accessibilityElements(of: window).last { $0.focused && !$0.name.isEmpty && $0.role != NSAccessibility.Role.group.rawValue }?.name ?? "nothing"
    }

    /// SwiftUI builds its accessibility elements once something has asked
    /// this process for them, from another thread.
    static func wakeAccessibility() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                var value: AnyObject?
                AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &value)
                c.resume()
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    static func accessibilityElements(of root: Any, depth: Int = 0) -> [AccessibilityElement] {
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
            let focused = o.responds(to: NSSelectorFromString("isAccessibilityFocused"))
                && o.value(forKey: "accessibilityFocused") as? Bool == true
            list.append(AccessibilityElement(role: ask("accessibilityRole") as? String ?? "", name: name,
                                             // (An adjustable element says its value in words apart.)
                                             value: ask("accessibilityValue") as? String ?? ask("accessibilityValueDescription") as? String ?? "",
                                             frame: frame,
                                             selected: selected, focused: focused, object: o))
        }
        guard depth < 16 else { return list }
        for child in ask("accessibilityChildren") as? [Any] ?? [] { list += accessibilityElements(of: child, depth: depth + 1) }
        return list
    }

    /// The windows of the documents for `urls`, once every one of them has a
    /// tab and the windows' tabs have stopped changing (or after 8 s).
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
            let now = ws.map { w in documents(in: w).map { ObjectIdentifier($0).hashValue } }
            if now != last { last = now; since = clock.now }
            if ws.count == names.count, clock.now - since > .milliseconds(700) { return ws }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return windows()
    }

    static func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
        return nil
    }

    // MARK: Tabs

    /// The tab that shows `doc`.
    static func documentTab(of doc: NSDocument?) -> DocumentTab? { doc.flatMap { DocumentWindow.tab(of: $0) } }

    /// The editor of `doc`'s tab, showing or not.
    static func editorText(of doc: NSDocument?) -> KiriTextView? { documentTab(of: doc)?.container.textView }

    /// `doc`'s tab is the one its window shows.
    static func isShowing(_ doc: NSDocument?) -> Bool {
        documentTab(of: doc).map { $0.window?.tabs.selectedTab === $0 } ?? false
    }

    /// Brings `doc`'s tab forward in its window.
    static func show(_ doc: NSDocument?) {
        if let tab = documentTab(of: doc) { tab.window?.tabs.select(tab) }
    }

    /// The tab's close button: closes `doc`'s tab, asking first if it has
    /// unsaved changes.
    static func closeTab(of doc: NSDocument?) {
        if let tab = documentTab(of: doc), let window = tab.window { window.tabs.close(tab.id) }
    }

    /// The documents of `window`'s tabs, in order.
    static func documents(in window: NSWindow?) -> [KiriDocument] {
        (window as? DocumentNSWindow)?.tabs.list.map(\.document) ?? []
    }

    /// The document of the tab `window` shows.
    static func shownDocument(in window: NSWindow?) -> KiriDocument? {
        (window as? DocumentNSWindow)?.tabs.selectedTab?.document
    }
}

/// The top bar's row laid out as `EditorScreen.topBar` does, around a tab
/// strip of made-up tabs, for `-KiriRenderTabs`.
struct TabStripSample: View {
    let caption: String
    let tabs: [HoneyTab<Int>]
    let selected: Int
    var sidebar = false
    let width: CGFloat
    var save = HoneyTaskState.idle

    /// As in a window: Save is the pill while the tab that shows is unsaved.
    private var unsaved: Bool { tabs.first { $0.id == selected }?.dirty ?? false }

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
                HoneyTaskButton("Save", systemImage: "square.and.arrow.down", state: save, pending: unsaved) {}
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
        // A preview tab (a file clicked once in the sidebar): its title slants.
        for selected in [3, 0] {
            var four = tabs(Array(names.prefix(4)), dirty: [])
            four[3].preview = true
            rows.append(TabStripSample(caption: "folder window, tab 4 a preview, tab \(selected + 1) selected", tabs: four,
                                       selected: selected, sidebar: true, width: width))
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { rows[$0] }
        }
        .background(Color.honeyCanvas)
        .environment(\.honeyOffscreen, true)
        .honeyRoot(HoneyAppearance())
    }
}

/// The Save button's states in the top bar's row, for `-KiriRenderSave`.
enum SaveButtonSample {
    /// One theme's rows. `Honey.theme` is that theme while it is drawn.
    @MainActor static func block(_ theme: Honey.Theme, _ scheme: ColorScheme) -> some View {
        let one = TabStripSample.tabs(["sample.swift"], dirty: []), edited = TabStripSample.tabs(["sample.swift"], dirty: [0])
        let many = Array(TabStripSample.names.prefix(12))
        let rows: [TabStripSample] = [
            TabStripSample(caption: "nothing to save: a glass circle", tabs: one, selected: 0, width: 480),
            TabStripSample(caption: "unsaved changes: the accent pill", tabs: edited, selected: 0, width: 480),
            TabStripSample(caption: "saving", tabs: edited, selected: 0, width: 480, save: .busy),
            TabStripSample(caption: "saved, for 1.5 s", tabs: one, selected: 0, width: 480, save: .done),
            TabStripSample(caption: "12 tabs at 480 pt, nothing to save", tabs: TabStripSample.tabs(many, dirty: []), selected: 5, width: 480),
            TabStripSample(caption: "12 tabs at 480 pt, unsaved: the strip gives the pill its room",
                           tabs: TabStripSample.tabs(many, dirty: [5]), selected: 5, width: 480),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            Text(theme.name).font(.honey(.subheadline, weight: .heavy)).foregroundStyle(Color.honeyFg)
                .padding(.leading, Honey.gap).padding(.top, 8)
            ForEach(rows.indices, id: \.self) { rows[$0] }
        }
        .padding(.bottom, 8)
        .background(Color.honeyCanvas)
        .environment(\.honeyOffscreen, true)
        .environment(\.colorScheme, scheme)
        .honeyRoot(HoneyAppearance())
    }

    /// The button's width as SwiftUI lays it out.
    @MainActor static func width(_ state: HoneyTaskState, pending: Bool) -> CGFloat {
        ImageRenderer(content: HoneyTaskButton("Save", systemImage: "square.and.arrow.down", state: state, pending: pending) {}
            .honeyRoot(HoneyAppearance())).nsImage?.size.width ?? 0
    }

    /// The pill as it was before it had a resting look: a plain `Label`.
    @MainActor static var plainPillWidth: CGFloat {
        ImageRenderer(content: Label("Save", systemImage: "square.and.arrow.down").font(.honey(.subheadline, weight: .bold))
            .padding(.horizontal, 14).frame(height: 30).honeyRoot(HoneyAppearance())).nsImage?.size.width ?? 0
    }
}

/// The find bar in its states, for `-KiriRenderFind` (Go to Line is the
/// command palette's, `-KiriRenderPalette`): each
/// over a strip of the editor's paper, as wide as a default window's editor
/// and as narrow as the narrowest.
private enum FindBarSample {
    @MainActor static func sheet(_ scheme: ColorScheme) -> some View {
        let regex = SearchOptions(matchCase: true, regularExpression: true)
        let bars: [(String, FindController, FindBar.Field?)] = [
            ("no query", .sample(query: "", status: .idle), .query),
            ("matches, on the third", .sample(query: "count", status: .found(current: 2, total: 12, more: false)), .query),
            ("matches, the editor has the keyboard and is on none of them",
             .sample(query: "count", status: .found(current: nil, total: 12, more: false)), nil),
            ("no matches", .sample(query: "cuont", status: .none), .query),
            ("match case and regular expression on, an invalid pattern", .sample(query: "func (", status: .invalid, options: regex), .query),
            ("more matches than are counted", .sample(query: "e", status: .found(current: 41, total: 100_000, more: true)), .query),
            ("replace row", .sample(query: "count", status: .found(current: 0, total: 4, more: false), replacement: "tally"), .replacement),
            ("replace row, after Replace All",
             .sample(query: "count", status: .none, replacement: "tally", notice: "Replaced 4"), .replacement),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            ForEach([860.0, 460.0], id: \.self) { width in
                ForEach(bars.indices, id: \.self) { i in
                    strip("\(bars[i].0), \(Int(width)) pt", width: width) { FindBar(find: bars[i].1, sampleFocus: bars[i].2) }
                }
            }
        }
        .padding(16)
        .background(Color.honeyCanvas)
        .environment(\.honeyOffscreen, true)
        .environment(\.colorScheme, scheme)
        .honeyRoot(HoneyAppearance())
    }

    @MainActor private static func strip(_ caption: String, width: CGFloat, @ViewBuilder bar: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption).font(.system(size: 10)).foregroundStyle(Color.honeyMuted)
            bar()
                .padding(.top, EditorBar.topPadding)
                .padding(.bottom, EditorBar.clearance)
                .frame(width: width)
                .background(Color.honeySurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
/// The status bar in given states with no editor behind it, for
/// `-KiriRenderStatus` and for measuring that its width holds.
enum StatusBarSample {
    @MainActor static func model(line: Int = 12, column: Int = 5, selected: Int = 0, lineCount: Int = 40, longestLine: Int = 62,
                                 length: Int = 1200, language: Language = .swift, indent: IndentStyle = .spaces(4)) -> EditorModel {
        let model = EditorModel()
        model.line = line
        model.column = column
        model.selectedLength = selected
        model.lineCount = lineCount
        model.language = language
        model.indent = indent
        model.positionReserve = StatusText.Reserve(lineCount: lineCount, longestLine: longestLine, length: length)
        return model
    }

    @MainActor static func bar(_ model: EditorModel, document: KiriDocument = KiriDocument(),
                               showing: (item: EditorStatusBar.Item, as: HoneyStatusHighlight)? = nil) -> some View {
        EditorStatusBar(model: model, document: document, encoding: .constant(document.encoding),
                        lineEnding: .constant(document.lineEnding), byteOrderMark: .constant(document.hasBOM), showing: showing)
            .environment(\.honeyOffscreen, true)
            .honeyRoot(HoneyAppearance())
    }

    /// The bar's width (with its side margins) as SwiftUI lays it out.
    @MainActor static func width(_ model: EditorModel) -> CGFloat {
        ImageRenderer(content: bar(model)).nsImage?.size.width ?? 0
    }

    @MainActor static func sheet(_ scheme: ColorScheme) -> some View {
        let windows = KiriDocument()
        windows.setEncoding(.utf16LE)
        windows.setByteOrderMark(true)
        windows.setLineEnding(.crlf)
        let resting = model()
        resting.statusRest.activity()
        let long = model(line: 12345, column: 120, lineCount: 20000, longestLine: 400, length: 900_000, language: .typescript,
                         indent: .spaces(2))
        return VStack(alignment: .leading, spacing: 12) {
            strip("at rest: a 40-line Swift file, 460 pt (a 480 pt window)") { bar(model()) }
            strip("the pointer on the language") { bar(model(), showing: (.language, .hover)) }
            strip("the pointer on the position (opens Go to Line)") { bar(model(), showing: (.position, .hover)) }
            strip("the pointer on the encoding") { bar(model(), showing: (.encoding, .hover)) }
            strip("the pointer on the line endings") { bar(model(), showing: (.lineEnding, .hover)) }
            strip("the keyboard on the language") { bar(model(), showing: (.language, .focus)) }
            strip("the keyboard on the encoding") { bar(model(), showing: (.encoding, .focus)) }
            strip("line 1, column 1 (the same width)") { bar(model(line: 1, column: 1)) }
            strip("the last line, its last column") { bar(model(line: 40, column: 63)) }
            strip("a selection takes the column's place") { bar(model(selected: 128)) }
            strip("everything selected") { bar(model(line: 1, column: 1, selected: 1200)) }
            strip("resting while typing or scrolling: 35 %") { bar(resting) }
            strip("a new document: plain text, no indentation yet") {
                bar(model(line: 1, column: 1, lineCount: 1, longestLine: 0, length: 0, language: .plainText, indent: .tabs))
            }
            strip("a long file, UTF-16 with a BOM, CRLF") { bar(long, document: windows) }
            strip("330 pt: the indentation goes first", width: 330) { bar(model()) }
            strip("220 pt (a folder window at 480 pt): language and position", width: 220) { bar(model()) }
            strip("220 pt, a long file: the position alone", width: 220) { bar(long, document: windows) }
        }
        .padding(16)
        .background(Color.honeyCanvas)
        .environment(\.colorScheme, scheme)
        .honeyRoot(HoneyAppearance())
    }

    /// A bar over the last lines of a panel of text, as in a window.
    @MainActor private static func strip(_ caption: String, width: CGFloat = 460, @ViewBuilder bar: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption).font(.system(size: 10)).foregroundStyle(Color.honeyMuted)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(["    mutating func greet(_ other: String? = nil) -> String {", "        count += 1",
                         "        let who = other ?? name; return \"Hello, \\(who)! That's \\(count) so far.\""], id: \.self) {
                    Text($0).font(.honeyMono(size: 12)).foregroundStyle(Color.honeyFg).lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .frame(width: width, alignment: .leading)
            .overlay(alignment: .bottom) { bar() }
            .background(Color.honeySurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// The first-run hint on panels of the sizes a window can give it, with the
/// status bar below it, for `-KiriRenderHint`.
private enum StartHintSample {
    @MainActor static func sheet(_ scheme: ColorScheme) -> some View {
        let empty = StatusBarSample.model(line: 1, column: 1, lineCount: 1, longestLine: 0, length: 0, language: .plainText,
                                          indent: .tabs)
        func panel(_ caption: String, width: CGFloat, height: CGFloat, _ tool: CLIInstaller.Status, hovered: Int? = nil) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(caption).font(.system(size: 10)).foregroundStyle(Color.honeyMuted)
                // Line 1 and its number, where the editor draws them.
                HStack(alignment: .top, spacing: 16) {
                    Text("1").font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.honeyFg)
                    Rectangle().fill(Color.honeyCaret).frame(width: 2, height: 16)
                }
                .padding(.leading, 24)
                .padding(.top, 14)
                .frame(width: width, height: height, alignment: .topLeading)
                .overlay {
                    StartHint(commandLineTool: tool, hovered: hovered).padding(.bottom, StartHint.bottomClearance)
                }
                .overlay(alignment: .bottom) { StatusBarSample.bar(empty) }
                .background(Color.honeySurface, in: RoundedRectangle(cornerRadius: Honey.Radius.panel.value, style: .continuous))
            }
        }
        return VStack(alignment: .leading, spacing: 14) {
            panel("a 900 × 640 window: the kiri command not installed", width: 880, height: 578, .missing)
            HStack(alignment: .top, spacing: 14) {
                panel("480 pt wide: installed, three lines", width: 460, height: 340, .installed)
                panel("the pointer on a line", width: 460, height: 340, .missing, hovered: 1)
            }
            HStack(alignment: .top, spacing: 14) {
                panel("the pointer on the link", width: 460, height: 260, .missing, hovered: 3)
                panel("a folder window at 480 pt: 220 pt of paper", width: 220, height: 260, .missing)
                panel("the smallest window: 480 × 280", width: 220, height: 218, .missing)
            }
        }
        .padding(16)
        .background(Color.honeyCanvas)
        .environment(\.honeyOffscreen, true)
        .environment(\.colorScheme, scheme)
        .honeyRoot(HoneyAppearance())
    }
}
#endif
