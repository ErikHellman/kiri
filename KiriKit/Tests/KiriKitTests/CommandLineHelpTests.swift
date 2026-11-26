import Foundation
import Testing
@testable import KiriKit

@Suite struct CommandLineHelpTests {
    /// The `kiri` script's `usage()` text (App/CLI/kiri).
    private func scriptUsage() throws -> String {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("App/CLI/kiri")
        let text = try String(contentsOf: script, encoding: .utf8)
        let start = try #require(text.range(of: "cat <<'EOF'\n"))
        let end = try #require(text.range(of: "\nEOF\n", range: start.upperBound..<text.endIndex))
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// The options of the script's help: the first word (and a second
    /// spelling after a comma) of each line that starts with two spaces
    /// and a dash.
    private func scriptOptions(_ usage: String) -> Set<String> {
        var flags: Set<String> = []
        for line in usage.split(separator: "\n") where line.hasPrefix("  -") {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = words.first else { continue }
            flags.insert(String(first.trimmingCharacters(in: CharacterSet(charactersIn: ","))))
            if first.hasSuffix(","), words.count > 1 { flags.insert(String(words[1])) }
        }
        return flags
    }

    @Test func theHelpWindowAndTheScriptNameTheSameOptions() throws {
        let usage = try scriptUsage()
        let inScript = scriptOptions(usage)
        // `kiri -` is an example in the script's help, not an option line.
        let inHelp = Set(CommandLineHelp.options.flatMap(\.flags)).subtracting(["-"])
        #expect(inScript == inHelp)
        #expect(usage.contains("Usage: " + CommandLineHelp.usage))
    }

    @Test func everyExampleRunsTheKiriCommand() {
        let examples = CommandLineHelp.sections.flatMap(\.examples)
        #expect(!examples.isEmpty)
        for example in examples {
            #expect(example.command.hasPrefix("kiri ") || example.command.contains("| kiri -")
                    || example.command.contains("kiri -w"), "\(example.command)")
            #expect(!example.explanation.isEmpty)
        }
        // Piping is shown, both ways it goes.
        #expect(examples.contains { $0.command == "git diff | kiri -" })
        #expect(examples.contains { $0.command == "adb logcat | kiri -" })
        #expect(Set(examples.map(\.id)).count == examples.count)
    }
}
