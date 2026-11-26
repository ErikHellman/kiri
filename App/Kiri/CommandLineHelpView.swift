import AppKit
import KiriKit
import SwiftUI

/// Help ▸ Command Line Tool: how to use the `kiri` command, with its
/// options and examples (`CommandLineHelp`), piping among them. Each
/// example has a Copy button; the header says whether the command is
/// installed and offers Install… when it isn't. Escape closes it.
struct CommandLineHelpView: View {
    static let windowID = "command-line-tool"

    private static let margin: CGFloat = 20
    /// Wide enough for a card's shadow to fade out before the next card.
    private static let cardGap: CGFloat = 20

    @State private var commandLineTool = CommandLineTool.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Command Line Tool").font(.honey(.largeTitle, weight: .heavy))
                    Text("Open files, folders and the output of other commands in Kiri from a terminal.")
                        .font(.honey(.subheadline)).foregroundStyle(Color.honeyMuted)
                }
                Spacer(minLength: 16)
                installState
            }
            .padding(.top, 34) // clear of the traffic lights
            .padding(.horizontal, Self.margin)

            // The scroll view runs to the window's edges and the margins are
            // inside it, so it doesn't cut the cards' shadows off.
            ScrollView {
                VStack(alignment: .leading, spacing: Self.cardGap) {
                    usageCard
                    ForEach(CommandLineHelp.sections) { SectionCard(section: $0) }
                    optionsCard
                }
                .padding(.horizontal, Self.margin)
                .padding(.top, 14)
                .padding(.bottom, Self.margin + Honey.gap)
            }
            .scrollIndicators(.automatic)
        }
        .frame(minWidth: 620, minHeight: 480)
        .onAppear { Telemetry.screen("Command Line Tool") }
        .honeyCanvas()
        .ignoresSafeArea(.container, edges: .top)
        .escapeCloses { dismiss() }
    }

    /// Installed, or a button that installs it.
    @ViewBuilder private var installState: some View {
        if commandLineTool.status == .installed {
            Label("Installed", systemImage: "checkmark")
                .font(.honey(.subheadline, weight: .semibold)).foregroundStyle(Color.honeyMuted)
                .help("The kiri command is at \(CLIInstaller.linkPath).")
        } else {
            Button("Install…") { CLIInstaller.install() }.buttonStyle(.honeyGlass)
                .accessibilityLabel("Install Command Line Tool")
                .help("Links \(CLIInstaller.linkPath) to this copy of Kiri.")
        }
    }

    private var usageCard: some View {
        Card(title: "Usage", systemImage: "terminal") {
            Command(text: CommandLineHelp.usage)
            Text(CommandLineHelp.summary).font(.honey(.body)).foregroundStyle(Color.honeyMuted)
                .fixedSize(horizontal: false, vertical: true)
            if commandLineTool.status != .installed {
                Text("Install it once with the button above or Kiri ▸ Install Command Line Tool…; it links \(CLIInstaller.linkPath) to the script inside Kiri.")
                    .font(.honey(.caption)).foregroundStyle(Color.honeyMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var optionsCard: some View {
        Card(title: "Options", systemImage: "slider.horizontal.3") {
            ForEach(CommandLineHelp.options) { option in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(option.flags.joined(separator: ", "))
                        .font(.honeyMono(size: 13, weight: .semibold))
                        .foregroundStyle(Color.honeyFg)
                        .frame(width: 150, alignment: .leading)
                    Text(option.explanation).font(.honey(.body))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
            Text("kiri --help in a terminal shows these too.")
                .font(.honey(.caption)).foregroundStyle(Color.honeyMuted)
        }
    }
}

/// A Honey card with a section label, as in Keyboard Shortcuts.
private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                HoneySectionLabel(title)
            } icon: {
                Image(systemName: systemImage).font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.honeyAccentInk)
            }
            .padding(.bottom, 2)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .honeyPanel(radius: .card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct SectionCard: View {
    let section: CommandLineHelp.Section

    var body: some View {
        Card(title: section.title, systemImage: section.systemImage) {
            if let intro = section.intro {
                Text(intro).font(.honey(.body)).foregroundStyle(Color.honeyMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
            }
            ForEach(section.examples) { example in
                VStack(alignment: .leading, spacing: 4) {
                    Command(text: example.command)
                    Text(example.explanation).font(.honey(.subheadline)).foregroundStyle(Color.honeyMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 2)
                }
            }
        }
    }
}

/// A command in the editor's monospaced face on a sunken strip, selectable,
/// with a button that copies it.
private struct Command: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.honeyMono(size: 13))
                .foregroundStyle(Color.honeyFg)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copied ? Color.honeyAccentInk : Color.honeyMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")
            .accessibilityLabel(copied ? "Copied" : "Copy \(text)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(Color.honeySurface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.honeyLine, lineWidth: 1)
        }
    }
}
