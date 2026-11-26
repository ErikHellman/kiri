/// What Help ▸ Command Line Tool says about the `kiri` command: its usage,
/// examples (piping among them) and options. The script's own `kiri --help`
/// (App/CLI/kiri) says the same in fewer words; `CommandLineHelpTests`
/// checks that the two name the same options.
public enum CommandLineHelp {
    /// A command to type, and what it does.
    public struct Example: Hashable, Sendable, Identifiable {
        public let command: String
        public let explanation: String
        public var id: String { command }

        public init(_ command: String, _ explanation: String) {
            self.command = command
            self.explanation = explanation
        }
    }

    /// A group of examples under a title, with a line about them.
    public struct Section: Hashable, Sendable, Identifiable {
        public let title: String
        /// An SF Symbol's name.
        public let systemImage: String
        public let intro: String?
        public let examples: [Example]
        public var id: String { title }
    }

    /// An option and its other spellings ("-n", "--new-window").
    public struct Option: Hashable, Sendable, Identifiable {
        public let flags: [String]
        public let explanation: String
        public var id: String { flags.joined(separator: " ") }
    }

    public static let usage = "kiri [options] [path[:line[:column]] ...]"

    /// What the command does with no arguments and with a running Kiri.
    public static let summary = "Opens files and folders in Kiri. A running Kiri is reused, so files open at once, "
        + "as tabs in the front window. With no paths, kiri opens Kiri or brings it to the front."

    public static let sections: [Section] = [
        Section(title: "Open files and folders", systemImage: "doc.on.doc", intro: nil, examples: [
            Example("kiri notes.md todo.txt", "Opens the files as tabs in the front window."),
            Example("kiri src/main.swift:42:5", "Opens the file at line 42, column 5. Just :42 goes to the line."),
            Example("kiri ~/project", "Opens the folder in a new window, with its files in a sidebar."),
            Example("kiri new.md", "A file that doesn't exist yet opens empty; saving creates it."),
            Example("kiri -n file.txt", "Opens the file in a new window instead of the front one."),
        ]),
        Section(title: "Pipe into Kiri", systemImage: "arrow.right.to.line",
                intro: "A - reads standard input. Output that ends within a second opens in a new untitled tab, "
                    + "to edit and save. Output that goes on is followed live in the read-only large-file viewer, "
                    + "with search, until the command ends or you press Ctrl+C.",
                examples: [
                    Example("git diff | kiri -", "The diff in a new untitled tab."),
                    Example("pbpaste | kiri -", "The clipboard's text in a new tab."),
                    Example("curl -s https://api.github.com/zen | kiri -", "A download, without saving it first."),
                    Example("adb logcat | kiri -", "An Android device's log, followed live."),
                    Example("tail -f /var/log/system.log | kiri -", "A log as it is written, followed live."),
                ]),
        Section(title: "Use Kiri as your editor", systemImage: "pencil.and.outline",
                intro: "With -w the command waits until the tab is closed, as git and other tools expect of an editor. "
                    + "Save before closing; closing asks if you haven't.",
                examples: [
                    Example("export EDITOR=\"kiri -w\"", "For your shell's startup file (~/.zshrc)."),
                    Example("git config --global core.editor \"kiri -w\"", "Commit messages and rebases in Kiri."),
                    Example("kiri -w file.txt", "Waits until the tab is closed."),
                ]),
    ]

    public static let options: [Option] = [
        Option(flags: ["-n", "--new-window"], explanation: "Open in a new window instead of the front one."),
        Option(flags: ["-w", "--wait"], explanation: "Wait until the opened tabs are closed (for EDITOR and git)."),
        Option(flags: ["-"], explanation: "Read standard input into a new tab, or follow it live."),
        Option(flags: ["--"], explanation: "Treat everything after it as a path, even names that start with -."),
        Option(flags: ["-h", "--help"], explanation: "Show the command's help in the terminal."),
        Option(flags: ["-v", "--version"], explanation: "Show Kiri's version."),
    ]
}
