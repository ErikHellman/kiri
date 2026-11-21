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
                            ? "  <\(i.action.map { NSStringFromSelector($0) } ?? "-") tag=\(i.tag)\(i.isHidden ? " hidden" : "")\(i.isEnabled ? "" : " disabled")>" : ""
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
                let delay = UserDefaults.standard.object(forKey: "KiriSaveDelay") as? Double ?? 0.3
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
                        await manyFiles(window)
                        NSApp.terminate(nil)
                    }
                }
            }
        }
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
#endif
