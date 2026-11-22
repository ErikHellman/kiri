import Foundation

/// A language or file format Kiri knows: its status-bar name and how to
/// recognise it from a file name or the first line.
public struct Language: Hashable, Sendable, Identifiable {
    /// Stable id, also the tree-sitter grammar key (e.g. "swift", "json").
    public let id: String
    public let name: String
    public let extensions: Set<String>
    public let fileNames: Set<String>
    /// Interpreters named in a `#!` line.
    public let interpreters: Set<String>
    /// Line comment prefix, used by the fallback highlighter.
    public let lineComment: String?
    /// How Toggle Comment (⌘/) comments a line out, or nil for a format
    /// that has no comments (plain text, JSON, CSV).
    public let comment: CommentSyntax?

    /// - Parameters:
    ///   - blockComment: for a language that only has block comments, the
    ///     pair Toggle Comment puts around each line.
    ///   - togglesComments: false for a format whose `lineComment` is only
    ///     there for the highlighter.
    public init(id: String, name: String, extensions: Set<String> = [], fileNames: Set<String> = [],
                interpreters: Set<String> = [], lineComment: String? = nil,
                blockComment: (open: String, close: String)? = nil, togglesComments: Bool = true) {
        self.id = id
        self.name = name
        self.extensions = extensions
        self.fileNames = fileNames
        self.interpreters = interpreters
        self.lineComment = lineComment
        comment = blockComment.map { .block(open: $0.open, close: $0.close) }
            ?? (togglesComments ? lineComment.map { .line($0) } : nil)
    }

    public static let plainText = Language(id: "text", name: "Plain Text", extensions: ["txt", "text", "log"])
    public static let swift = Language(id: "swift", name: "Swift", extensions: ["swift", "swiftinterface"], lineComment: "//")
    // JSON has no comments. (The `//` is for the highlighter, which meets
    // them in .jsonc and .json5 files.)
    public static let json = Language(id: "json", name: "JSON",
                                      extensions: ["json", "jsonc", "json5", "geojson", "webmanifest", "jsonl"],
                                      fileNames: [".prettierrc", ".eslintrc", ".babelrc"], lineComment: "//",
                                      togglesComments: false)
    public static let yaml = Language(id: "yaml", name: "YAML", extensions: ["yaml", "yml"],
                                      fileNames: [".clang-format", ".clang-tidy"], lineComment: "#")
    public static let markdown = Language(id: "markdown", name: "Markdown",
                                          extensions: ["md", "markdown", "mdown", "mkd", "mdx"],
                                          blockComment: ("<!--", "-->"))
    public static let javascript = Language(id: "javascript", name: "JavaScript",
                                            extensions: ["js", "mjs", "cjs", "jsx"], interpreters: ["node"],
                                            lineComment: "//")
    public static let typescript = Language(id: "typescript", name: "TypeScript", extensions: ["ts", "mts", "cts"],
                                            interpreters: ["deno", "ts-node", "bun"], lineComment: "//")
    public static let tsx = Language(id: "tsx", name: "TSX", extensions: ["tsx"], lineComment: "//")
    public static let python = Language(id: "python", name: "Python", extensions: ["py", "pyw", "pyi"],
                                        fileNames: ["SConstruct", "SConscript"],
                                        interpreters: ["python", "python3", "python2"], lineComment: "#")
    public static let shell = Language(id: "bash", name: "Shell", extensions: ["sh", "bash", "zsh", "ksh", "command"],
                                       fileNames: [".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".profile",
                                                   ".zshenv", "PKGBUILD"],
                                       interpreters: ["sh", "bash", "zsh", "ksh", "dash"], lineComment: "#")
    public static let html = Language(id: "html", name: "HTML", extensions: ["html", "htm", "xhtml"],
                                      blockComment: ("<!--", "-->"))
    public static let css = Language(id: "css", name: "CSS", extensions: ["css"], blockComment: ("/*", "*/"))
    // Formats without a bundled grammar use the fallback highlighter.
    public static let toml = Language(id: "toml", name: "TOML", extensions: ["toml"],
                                      fileNames: ["Cargo.lock", "Pipfile"], lineComment: "#")
    public static let xml = Language(id: "xml", name: "XML",
                                     extensions: ["xml", "plist", "svg", "xsd", "xsl", "xslt", "storyboard", "xib",
                                                  "entitlements", "csproj"],
                                     blockComment: ("<!--", "-->"))
    public static let csv = Language(id: "csv", name: "CSV", extensions: ["csv", "tsv"])
    public static let ini = Language(id: "ini", name: "INI", extensions: ["ini", "cfg", "conf", "properties", "env"],
                                     fileNames: [".env", ".gitconfig", ".editorconfig", ".npmrc"], lineComment: "#")
    public static let makefile = Language(id: "make", name: "Makefile", extensions: ["mk", "mak"],
                                          fileNames: ["Makefile", "makefile", "GNUmakefile"], lineComment: "#")
    public static let dockerfile = Language(id: "dockerfile", name: "Dockerfile", extensions: ["dockerfile"],
                                            fileNames: ["Dockerfile", "Containerfile"], lineComment: "#")
    public static let ruby = Language(id: "ruby", name: "Ruby", extensions: ["rb", "rake", "gemspec"],
                                      fileNames: ["Gemfile", "Rakefile", "Podfile", "Fastfile"],
                                      interpreters: ["ruby"], lineComment: "#")
    // Tree-sitter grammars (KiriSyntax), added with the C family and JVM languages.
    public static let go = Language(id: "go", name: "Go", extensions: ["go"], lineComment: "//")
    public static let rust = Language(id: "rust", name: "Rust", extensions: ["rs"], interpreters: ["rust-script"],
                                      lineComment: "//")
    public static let java = Language(id: "java", name: "Java", extensions: ["java", "jav"], lineComment: "//")
    public static let kotlin = Language(id: "kotlin", name: "Kotlin", extensions: ["kt", "kts"],
                                        interpreters: ["kotlin", "kscript"], lineComment: "//")
    public static let csharp = Language(id: "csharp", name: "C#", extensions: ["cs", "csx"], lineComment: "//")
    public static let c = Language(id: "c", name: "C", extensions: ["c", "h"], lineComment: "//")
    public static let cpp = Language(id: "cpp", name: "C++",
                                     extensions: ["cc", "cpp", "cxx", "c++", "hpp", "hh", "hxx", "h++", "ipp", "tpp",
                                                  "inl", "ixx", "cppm"],
                                     lineComment: "//")
    public static let zig = Language(id: "zig", name: "Zig", extensions: ["zig", "zon"], lineComment: "//")
    // No grammar: the fallback highlighter.
    public static let objectiveC = Language(id: "objc", name: "Objective-C", extensions: ["m", "mm"],
                                            lineComment: "//")
    public static let gradle = Language(id: "gradle", name: "Gradle", extensions: ["gradle"], lineComment: "//")
    public static let sql = Language(id: "sql", name: "SQL", extensions: ["sql"], lineComment: "--")

    /// Every known language, in menu order.
    public static let all: [Language] = [
        plainText, markdown, json, yaml, toml, xml, csv, ini, swift, javascript, typescript, tsx, python, shell,
        html, css, ruby, go, rust, java, kotlin, csharp, c, cpp, objectiveC, zig, gradle, sql, makefile, dockerfile,
    ]

    public static func with(id: String) -> Language? { all.first { $0.id == id } }

    /// The language for a file, from its name, then a `#!` line; plain text otherwise.
    public static func detect(fileName: String?, firstLine: String? = nil) -> Language {
        if let fileName, !fileName.isEmpty {
            if let l = all.first(where: { $0.fileNames.contains(fileName) }) { return l }
            let ext = (fileName as NSString).pathExtension.lowercased()
            if !ext.isEmpty, let l = all.first(where: { $0.extensions.contains(ext) }) { return l }
            // `.env.local`, `Dockerfile.dev`
            if fileName.hasPrefix(".env") { return ini }
            if fileName.hasPrefix("Dockerfile") { return dockerfile }
        }
        if let firstLine, let l = fromShebang(firstLine) { return l }
        return plainText
    }

    /// The language a `#!` line names, as in `#!/usr/bin/env python3`.
    static func fromShebang(_ line: String) -> Language? {
        guard line.hasPrefix("#!") else { return nil }
        let words = line.dropFirst(2).split(separator: " ").map(String.init)
        guard var program = words.first.map({ ($0 as NSString).lastPathComponent }) else { return nil }
        if program == "env" {
            guard let next = words.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
            program = next
        }
        return all.first { $0.interpreters.contains(program) }
            ?? all.first { l in l.interpreters.contains { program.hasPrefix($0) } }
    }
}
