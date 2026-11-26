import AppKit
import Observation

/// Install Command Line Tool… (the app menu, Settings and the first-run
/// hint): links /usr/local/bin/kiri to the script inside the app bundle,
/// asking for an administrator password when /usr/local/bin isn't writable.
@MainActor enum CLIInstaller {
    static let linkPath = "/usr/local/bin/kiri"

    /// Whether a terminal has the `kiri` command.
    enum Status: Equatable {
        /// Nothing at `linkPath`, or a link to something that is gone.
        case missing
        /// `linkPath` links to this copy of Kiri's script.
        case installed
        /// Something else is there, at this path once links are followed:
        /// as a rule another copy of Kiri's script (a build, an older install).
        case other(String)
    }

    private static var script: String? { Bundle.main.url(forResource: "kiri", withExtension: nil)?.path }

    /// What is at `link`, for a copy of Kiri whose script is at `script`.
    nonisolated static func status(link: String, script: String?) -> Status {
        let fm = FileManager.default
        if let script, (try? fm.destinationOfSymbolicLink(atPath: link)) == script, fm.fileExists(atPath: script) {
            return .installed
        }
        // `fileExists` follows links: a link to a deleted app is no command.
        guard fm.fileExists(atPath: link) else { return .missing }
        return .other(URL(fileURLWithPath: link).resolvingSymlinksInPath().path)
    }

    static var status: Status { status(link: linkPath, script: script) }

    static func install() {
        defer { CommandLineTool.shared.refresh() }
        guard let script else {
            alert("The kiri command isn't in this copy of Kiri.", info: "Rebuild Kiri with scripts/build.sh.", style: .warning)
            return
        }
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: linkPath)) == script {
            alert("The kiri command is already installed.", info: usage)
            return
        }
        do {
            try fm.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
            if (try? fm.attributesOfItem(atPath: linkPath)) != nil { try fm.removeItem(atPath: linkPath) }
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: script)
        } catch {
            guard installAsAdmin(script) else {
                alert("Couldn't install the kiri command.",
                      info: "Link it yourself:\nsudo ln -sf \"\(script)\" \(linkPath)", style: .warning)
                return
            }
        }
        alert("The kiri command is installed.", info: usage)
    }

    private static var usage: String {
        "Open a terminal and run kiri --help. Try kiri file.txt, kiri file.txt:12, kiri ~/project or git diff | kiri -.\n\n"
            + "To use Kiri as git's editor: git config --global core.editor \"kiri -w\"\n\n"
            + "Help ▸ Command Line Tool lists every option, with examples."
    }

    /// `osascript … with administrator privileges` shows the system's
    /// password prompt.
    private static func installAsAdmin(_ script: String) -> Bool {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let command = "mkdir -p /usr/local/bin && ln -sf \" & quoted form of \(quoted(script)) & \" \(linkPath)"
        let source = "do shell script \"\(command)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func alert(_ message: String, info: String, style: NSAlert.Style = .informational) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.alertStyle = style
        a.runModal()
    }
}

/// Whether the `kiri` command is installed, for Settings and the first-run
/// hint. Looked up when Kiri starts, when it comes to the front (the link
/// may have been made or removed in a terminal) and after an install.
@MainActor @Observable final class CommandLineTool {
    static let shared = CommandLineTool()

    private(set) var status: CLIInstaller.Status

    private init() {
        status = Self.current
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CommandLineTool.shared.refresh() }
        }
    }

    func refresh() {
        let now = Self.current
        if now != status { status = now }
    }

    private static var current: CLIInstaller.Status {
        #if DEBUG || KIRI_SELFTEST
        // -KiriCommandLineTool missing|installed|other shows that state,
        // whatever this Mac has.
        switch UserDefaults.standard.string(forKey: "KiriCommandLineTool") {
        case "missing": return .missing
        case "installed": return .installed
        case "other": return .other("/Applications/Kiri.app/Contents/Resources/kiri")
        default: break
        }
        #endif
        return CLIInstaller.status
    }
}
