import Foundation

/// What the preview does with pictures and media a file loads from the
/// internet or from outside its own folder (Settings ▸ Privacy). Such a
/// load tells a server that the file was opened, and when, or reads a
/// file the document's author picked, so by default none of it loads
/// until the person says so.
public enum PreviewExternalContent: String, CaseIterable, Sendable {
    /// Held back, with a notice over the preview to accept or deny it.
    case ask
    /// Never loaded, and no notice.
    case deny
    /// Loaded as the file says.
    case allow

    /// The saved setting: `ask` when nothing, or nothing known, is saved.
    public init(saved: String?) { self = saved.flatMap(Self.init(rawValue:)) ?? .ask }

    /// Whether it loads, given the person's answer for this document (nil:
    /// not answered).
    public func loads(answer: Bool?) -> Bool {
        switch self {
        case .ask: answer == true
        case .deny: false
        case .allow: true
        }
    }

    /// Whether a document that holds something back shows the notice.
    public func asks(answer: Bool?) -> Bool { self == .ask && answer == nil }
}

/// What a preview holds back.
public struct PreviewHeldBack: Equatable, Sendable {
    /// Pictures or media from the internet (`http:`, `https:`).
    public var remote: Bool
    /// Files outside the document's folder.
    public var outside: Bool

    public init(remote: Bool = false, outside: Bool = false) {
        self.remote = remote
        self.outside = outside
    }

    public var isEmpty: Bool { !remote && !outside }

    /// What the notice says.
    public var notice: String {
        switch (remote, outside) {
        case (true, true): "This document loads pictures or media from the internet and from outside its folder."
        case (true, false): "This document loads pictures or media from the internet."
        default: "This document loads pictures from outside its folder."
        }
    }
}

/// Where a link clicked in the preview goes.
public enum PreviewLink: Equatable, Sendable {
    /// A web page or an address to write to: the browser or the mail app,
    /// as a link anywhere does.
    case web
    /// A file on this Mac: text opens in Kiri, anything else only after
    /// the person agrees.
    case file(URL)
    /// Another app's own kind of link (`x-apple.systempreferences:`,
    /// `zoommtg:`…): only after the person agrees.
    case app(scheme: String)

    public init(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == MarkdownPage.scheme, let file = MarkdownPage.fileURL(for: url) {
            self = .file(file)
        } else if url.isFileURL {
            self = .file(url.standardizedFileURL)
        } else if ["http", "https", "mailto"].contains(scheme) {
            self = .web
        } else {
            self = .app(scheme: scheme)
        }
    }
}
