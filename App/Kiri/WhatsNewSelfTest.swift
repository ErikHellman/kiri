#if DEBUG || KIRI_SELFTEST
import AppKit
import KiriKit

extension SelfTest {
    /// What's new (`WhatsNew`), with the notes `-KiriShowWhatsNew <file>`
    /// gives it: the first tab shows them, in the first-run hint's place,
    /// with its Close line and the "Don't show after updates" box; no
    /// other tab does; Escape closes them and the hint is back; Help ▸
    /// What's New in Kiri brings them back and the first character typed
    /// ends them; a `kiri -w` request's document gives them back. None of
    /// it writes a saved preference. `-KiriWhatsNewTest YES` runs these.
    static func whatsNewStage(_ window: NSWindow, textView: NSTextView) async {
        let whatsNew = WhatsNew.shared
        let domain = Bundle.main.bundleIdentifier ?? ""
        func saved(_ key: String) -> Any? { UserDefaults.standard.persistentDomain(forName: domain)?[key] }
        let seenBefore = saved(Prefs.whatsNewSeenKey) as? String
        let enabledBefore = saved(Prefs.whatsNewKey) as? Bool
        guard let model = FrontEditor.shared.editor(in: window) else { report(false, "a document window for What's new"); return }
        await settle(300)

        // The first tab has them, on the paper of its empty document.
        let version = whatsNew.notes.first?.version ?? "?"
        await wakeAccessibility()
        var names = accessibilityElements(of: window).map(\.name)
        let title = "What's new in Kiri \(version)"
        report(whatsNew.shows(in: model) && model.showsStartHint && names.contains(title)
               && names.contains("Close, Escape") && names.contains("Don't show after updates")
               && !names.contains("Open a file, Command O"),
               "the first tab after an update shows What's new in the first-run hint's place, with Close and the box (\(whatsNew.shows(in: model)), \(names.contains(title)))")

        // One tab only: another that appears doesn't take them.
        let other = EditorModel()
        whatsNew.offer(other, document: nil)
        report(!whatsNew.shows(in: other) && whatsNew.shows(in: model), "What's new shows in one tab only")

        // A tab closed while it showed them ends them: no later tab gets
        // them (they were seen).
        do {
            var gone: EditorModel? = EditorModel()
            whatsNew.selfTestHandOver(to: gone!)
            gone = nil
            let later = EditorModel()
            whatsNew.offer(later, document: nil)
            report(!whatsNew.shows(in: later) && whatsNew.notes.isEmpty, "a tab closed with What's new showing ends it: no later tab shows it")
            whatsNew.selfTestRestore(notesOf: model)
        }

        // Escape in the editor closes it, and the hint is back.
        textView.cancelOperation(nil)
        await settle(400)
        await wakeAccessibility()
        names = accessibilityElements(of: window).map(\.name)
        report(!whatsNew.shows(in: model) && whatsNew.notes.isEmpty && !names.contains(title) && names.contains("Open a file, Command O"),
               "Escape closes What's new and the first-run hint shows again")

        // Help ▸ What's New in Kiri: the app's newest notes, in the front tab.
        if let main = NSApp.mainMenu { updateMenu(main) }
        let item = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "What's New in Kiri" }
        let hasNotes = WhatsNew.latest != nil
        report(item != nil && item?.isEnabled == hasNotes,
               "Help has What's New in Kiri, enabled when the app has notes (\(item != nil), \(item?.isEnabled ?? false), \(hasNotes))")
        if hasNotes {
            WhatsNew.showLatest()
            await settle(300)
            report(whatsNew.shows(in: model), "Help ▸ What's New in Kiri shows the notes in the front tab")
            // A `kiri -w` request's document gives them back.
            if let document = FrontEditor.shared.document {
                whatsNew.waiting(on: [document])
                let given = !whatsNew.shows(in: model) && !whatsNew.notes.isEmpty
                whatsNew.offer(model, document: nil)
                report(given && whatsNew.shows(in: model), "a kiri -w document gives What's new back to the next tab")
            }
            // The first character typed ends it, as it ends the hint.
            textView.insertText("x", replacementRange: textView.selectedRange())
            await settle(300)
            report(!whatsNew.shows(in: model) && !model.showsStartHint, "the first character typed ends What's new")
            textView.undoManager?.undo()
        }

        report((saved(Prefs.whatsNewSeenKey) as? String) == seenBefore && (saved(Prefs.whatsNewKey) as? Bool) == enabledBefore,
               "a test launch writes neither What's new preference")
    }
}
#endif
