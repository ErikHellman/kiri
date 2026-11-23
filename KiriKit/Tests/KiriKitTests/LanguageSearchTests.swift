import Testing
@testable import KiriKit

/// The language picker's search: by name, by extension, by file name.
struct LanguageSearchTests {
    private func first(_ text: String) -> Language? { LanguageSearch.search(text).first?.language }

    @Test func nothingTypedListsEveryLanguagePlainTextFirstThenByName() {
        let hits = LanguageSearch.search("")
        #expect(hits.count == Language.all.count)
        #expect(hits.first?.language == .plainText)
        let names = hits.dropFirst().map { $0.language.name.lowercased() }
        #expect(names == names.sorted())
        #expect(hits.allSatisfy { $0.nameMarks.isEmpty && $0.detailMarks.isEmpty })
    }

    @Test func aNameFindsItsLanguage() {
        #expect(first("rust") == .rust)
        #expect(first("Python") == .python)
        #expect(first("pyth") == .python)
        #expect(first("objc") == .objectiveC)
        #expect(first("c") == .c)
        #expect(first("c#") == .csharp)
        #expect(first("c++") == .cpp)
        #expect(first("go") == .go)
        #expect(first("type") == .typescript)
    }

    @Test func anExtensionOrAFileNameFindsItsLanguage() {
        #expect(first("rs") == .rust)
        #expect(first(".rs") == .rust)
        #expect(first("yml") == .yaml)
        #expect(first("kt") == .kotlin)
        #expect(first("js") == .javascript)
        #expect(first("py") == .python)
        #expect(first("h") == .c)
        #expect(first("hpp") == .cpp)
        #expect(first("Gemfile") == .ruby)
        #expect(first("Dockerfile") == .dockerfile)
    }

    @Test func anExtensionThatWasTypedIsShownFirst() {
        let hit = LanguageSearch.search("hpp").first
        #expect(hit?.detail.hasPrefix(".hpp") == true)
        #expect(LanguageSearch.detail(of: .cpp).split(separator: " ").count == LanguageSearch.mostExtensions)
        #expect(LanguageSearch.detail(of: .rust) == ".rs")
        #expect(LanguageSearch.detail(of: .yaml) == ".yml .yaml")
    }

    @Test func theLettersAreMarkedWhereTheyWereFound() {
        // "ru" alone is Ruby as much as Rust (and Ruby comes first by name).
        let rust = LanguageSearch.search("rus").first
        #expect(rust?.language == .rust)
        #expect(rust?.nameMarks == [0..<3])
        #expect(rust?.detailMarks == [])
        // In the name if they are there, else in the extensions.
        let swift = LanguageSearch.search("swiftint").first
        #expect(swift?.language == .swift)
        #expect(swift?.nameMarks == [])
        #expect(swift?.detailMarks.isEmpty == false)
    }

    @Test func lettersAreNotPickedUpAcrossTwoExtensions() {
        // "ts" is in ".swift .swiftinterface" only as a t of one and an s of the other.
        #expect(!LanguageSearch.search("ts").contains { $0.language == .swift })
        let cpp = LanguageSearch.search("cxx").first { $0.language == .cpp }
        let detail = cpp.map { Array($0.detail.utf16) } ?? []
        let marked = cpp?.detailMarks.flatMap { Array($0) }.map { detail[$0] } ?? []
        #expect(String(decoding: marked, as: UTF16.self) == "cxx")
    }

    @Test func whatMatchesNothingFindsNothing() {
        #expect(LanguageSearch.search("zzqqxx").isEmpty)
    }
}
