import Foundation

/// The language picker's search (⌃⌘L, or the language in the status
/// bar): a language found by a few letters of its name ("ts" finds
/// TypeScript, "objc" Objective-C) or by a file extension or file name it
/// is known by ("rs" finds Rust, "yml" YAML, "Gemfile" Ruby).
///
/// A name typed in full, then an extension or a file name typed in full,
/// comes first; after that the letters are scored as the command palette
/// scores them (`FuzzyQuery`), a match in the name over one in the
/// extensions. With nothing typed every language is listed, Plain Text
/// first and the rest by name.
public enum LanguageSearch {
    /// A language as the picker lists it.
    public struct Hit: Equatable, Sendable {
        public let language: Language
        /// The extensions it is known by, muted after the name: ".rs",
        /// ".yaml .yml".
        public let detail: String
        /// The letters that were typed, in the name and in the detail
        /// (UTF-16 offsets).
        public var nameMarks: [Range<Int>] = []
        public var detailMarks: [Range<Int>] = []
    }

    /// The most extensions a row shows (C++ has thirteen).
    public static let mostExtensions = 4

    /// Plain Text first, then the rest by name.
    public static func listed(_ languages: [Language] = Language.all) -> [Language] {
        languages.filter { $0 == .plainText }
            + languages.filter { $0 != .plainText }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The extensions of `language` as a row shows them: the shortest
    /// first, at most `mostExtensions`; `first` (one that was typed) ahead
    /// of the rest.
    public static func detail(of language: Language, first: String? = nil) -> String {
        var names = language.extensions.sorted { ($0.count, $0) < ($1.count, $1) }
        if let first, let i = names.firstIndex(of: first) { names.insert(names.remove(at: i), at: 0) }
        return names.prefix(mostExtensions).map { "." + $0 }.joined(separator: " ")
    }

    /// What `text` finds, best first.
    public static func search(_ text: String, in languages: [Language] = Language.all) -> [Hit] {
        let listed = listed(languages)
        let query = FuzzyQuery(text)
        guard !query.isEmpty else { return listed.map { Hit(language: $0, detail: detail(of: $0)) } }
        let typed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let bare = typed.hasPrefix(".") ? String(typed.dropFirst()) : typed
        var found: [(score: Int, order: Int, hit: Hit)] = []
        for (order, language) in listed.enumerated() {
            let byExtension = language.extensions.contains(bare)
            let byFileName = language.fileNames.contains { $0.lowercased() == typed }
            let detail = detail(of: language, first: byExtension ? bare : nil)
            var hit = Hit(language: language, detail: detail)
            var best: Int?
            if let match = query.match(FuzzyCandidate(language.name)), match.score >= query.weakest {
                best = match.score
                hit.nameMarks = match.ranges
            }
            if let match = bestExtension(query, in: detail), match.score - extensionPenalty > (best ?? .min) {
                best = match.score - extensionPenalty
                hit.nameMarks = []
                hit.detailMarks = match.ranges
            }
            if language.name.lowercased() == typed {
                best = typedInFull + 1
            } else if byExtension || byFileName {
                best = typedInFull
            }
            if let best { found.append((best, order, hit)) }
        }
        return found.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.map(\.hit)
    }

    /// The best match among the extensions of a `detail`, each looked at
    /// on its own (so the letters are never picked up across two of
    /// them), its marks as offsets into the whole detail.
    static func bestExtension(_ query: FuzzyQuery, in detail: String) -> FuzzyMatch? {
        var best: FuzzyMatch?
        var start = 0
        for part in detail.split(separator: " ") {
            let text = String(part)
            if let match = query.match(FuzzyCandidate(text)), match.score >= query.weakest, match.score > (best?.score ?? .min) {
                best = FuzzyMatch(score: match.score, ranges: match.ranges.map { ($0.lowerBound + start)..<($0.upperBound + start) })
            }
            start += text.utf16.count + 1
        }
        return best
    }

    /// A name, extension or file name typed in full is worth more than any
    /// letters can be.
    static let typedInFull = 1 << 40
    /// What a match in the extensions gives up to one as good in the name.
    static let extensionPenalty = 1
}
