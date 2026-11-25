import Foundation

// What's new: the release notes Kiri shows once after an update, and which
// versions' notes to show. Plain Foundation so it tests on Linux.
//
// The notes are the repo's `docs/release-notes/<version>.md`, the same files
// the release workflow turns into the GitHub release and Sparkle's update
// window, bundled into the app. Their Markdown is small on purpose:
// paragraphs, "- " lists, `code`, **bold** and [links](url).

/// One version's notes.
public struct ReleaseNotes: Equatable, Sendable, Identifiable {
    public let version: String
    public let blocks: [Block]

    public var id: String { version }

    /// A paragraph, or a list item. The text keeps its inline Markdown
    /// (`code`, **bold**, links) for the view to draw.
    public enum Block: Equatable, Sendable {
        case paragraph(String)
        case item(String)
    }

    public init(version: String, blocks: [Block]) {
        self.version = version
        self.blocks = blocks
    }

    /// Reads a notes file. Lines that start with "- " or "* " start a list
    /// item, the lines under one carry it on, a blank line ends it; other
    /// lines make paragraphs. Headings are dropped: the view has its own.
    public init(version: String, markdown: String) {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var item: [String] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            if !item.isEmpty { blocks.append(.item(item.joined(separator: " "))) }
            paragraph = []
            item = []
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                item = [String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)]
            } else if line.hasPrefix("#") {
                flush()
            } else if !item.isEmpty {
                item.append(line)
            } else {
                paragraph.append(line)
            }
        }
        flush()
        self.init(version: version, blocks: blocks)
    }

    /// Nothing to say (an empty file, or one with only a heading).
    public var isEmpty: Bool { blocks.isEmpty }
}

/// Version numbers as Kiri's tags have them, "0.3.2": compared number by
/// number, so 0.10.0 comes after 0.9.0. Whatever follows a number
/// ("1-beta") is ignored.
public struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]
    public let description: String

    /// Nil for something that isn't a version ("README", "").
    public init?(_ text: String) {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        var parts: [Int] = []
        for piece in pieces {
            guard let n = Int(piece.prefix { $0.isNumber }) else { return nil }
            parts.append(n)
        }
        guard !parts.isEmpty else { return nil }
        self.parts = parts
        description = text
    }

    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: ReleaseVersion, b: ReleaseVersion) -> Bool { !(a < b) && !(b < a) }
}

/// Which versions' notes a launch shows.
public enum WhatsNewPlan {
    /// At most this many versions at once, newest first: someone who
    /// skipped a few updates gets the recent ones, not a history.
    public static let mostVersions = 3

    /// The versions whose notes to show, newest first, out of `available`
    /// (the bundled notes files): those after `lastSeen` up to and
    /// including `current`.
    ///
    /// - `lastSeen`: the version whose notes were last shown, or that last
    ///   launched with nothing to show. Nil before this feature existed.
    /// - `ranBefore`: an earlier Kiri ran on this Mac (it left settings
    ///   behind). With no `lastSeen` that tells an update from a fresh
    ///   install: a new install shows nothing (the first-run hint is for
    ///   that), an update from a version before What's new shows `current`.
    public static func versions(current: String, lastSeen: String?, ranBefore: Bool,
                                available: [String]) -> [String] {
        guard let now = ReleaseVersion(current) else { return [] }
        let after: ReleaseVersion?
        if let lastSeen {
            // An unreadable value is as none: this version's notes only.
            after = ReleaseVersion(lastSeen)
            if let after, after >= now { return [] }
        } else {
            guard ranBefore else { return [] }
            after = nil
        }
        let versions = available.compactMap(ReleaseVersion.init).filter { v in
            if let after { return v > after && v <= now }
            return v == now
        }
        return versions.sorted(by: >).prefix(mostVersions).map(\.description)
    }
}
