import AppKit
import KiriKit
import SwiftUI

/// The first-run hint: what an empty untitled document shows in the middle
/// of its paper until something is typed, pasted or dropped into it. A few
/// quiet lines, each a button with the key that does the same: open a file,
/// open a folder, the command palette for everything else (every command
/// is in it, with its key), and the `kiri` command until it is installed.
///
/// Only the lines take clicks. Everything around them is the text view's,
/// which keeps the keyboard: the caret is on line 1 and typing starts the
/// document (and ends the hint; `EditorModel.showsStartHint`).
struct StartHint: View {
    let commandLineTool: CLIInstaller.Status
    /// Draws that line as hovered, for pictures.
    var hovered: Int?
    /// Opens this window's command palette.
    var openPalette: () -> Void = {}

    /// The hint is centred in the paper above the status capsule.
    static let bottomClearance = EditorStatusBar.bottomPadding + HoneyStatusMetrics.barHeight

    var body: some View {
        // In a panel too small for it, nothing: never cut-off lines.
        ViewThatFits {
            lines
            Color.clear.frame(width: 0, height: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lines: some View {
        VStack(spacing: 2) {
            StartHintLine("Open a file", shortcut: Keys.open, hovered: hovered == 0) {
                NSDocumentController.shared.openDocument(nil)
            }
            StartHintLine("Open a folder", shortcut: Keys.openFolder, hovered: hovered == 1) {
                FolderSessions.openFolderPanel()
            }
            StartHintLine("Everything else", shortcut: Keys.palette, hovered: hovered == 2, action: openPalette)
            // Until a terminal has the command (this copy's or another's).
            if commandLineTool == .missing {
                StartHintLine("Install the kiri command", shortcut: nil, link: true, hovered: hovered == 3) {
                    CLIInstaller.install()
                }
            }
        }
        .frame(width: 216)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Getting started")
    }
}

/// One line of the hint: muted words and the key caps of the Keyboard
/// Shortcuts window, or without a key the words as a link. (What's new
/// has lines of the same kind: `WhatsNewNotice`.)
struct StartHintLine: View {
    let title: String
    let shortcut: KeyboardShortcut?
    /// A link to a page or a setup step, not a command: no key, the accent's ink.
    let link: Bool
    let hovered: Bool
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, shortcut: KeyboardShortcut?, link: Bool = false, hovered: Bool, action: @escaping () -> Void) {
        self.link = link
        self.title = title
        self.shortcut = shortcut
        self.hovered = hovered
        self.action = action
    }

    var body: some View {
        let active = hovering || hovered
        let shape = RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.honey(.subheadline, weight: .semibold))
                    .foregroundStyle(link ? Color.honeyAccentInk : active ? Color.honeyFg : Color.honeyMuted)
                    .underline(link && active)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
                if let shortcut { KeyCaps(shortcut.glyphs) }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(active ? Color.honeySurface2 : .clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(StartHintLineStyle())
        .focused($focused)
        .focusEffectDisabled()
        .overlay { shape.strokeBorder(Color.honeyFocus, lineWidth: focused ? 2 : 0).allowsHitTesting(false) }
        .onHover { hovering = $0 }
        .animation(HoneyMotion(appearance, systemReduced: reduceMotion).quick, value: active)
        // "Open a file, Command O, button"
        .accessibilityLabel(shortcut.map { "\(title), \($0.spoken)" } ?? title)
    }
}

/// A line draws its own hover; pressing dims it.
private struct StartHintLineStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A hint line that is a checkbox: the words, and at the right, where a
/// line's key caps would be, a box in the key caps' look that is ticked
/// in the accent while it is on.
struct StartHintCheckLine: View {
    let title: String
    let isOn: Bool
    let hovered: Bool
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.honeyAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, isOn: Bool, hovered: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.hovered = hovered
        self.action = action
    }

    var body: some View {
        let active = hovering || hovered
        let shape = RoundedRectangle(cornerRadius: Honey.Radius.small.value, style: .continuous)
        let box = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.honey(.subheadline, weight: .semibold))
                    .foregroundStyle(active ? Color.honeyFg : Color.honeyMuted)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.honeyAccentFg)
                    .opacity(isOn ? 1 : 0)
                    .frame(width: 22, height: 22)
                    .background(isOn ? Color.honeyAccent : Color.honeySurface2, in: box)
                    .overlay { box.strokeBorder(isOn ? Color.clear : Color.honeyLine, lineWidth: 1) }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(active ? Color.honeySurface2 : .clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(StartHintLineStyle())
        .focused($focused)
        .focusEffectDisabled()
        .overlay { shape.strokeBorder(Color.honeyFocus, lineWidth: focused ? 2 : 0).allowsHitTesting(false) }
        .onHover { hovering = $0 }
        .animation(HoneyMotion(appearance, systemReduced: reduceMotion).quick, value: active)
        .animation(HoneyMotion(appearance, systemReduced: reduceMotion).quick, value: isOn)
        .accessibilityRepresentation {
            Toggle(title, isOn: Binding(get: { isOn }, set: { _ in action() }))
        }
    }
}
