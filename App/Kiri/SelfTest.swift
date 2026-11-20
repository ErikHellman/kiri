#if DEBUG
import AppKit
import os

/// A launch-time smoke test for the document plumbing, run with
/// `Kiri.app/Contents/MacOS/Kiri <file> -KiriSelfTest YES`: types into the
/// editor, checks the window turns dirty, saves, checks the bytes on disk,
/// undoes, reverts and quits. Results go to stdout as `SELFTEST …` lines.
@MainActor enum SelfTest {
    private static var started = false
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "KiriSelfTest") }

    static var perf: Bool { UserDefaults.standard.bool(forKey: "KiriPerfTest") }

    static func run(textView: NSTextView) {
        // Screenshot helpers: open Settings or Go to Line at launch.
        if UserDefaults.standard.bool(forKey: "KiriDumpMenus") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                func dump(_ m: NSMenu, _ d: Int) {
                    for i in m.items where !i.isSeparatorItem {
                        let key = i.keyEquivalent.isEmpty ? "" : " [\(i.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "")⌘\(i.keyEquivalent)]"
                        print(String(repeating: "  ", count: d) + i.title + key)
                        if let sub = i.submenu, d < 2 { dump(sub, d + 1) }
                    }
                }
                if let main = NSApp.mainMenu { dump(main, 0) }
                fflush(stdout)
                NSApp.terminate(nil)
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
                report(Data(shown.utf8) == Data(String(decoding: before, as: UTF8.self)
                    .replacingOccurrences(of: "\r\n", with: "\n").utf8), "revert shows the file on disk")
                NSApp.terminate(nil)
            }
        }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
    }

    private static func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
        return nil
    }
}
#endif
