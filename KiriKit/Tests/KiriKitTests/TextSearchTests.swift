import Foundation
import Testing
@testable import KiriKit

@Suite struct TextSearchTests {
    let text = "let count = 0\ncount += 1 // Count them\nprint(count)\n"

    func ranges(_ query: String, _ options: SearchOptions = SearchOptions(), in text: String) throws -> [Range<Int>] {
        try #require(try TextSearch(query, options: options).matches(in: text)).ranges
    }

    @Test func plainSearchIgnoresCaseUnlessAsked() throws {
        #expect(try ranges("count", in: text) == [4..<9, 14..<19, 28..<33, 45..<50])
        #expect(try ranges("COUNT", in: text).count == 4)
        #expect(try ranges("count", SearchOptions(matchCase: true), in: text) == [4..<9, 14..<19, 45..<50])
        #expect(try ranges("Count", SearchOptions(matchCase: true), in: text) == [28..<33])
        #expect(try ranges("missing", in: text).isEmpty)
    }

    @Test func plainSearchTakesItsQueryLiterally() throws {
        #expect(try ranges("(count)", in: text) == [44..<51])
        #expect(try ranges(".", in: "a.b.c") == [1..<2, 3..<4])
        #expect(try ranges("+= 1", in: text) == [20..<24])
        #expect(try ranges("\\d", in: "a1 \\d") == [3..<5])
    }

    @Test func offsetsAreUTF16() throws {
        // The wave is two UTF-16 units, é one.
        #expect(try ranges("b", in: "a🌊b é b") == [3..<4, 7..<8])
        #expect(try ranges("é", in: "a🌊b é b") == [5..<6])
    }

    @Test func anEmptyQueryFindsNothing() throws {
        #expect(try ranges("", in: text).isEmpty)
        #expect(try ranges("", SearchOptions(regularExpression: true), in: text).isEmpty)
        #expect(try TextSearch("").replaceAll(in: text, with: "x") == nil)
    }

    @Test func regularExpressions() throws {
        let regex = SearchOptions(regularExpression: true)
        #expect(try ranges("c\\w+t", regex, in: text) == [4..<9, 14..<19, 28..<33, 45..<50])
        #expect(try ranges("\\d+", regex, in: text) == [12..<13, 23..<24])
        // ^ and $ work on every line.
        #expect(try ranges("^count", regex, in: text) == [14..<19])
        #expect(try ranges("\\d$", regex, in: text) == [12..<13])
        #expect(try ranges("^COUNT", SearchOptions(matchCase: true, regularExpression: true), in: text).isEmpty)
        // Matches of no length are left out; the search still ends.
        #expect(try ranges("^", regex, in: text).isEmpty)
        #expect(try ranges("x*", regex, in: "axxb") == [1..<3])
    }

    @Test func anInvalidRegularExpressionSaysSo() {
        #expect(throws: TextSearch.InvalidPattern.self) { try TextSearch("(", options: SearchOptions(regularExpression: true)) }
        #expect(throws: TextSearch.InvalidPattern.self) { try TextSearch("[a-", options: SearchOptions(regularExpression: true)) }
        // The same text is fine as a plain query.
        #expect(throws: Never.self) { try TextSearch("(") }
    }

    @Test func theLimitCutsALongListShort() throws {
        let many = String(repeating: "ab ", count: 50)
        let all = try #require(try TextSearch("ab").matches(in: many))
        #expect(all.ranges.count == 50 && !all.truncated)
        let some = try #require(try TextSearch("ab").matches(in: many, limit: 10))
        #expect(some.ranges.count == 10 && some.truncated)
        let exact = try #require(try TextSearch("ab").matches(in: many, limit: 50))
        #expect(exact.ranges.count == 50 && !exact.truncated)
    }

    @Test func aCancelledSearchHasNoResult() throws {
        let long = String(repeating: "abc def ghi\n", count: 20_000)
        #expect(try TextSearch("def").matches(in: long, isCancelled: { true }) == nil)
        #expect(try TextSearch("def").matches(in: long, isCancelled: { false })?.ranges.count == 20_000)
    }

    @Test func nextAndPreviousFromACaretWrapAround() throws {
        let found = try ranges("count", in: text)   // 4, 14, 28, 45
        func next(_ caret: Range<Int>, current: Int? = nil) -> Int? {
            TextSearch.step(from: current, selection: caret, forward: true, in: found)
        }
        func previous(_ caret: Range<Int>, current: Int? = nil) -> Int? {
            TextSearch.step(from: current, selection: caret, forward: false, in: found)
        }
        #expect(next(0..<0) == 0)
        #expect(next(4..<4) == 0, "a caret right before a match finds that match")
        #expect(next(5..<5) == 1)
        #expect(next(4..<9) == 1, "from a selected match, the one after it")
        #expect(next(46..<46) == 0, "wraps to the first")
        #expect(next(52..<52) == 0)
        #expect(previous(52..<52) == 3)
        #expect(previous(45..<50) == 2, "from a selected match, the one before it")
        #expect(previous(19..<19) == 1, "a caret right after a match finds that match")
        #expect(previous(18..<18) == 0)
        #expect(previous(4..<4) == 3, "wraps to the last")
        #expect(previous(0..<0) == 3)
        // From the current match, whatever the selection is.
        #expect(next(4..<4, current: 0) == 1)
        #expect(next(0..<0, current: 3) == 0)
        #expect(previous(0..<0, current: 0) == 3)
        #expect(previous(0..<0, current: 2) == 1)
        #expect(TextSearch.step(from: nil, selection: 0..<0, forward: true, in: []) == nil)
        #expect(TextSearch.step(from: 2, selection: 0..<0, forward: false, in: []) == nil)
    }

    @Test func theMatchAtTheCaretStaysCurrentWhileTyping() throws {
        let found = try ranges("count", in: text)
        #expect(TextSearch.index(startingAtOrAfter: 14, in: found) == 1)
        #expect(TextSearch.index(startingAtOrAfter: 15, in: found) == 2)
        #expect(TextSearch.index(startingAtOrAfter: 51, in: found) == 0)
        #expect(TextSearch.index(startingAtOrAfter: 0, in: []) == nil)
        #expect(TextSearch.index(of: 28..<33, in: found) == 2)
        #expect(TextSearch.index(of: 28..<32, in: found) == nil)
        #expect(TextSearch.index(of: 60..<65, in: found) == nil)
    }

    @Test func replacingOneMatch() throws {
        let search = try TextSearch("count")
        #expect(search.replacement(for: 14..<19, in: text, with: "tally") == "tally")
        // Plain replacements are taken literally.
        #expect(search.replacement(for: 14..<19, in: text, with: "$1 \\n $0") == "$1 \\n $0")
        #expect(search.replacement(for: 15..<20, in: text, with: "tally") == nil, "not a match")
        #expect(search.replacement(for: 14..<18, in: text, with: "tally") == nil, "not the whole match")
        #expect(search.replacement(for: 50..<99, in: text, with: "tally") == nil)
    }

    @Test func regularExpressionTemplates() throws {
        let regex = SearchOptions(regularExpression: true)
        let search = try TextSearch("(\\w+) \\+= (\\d+)", options: regex)
        let found = try #require(search.matches(in: text)).ranges
        #expect(found == [14..<24])
        #expect(search.replacement(for: found[0], in: text, with: "$1 = $1 + $2") == "count = count + 1")
        #expect(search.replacement(for: found[0], in: text, with: "[$0]") == "[count += 1]")
        #expect(search.replacement(for: found[0], in: text, with: "a\\nb\\tc") == "a\nb\tc")
        #expect(search.replacement(for: found[0], in: text, with: "\\$1 \\\\n") == "$1 \\n")
        #expect(search.replacement(for: found[0], in: text, with: "end\\") == "end\\")
        // A match found with `^` or a lookbehind is still one when replaced on its own.
        let anchored = try TextSearch("^count", options: regex)
        #expect(anchored.replacement(for: 14..<19, in: text, with: "n") == "n")
        #expect(anchored.replacement(for: 45..<50, in: text, with: "n") == nil)
        let behind = try TextSearch("(?<=\\()count", options: regex)
        #expect(behind.replacement(for: 45..<50, in: text, with: "n") == "n")
    }

    @Test func replacingAll() throws {
        let all = try #require(try TextSearch("count").replaceAll(in: text, with: "n"))
        #expect(all.count == 4)
        #expect(all.range == 4..<50)
        #expect(all.text == "n = 0\nn += 1 // n them\nprint(n")
        let (replaced, count) = try TextSearch("count").replacingAll(in: text, with: "n")
        #expect(replaced == "let n = 0\nn += 1 // n them\nprint(n)\n")
        #expect(count == 4)

        let cased = try TextSearch("count", options: SearchOptions(matchCase: true)).replacingAll(in: text, with: "n")
        #expect(cased.text == "let n = 0\nn += 1 // Count them\nprint(n)\n" && cased.count == 3)

        #expect(try TextSearch("missing").replaceAll(in: text, with: "n") == nil)
        #expect(try TextSearch("missing").replacingAll(in: text, with: "n") == (text, 0))

        // A replacement that holds the query again is not searched again.
        #expect(try TextSearch("a").replacingAll(in: "banana", with: "aa") == ("baanaanaa", 3))
        // Templates, and nothing but the matches changes.
        let swapped = try TextSearch("(\\w+)=(\\w+)", options: SearchOptions(regularExpression: true))
            .replacingAll(in: "a=1, b=2; 🌊 c=3", with: "$2=$1")
        #expect(swapped == ("1=a, 2=b; 🌊 3=c", 3))
        #expect(try TextSearch("=").replacingAll(in: "a=1", with: "$0\\") == ("a$0\\1", 1))
    }
}

@Suite struct LineTargetTests {
    @Test func aLineAndMaybeAColumn() {
        #expect(LineTarget("12", lineCount: 40) == LineTarget("12:1", lineCount: 40))
        #expect(LineTarget("12", lineCount: 40)?.line == 12)
        #expect(LineTarget("12:5", lineCount: 40)?.column == 5)
        #expect(LineTarget(" 12 : 5 ", lineCount: 40).map { [$0.line, $0.column] } == [12, 5])
        #expect(LineTarget("12:", lineCount: 40).map { [$0.line, $0.column] } == [12, 1])
        #expect(LineTarget("12:0", lineCount: 40)?.column == 1)
    }

    @Test func numbersPastTheEndsClamp() {
        #expect(LineTarget("999", lineCount: 40)?.line == 40)
        #expect(LineTarget("0", lineCount: 40)?.line == 1)
        #expect(LineTarget("-3", lineCount: 40)?.line == 1)
        #expect(LineTarget("7", lineCount: 0)?.line == 1)
    }

    @Test func anythingElseIsNotATarget() {
        #expect(LineTarget("", lineCount: 40) == nil)
        #expect(LineTarget("abc", lineCount: 40) == nil)
        #expect(LineTarget("12:x", lineCount: 40) == nil)
        #expect(LineTarget(":5", lineCount: 40) == nil)
        #expect(LineTarget("1:2:3", lineCount: 40) == nil)
        #expect(LineTarget("1.5", lineCount: 40) == nil)
    }
}
