import AppKit
import KiriKit
import KiriSyntax

/// Colors the editor's text. Tree-sitter parses on a background queue
/// (incrementally, after each burst of edits); only the visible part of the
/// text, plus a margin, is colored, so large files stay fast. Languages
/// without a grammar use the fallback lexer on the visible range.
@MainActor final class SyntaxHighlighter {
    private weak var textView: NSTextView?
    private(set) var language = Language.plainText
    private var parser: SyntaxParser?
    private let queue = DispatchQueue(label: "se.hellsoft.kiri.syntax", qos: .userInitiated)
    /// The latest parse, and the edit count it matches.
    private var snapshot: SyntaxSnapshot?
    private var snapshotVersion = -1
    /// Edits since the last parse started.
    private var pendingEdits: [SyntaxEdit] = []
    private var version = 0
    private var parsing = false
    /// Parts of the text colored from the current snapshot.
    private var colored = IndexSet()
    private var scheduled = false
    var baseFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Files bigger than this skip Tree-sitter and use the fallback lexer.
    static let treeSitterLimit = 10 * 1024 * 1024
    /// Extra text colored above and below the viewport, in UTF-16 units.
    static let margin = 4000

    init(textView: NSTextView) {
        self.textView = textView
    }

    var length: Int { textView?.textStorage?.length ?? 0 }

    func setLanguage(_ language: Language) {
        guard language != self.language || (parser == nil && snapshot == nil) else { return }
        self.language = language
        parser = nil
        snapshot = nil
        pendingEdits = []
        version += 1
        clearColors()
        loadingGrammar = false
        guard length <= Self.treeSitterLimit, SyntaxGrammar.supportedIDs.contains(language.id) else {
            setNeedsHighlight()
            return
        }
        // Load the grammar (compiling its query takes a moment) off the main
        // thread, then parse from scratch there too.
        loadingGrammar = true
        let generation = version
        let id = language.id
        queue.async { [weak self] in
            let parser = SyntaxGrammar.forLanguage(id: id).flatMap(SyntaxParser.init(grammar:))
            nonisolated(unsafe) let p = parser
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.language.id == id, self.loadingGrammar else { return }
                    _ = generation
                    self.loadingGrammar = false
                    self.parser = p
                    self.pendingEdits = []
                    self.startParseIfNeeded(force: true)
                    self.setNeedsHighlight()
                }
            }
        }
    }

    /// While a grammar loads, nothing is colored (instead of the fallback
    /// lexer flashing first).
    private var loadingGrammar = false

    /// The whole text was replaced (a document load).
    func textReplaced() {
        let lang = language
        language = .plainText
        parser = nil
        setLanguage(lang)
    }

    /// Call from the text storage delegate for every character edit.
    func didEdit(_ edit: SyntaxEdit) {
        version += 1
        if parser != nil { pendingEdits.append(edit) }
        colored = IndexSet()
        startParseIfNeeded()
        setNeedsHighlight()
    }

    /// The viewport moved or the fonts changed.
    func visibleRangeChanged() { setNeedsHighlight() }

    func invalidateColors() {
        colored = IndexSet()
        setNeedsHighlight()
    }

    // MARK: Parsing

    private func startParseIfNeeded(force: Bool = false) {
        guard let parser, !parsing, force || !pendingEdits.isEmpty, let storage = textView?.textStorage else { return }
        // Parse an immutable copy; later edits queue up for the next round.
        let text = storage.string.copy() as! NSString
        let edits = pendingEdits
        pendingEdits = []
        let parseVersion = version
        parsing = true
        nonisolated(unsafe) let unsafeText = text
        queue.async { [weak self] in
            let snap = parser.parse(unsafeText, edits: edits)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.parser === parser else { return }
                    self.parsing = false
                    if let snap {
                        self.snapshot = snap
                        self.snapshotVersion = parseVersion
                        self.colored = IndexSet()
                    }
                    if !self.pendingEdits.isEmpty { self.startParseIfNeeded() }
                    self.setNeedsHighlight()
                }
            }
        }
    }

    // MARK: Coloring

    private func setNeedsHighlight() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                self?.highlightVisible()
            }
        }
    }

    private func visibleRange() -> Range<Int>? {
        guard let tv = textView, let tlm = tv.textLayoutManager, let storage = tv.textStorage else { return nil }
        let len = storage.length
        guard len > 0 else { return nil }
        var lower = 0, upper = len
        if let viewport = tlm.textViewportLayoutController.viewportRange {
            lower = tlm.offset(from: tlm.documentRange.location, to: viewport.location)
            upper = tlm.offset(from: tlm.documentRange.location, to: viewport.endLocation)
        } else {
            upper = min(len, 20_000)
        }
        return max(0, lower - Self.margin)..<min(len, upper + Self.margin)
    }

    private func highlightVisible() {
        guard language != .plainText, !loadingGrammar, let range = visibleRange() else { return }
        let needed = IndexSet(integersIn: range).subtracting(colored)
        guard let first = needed.first, let last = needed.last else { return }
        let target = first..<(last + 1)
        let spans: [SyntaxSpan]
        if parser != nil {
            // Only color from a parse that matches the text exactly.
            guard let snapshot, snapshotVersion == version else { return }
            spans = snapshot.spans(in: target)
        } else {
            guard let text = textView?.string else { return }
            spans = FallbackHighlighter.spans(in: text, language: language, range: target)
        }
        apply(spans, in: target)
        colored.insert(integersIn: target)
    }

    private func apply(_ spans: [SyntaxSpan], in range: Range<Int>) {
        guard let storage = textView?.textStorage, range.upperBound <= storage.length else { return }
        let ns = NSRange(location: range.lowerBound, length: range.count)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.honey(Honey.fg), range: ns)
        storage.addAttribute(.font, value: baseFont, range: ns)
        for span in spans {
            let r = span.range.clamped(to: 0..<storage.length)
            guard !r.isEmpty else { continue }
            let nr = NSRange(location: r.lowerBound, length: r.count)
            storage.addAttribute(.foregroundColor, value: Self.color(span.kind), range: nr)
            if let font = font(for: span.kind) { storage.addAttribute(.font, value: font, range: nr) }
        }
        storage.endEditing()
    }

    private func clearColors() {
        guard let storage = textView?.textStorage, storage.length > 0 else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.honey(Honey.fg), range: all)
        storage.addAttribute(.font, value: baseFont, range: all)
        storage.endEditing()
        colored = IndexSet()
    }

    private static var colors: [SyntaxKind: NSColor] = [:]

    static func color(_ kind: SyntaxKind) -> NSColor {
        if let c = colors[kind] { return c }
        let c = NSColor.honey(kind.token)
        colors[kind] = c
        return c
    }

    private func font(for kind: SyntaxKind) -> NSFont? {
        switch kind {
        case .heading, .strong:
            NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .bold)
        case .emphasis:
            NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        default: nil
        }
    }
}
