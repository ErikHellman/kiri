import KiriKit
import SwiftUI

/// The editors of a window: the selected tab's on its panel, or two tabs
/// side by side, each on a panel of its own with `Honey.gap` of canvas
/// between them (the edge, `SplitEdge`), as the sidebar and the editor
/// are. The side with the keyboard has a thin accent edge; the other's
/// status bar stays at rest.
///
/// Each panel keeps its slot (`WindowTabs.Panel.slot`) while the other
/// comes and goes, the keyboard moves and the sides swap, so an editor
/// that shows stays where it is in the window. A new side comes in from
/// its edge on the shape spring (a fade with reduced motion, nothing with
/// Motion: Off); its text is there as it moves.
struct EditorPanels: View {
    let tabs: WindowTabs
    /// How wide the row of panels is.
    @State private var width = 0.0
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduceMotion)
        let panels = tabs.panels
        let split = panels.count > 1
        let left = SplitLayout.leftWidth(available: width, fraction: tabs.splitFraction, gap: Honey.gap)
        HStack(spacing: 0) {
            ForEach(Array(panels.enumerated()), id: \.element.id) { index, panel in
                HStack(spacing: 0) {
                    if index > 0 {
                        SplitEdge(tabs: tabs, leftWidth: left, available: width)
                    }
                    TabPanel(tabs: tabs, panel: panel, split: split)
                }
                .frame(width: split && index == 0 ? left : nil)
                .transition(transition(for: panel.side, motion))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // (Only while something is dragged over the editors: nothing of it
        // is made at launch.)
        .overlay { if let zone = tabs.dropZone { DropZone(side: zone, split: split, leftWidth: left) } }
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
        .animation(motion.shape, value: panels.map(\.id))
        .animation(motion.reduced ? nil : motion.quick, value: tabs.dropZone)
    }

    /// A side that opens comes in from its own edge.
    private func transition(for side: SplitLayout.Side, _ motion: HoneyMotion) -> AnyTransition {
        if motion.off { return .identity }
        if motion.reduced { return .opacity }
        return .move(edge: side == .left ? .leading : .trailing).combined(with: .opacity)
    }
}

/// One editor panel: a tab's editor (or the preview beside its text) on
/// the solid Honey panel, with the glass status bar floating over its
/// bottom edge and the find bar or the palette over its top.
private struct TabPanel: View {
    let tabs: WindowTabs
    let panel: WindowTabs.Panel
    /// The window shows two panels.
    let split: Bool
    private var tab: DocumentTab { panel.tab }
    private var model: EditorModel { tab.model }
    private var document: KiriDocument { tab.document }
    @State private var commandLineTool = CommandLineTool.shared
    @State private var whatsNew = WhatsNew.shared
    /// The panel's size: the command palette shows as many rows as it has
    /// room for, and fewer words in a narrow one.
    @State private var panelSize = DocumentWindow.defaultSize
    @AppStorage(Prefs.textScaleKey) private var textScale = 1.0
    @State private var editorFont = EditorFont.shared
    @AppStorage(Prefs.wrapLinesKey) private var wrapLines = true
    @AppStorage(Prefs.typingAnimationsKey) private var typingAnimations = true
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if panel.preview {
                previewBeside
            } else {
                editor
            }
        }
        // The side with the keyboard: a thin accent edge (only while
        // there are two).
        .overlay {
            if split, panel.keyboard {
                RoundedRectangle(cornerRadius: Honey.Radius.panel.value, style: .continuous)
                    .strokeBorder(Color.honeyAccent.opacity(0.75), lineWidth: 1.5)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(HoneyMotion(appearance, systemReduced: reduceMotion).quick, value: split && panel.keyboard)
        // Picking another language leaves the preview (Markdown only).
        .onChange(of: model.language) {
            guard !tab.canPreviewMarkdown else { return }
            tab.setMarkdownPreview(false)
            if tab.previewsBeside { tabs.endSplit() }
        }
    }

    /// The tab's Markdown rendered, or its SVG drawn, beside its text.
    private var previewBeside: some View {
        EditorView(tab: tab, slot: panel.slot, previewBeside: true, fontScale: textScale, fontFamily: editorFont.shown,
                   language: model.language, isUntitled: document.location == nil, wrapLines: wrapLines,
                   animation: .none, arrival: .none)
            .honeyPanel()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(tab.isSVG ? "Picture beside the text" : "Preview beside the text")
    }

    private var editor: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduceMotion)
        // The bars pop in; with Reduce Motion they fade.
        let arrive: AnyTransition = motion.reduced ? .opacity : .honeyPop
        // A file that arrives (a new tab, or the preview tab taking another
        // file) fades in on the paper, which stays put: the file arriving
        // is told in the content, never by the window.
        return EditorView(tab: tab, slot: panel.slot, fontScale: textScale, fontFamily: editorFont.shown,
                          language: model.language, isUntitled: document.location == nil, wrapLines: wrapLines,
                          animation: EditorAnimation.resolve(motion: appearance.motion, systemReduceMotion: reduceMotion,
                                                             typingAnimations: typingAnimations),
                          arrival: motion.off ? .none : motion.reduced ? .fade : .rise)
            // Under the bars: the first-run hint, on the paper of an empty
            // untitled document until something is typed into it. (Not
            // while the palette is open: its list would lie over the
            // hint's lines, glass over words.) After an update, What's new
            // takes its place until it is closed, in its look; over text,
            // on a panel of its own. (Neither under the find bar either.)
            .overlay {
                if whatsNew.shows(in: model), !model.palette.isOpen, !model.find.isOpen {
                    WhatsNewNotice(notes: whatsNew.notes, onPaper: model.showsStartHint)
                        .padding(.bottom, StartHint.bottomClearance)
                        .transition(.opacity)
                } else if model.showsStartHint, !model.palette.isOpen {
                    StartHint(commandLineTool: commandLineTool.status) { model.palette.open() }
                        .padding(.bottom, StartHint.bottomClearance)
                        .transition(.opacity)
                }
            }
            .honeyPanel()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { panelSize = $0 }
            .overlay(alignment: .bottom) {
                // The side without the keyboard keeps its bar at rest.
                EditorStatusBar(model: model, document: document, encoding: encodingBinding, lineEnding: lineEndingBinding,
                                byteOrderMark: bomBinding, quiet: split && !panel.keyboard)
            }
            .overlay(alignment: .top) {
                // One at a time: opening one closes the others.
                if model.find.isOpen {
                    FindBar(find: model.find).padding(.top, EditorBar.topPadding).transition(arrive)
                } else if model.palette.isOpen {
                    CommandPalette(palette: model.palette, lineCount: model.lineCount,
                                   rowsThatFit: CommandPalette.rowsThatFit(in: panelSize.height), panelWidth: panelSize.width)
                        .padding(.top, EditorBar.topPadding).transition(arrive)
                }
            }
            .animation(motion.shape, value: model.find.isOpen)
            .animation(motion.shape, value: model.palette.isOpen)
            // The hint fades out; with reduced motion it is simply gone.
            .animation(motion.reduced ? nil : motion.quick, value: model.showsStartHint && !model.palette.isOpen)
            .animation(motion.reduced ? nil : motion.quick, value: whatsNew.shows(in: model))
    }

    // Changing the save format is an undoable edit of the document.
    private var encodingBinding: Binding<TextEncoding> {
        Binding(get: { document.encoding }, set: { document.setEncoding($0) })
    }

    private var lineEndingBinding: Binding<LineEnding> {
        Binding(get: { document.lineEnding }, set: { document.setLineEnding($0) })
    }

    private var bomBinding: Binding<Bool> {
        Binding(get: { document.hasBOM }, set: { document.setByteOrderMark($0) })
    }
}

/// The edge between the two sides of a split window: the 10 pt of canvas
/// between their panels, built as the sidebar's edge is (`SidebarEdge`).
/// Dragging it gives one side more of the row and the other less, each
/// keeping the editor's minimum; a double-click makes them half and half.
private struct SplitEdge: View {
    let tabs: WindowTabs
    /// The left panel's width now, and the row's.
    let leftWidth: Double
    let available: Double
    #if DEBUG || KIRI_SELFTEST
    /// -KiriSplitEdgeHover YES: the edge as under the pointer, for a picture.
    @State private var hovering = UserDefaults.standard.bool(forKey: "KiriSplitEdgeHover")
    #else
    @State private var hovering = false
    #endif
    /// The left panel's width when the drag began.
    @State private var dragStart: Double?
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let motion = HoneyMotion(appearance, systemReduced: reduce)
        Color.clear
            .frame(width: Honey.gap)
            .frame(maxHeight: .infinity)
            .overlay {
                Capsule().fill(Color.honeyMuted)
                    .frame(width: 4, height: 36)
                    .opacity(hovering || dragStart != nil ? 0.7 : 0)
                    .animation(motion.quick, value: hovering || dragStart != nil)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? leftWidth
                    dragStart = start
                    tabs.splitFraction = SplitLayout.dragged(from: start, by: drag.translation.width, available: available,
                                                             gap: Honey.gap)
                }
                .onEnded { _ in
                    dragStart = nil
                    tabs.window?.invalidateRestorableState()
                })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                withAnimation(motion.shape) { tabs.splitFraction = SplitLayout.defaultFraction }
                tabs.window?.invalidateRestorableState()
            })
            // VoiceOver and Voice Control: a slider of the left side's share.
            .accessibilityRepresentation {
                Slider(value: Binding(get: { SplitLayout.clamped(tabs.splitFraction, available: available, gap: Honey.gap) },
                                      set: { tabs.splitFraction = SplitLayout.clamped($0, available: available, gap: Honey.gap) }),
                       in: 0...1, step: SplitLayout.step) { Text("Left side's width") }
                    .accessibilityValue("\(Int((SplitLayout.clamped(tabs.splitFraction, available: available, gap: Honey.gap) * 100).rounded())) percent")
                    .accessibilityAction(named: "Half and Half") { tabs.splitFraction = SplitLayout.defaultFraction }
            }
    }
}

/// Where something dragged over the editors would go, while it is: that
/// side's half (or panel) under glass, with the focus color's outline.
private struct DropZone: View {
    let side: SplitLayout.Side
    let split: Bool
    let leftWidth: Double

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            let half = split ? (side == .left ? leftWidth : total - leftWidth - Honey.gap) : (total - Honey.gap) / 2
            let shape = RoundedRectangle(cornerRadius: Honey.Radius.panel.value, style: .continuous)
            shape.fill(Color.honeyAccentSoft.opacity(0.35))
                .honeyGlass(.chrome, in: shape)
                .overlay { shape.strokeBorder(Color.honeyFocus, lineWidth: 2) }
                .overlay {
                    Image(systemName: side == .left ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.honeyAccentInk)
                }
                .frame(width: max(half, 0), height: geometry.size.height)
                .offset(x: side == .left ? 0 : total - max(half, 0))
                .transition(.opacity)
                .accessibilityHidden(true)
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}
