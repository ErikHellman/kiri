import Foundation
import KiriKit

/// The Markdown preview's web page. The app loads `shell` once into its
/// web view, then puts each rendering in with the page script's `update`
/// (`preview.js`), so scrolling, and Mermaid once it has loaded, stay.
///
/// The page runs none of the file's scripts: the web view has page
/// JavaScript off, and the Content Security Policy below lets nothing load
/// but images (from the file's folder, through the app) and the app's own
/// fonts; images and media from the web only once the person has let them
/// (`PreviewExternalContent`). Kiri's scripts run in a world of their own.
public enum MarkdownPage {
    /// The URL scheme the app serves the page's files under:
    /// `kiri-preview://file/<path>` for files next to the document,
    /// `kiri-preview://app/fonts/<name>` for Nunito.
    public static let scheme = "kiri-preview"

    /// How the page looks: the theme's colors, and the editor's text size
    /// and font.
    public struct Style: Equatable, Sendable {
        public var theme: Honey.Theme
        public var dark: Bool
        public var highContrast: Bool
        /// The editor's text size, 1 = 100%.
        public var textScale: Double
        /// The editor's font family, "" for SF Mono.
        public var codeFont: String

        public init(theme: Honey.Theme = .honey, dark: Bool = false, highContrast: Bool = false, textScale: Double = 1,
                    codeFont: String = "") {
            self.theme = theme
            self.dark = dark
            self.highContrast = highContrast
            self.textScale = textScale
            self.codeFont = codeFont
        }

        /// The CSS that sets the page's colors (`--fg`, `--syn-keyword`…)
        /// and sizes.
        public var css: String {
            var out = ":root {\n  color-scheme: \(dark ? "dark" : "light");\n"
            for (name, token) in Honey.allTokens {
                out += "  --\(name): \(Self.hex(theme[token].value(dark: dark, highContrast: highContrast)));\n"
            }
            let family = codeFont.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "")
            out += "  --mono: \(family.isEmpty ? "" : "\"\(family)\", ")ui-monospace, \"SF Mono\", Menlo, monospace;\n"
            out += "  --scale: \(textScale);\n}\n"
            return out
        }

        static func hex(_ rgb: UInt32) -> String { "#" + String(format: "%06X", rgb & 0xFFFFFF) }
    }

    /// The URL the page is loaded at, for a document in `folder` (nil when
    /// it has no file yet): images with relative paths resolve against it.
    public static func baseURL(folder: URL?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.path = folderPrefix(folder) ?? "/"
        // swiftlint:disable:next force_unwrapping - the scheme and host make a URL
        return components.url ?? URL(string: "\(scheme)://file/")!
    }

    /// What the path of every file in `folder` starts with (nil without a
    /// folder): the page script tells files outside it by this.
    public static func folderPrefix(_ folder: URL?) -> String? {
        guard var path = folder?.standardizedFileURL.path else { return nil }
        if !path.hasSuffix("/") { path += "/" }
        return path
    }

    /// Whether `file` is in `folder` or a folder under it, where both
    /// really are (a link in the folder to a file elsewhere is outside).
    /// Nothing is inside a document that has no folder yet.
    public static func isInside(_ file: URL, folder: URL?) -> Bool {
        guard let folder else { return false }
        let parts = { (url: URL) in url.resolvingSymlinksInPath().standardizedFileURL.path.split(separator: "/") }
        let inner = parts(file), outer = parts(folder)
        return inner.count > outer.count && inner.prefix(outer.count).elementsEqual(outer)
    }

    /// The file a `kiri-preview://file/…` URL stands for.
    public static func fileURL(for url: URL) -> URL? {
        guard url.scheme == scheme, url.host == "file" else { return nil }
        let path = url.path
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// What the page may load: images through the app (`PreviewFiles`
    /// keeps those to the document's folder) and inline, the app's fonts,
    /// and with `allowsRemote` images and media from the web. Nothing
    /// else, and never a script.
    public static func contentSecurityPolicy(allowsRemote: Bool) -> String {
        let web = allowsRemote ? " https: http:" : ""
        return "default-src 'none'; img-src \(scheme):\(web) data:; media-src \(scheme):\(web); "
            + "style-src 'unsafe-inline'; font-src \(scheme):"
    }

    /// The page, without its content: `update` puts that in. The policy is
    /// the page's for as long as it is loaded, so letting the web in (or
    /// out again) means loading the page again.
    public static func shell(style: Style, allowsRemote: Bool = false) -> String {
        let csp = contentSecurityPolicy(allowsRemote: allowsRemote)
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style id="kiri-fonts">\(fontFaces)</style>
        <style id="kiri-style">\(style.css)</style>
        <style>\(stylesheet)</style>
        </head>
        <body>
        <main class="page" id="kiri-page"></main>
        </body>
        </html>
        """
    }

    static var fontFaces: String {
        [(400, "400"), (600, "600"), (700, "700"), (800, "800")].map { weight, file in
            "@font-face { font-family: \"Nunito\"; font-weight: \(weight); font-style: normal; "
                + "src: url(\"\(scheme)://app/fonts/Nunito-\(file).ttf\") format(\"truetype\"); }"
        }.joined(separator: "\n")
    }

    // MARK: SVG

    /// What the page shows for an SVG file's `text`: the picture, drawn by
    /// WebKit as an image. As an image it runs none of the file's scripts
    /// and loads nothing it points to, whatever the file says. It fits
    /// the page, and a small one (an icon) shows larger: an SVG is sharp
    /// at any size.
    public static func svgHTML(_ text: String) -> String {
        let data = Data(text.utf8).base64EncodedString()
        return "<figure class=\"svg-view\" data-line=\"1\"><img src=\"data:image/svg+xml;base64,\(data)\" alt=\"\"></figure>"
    }

    // MARK: The page's files

    /// The stylesheet (`Web/preview.css`).
    public static let stylesheet: String = resource("preview", "css") ?? ""
    /// The page script (`Web/preview.js`), run in the app's own world.
    public static let script: String = resource("preview", "js") ?? ""
    /// Mermaid (`Web/mermaid.min.js`, MIT): only read when a file has a
    /// diagram, and then once.
    public static var mermaidURL: URL? { Bundle.module.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Web") }

    private static func resource(_ name: String, _ ext: String) -> String? {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Web") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
