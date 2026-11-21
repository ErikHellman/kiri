import Testing
@testable import KiriKit

@Suite struct StatusTextTests {
    @Test func positionShowsLineAndColumn() {
        #expect(StatusText.position(line: 12, column: 5) == "Ln 12, Col 5")
        #expect(StatusText.position(line: 1, column: 1, selected: 0) == "Ln 1, Col 1")
    }

    @Test func aSelectionTakesTheColumnsPlace() {
        #expect(StatusText.position(line: 12, column: 5, selected: 5) == "Ln 12, Sel 5")
        #expect(StatusText.position(line: 3, column: 1, selected: 1234) == "Ln 3, Sel 1234")
    }

    @Test func spokenPositionSaysItInWords() {
        #expect(StatusText.spokenPosition(line: 12, lineCount: 340, column: 5) == "Line 12 of 340, column 5")
        #expect(StatusText.spokenPosition(line: 12, lineCount: 340, column: 5, selected: 1) == "Line 12 of 340, 1 character selected")
        #expect(StatusText.spokenPosition(line: 12, lineCount: 340, column: 5, selected: 7) == "Line 12 of 340, 7 characters selected")
    }

    @Test func aNewDocumentReservesTwoDigitsAndThreeForASelection() {
        let reserve = StatusText.Reserve()
        #expect(reserve.texts == ["Ln 88, Col 88", "Ln 88, Sel 888"])
        #expect(reserve == StatusText.Reserve(lineCount: 99, longestLine: 98, length: 999))
    }

    @Test func theReserveGrowsOnlyAtPowersOfTen() {
        #expect(StatusText.Reserve(lineCount: 99, longestLine: 20, length: 500) == StatusText.Reserve(lineCount: 10, longestLine: 5, length: 100))
        #expect(StatusText.Reserve(lineCount: 100).lineDigits == 3)
        #expect(StatusText.Reserve(lineCount: 999).lineDigits == 3)
        #expect(StatusText.Reserve(lineCount: 1000).lineDigits == 4)
        // The caret can stand after the last character of the longest line.
        #expect(StatusText.Reserve(longestLine: 98).columnDigits == 2)
        #expect(StatusText.Reserve(longestLine: 99).columnDigits == 3)
        #expect(StatusText.Reserve(length: 999).selectionDigits == 3)
        #expect(StatusText.Reserve(length: 1000).selectionDigits == 4)
    }

    @Test func theReserveHoldsEveryPositionTheDocumentHas() {
        // 340 lines, the longest 120 characters, 9,800 characters in all.
        let reserve = StatusText.Reserve(lineCount: 340, longestLine: 120, length: 9800)
        #expect(reserve.texts == ["Ln 888, Col 888", "Ln 888, Sel 8888"])
        let widest = reserve.texts.map(\.count).max()!
        for (line, column, selected) in [(1, 1, 0), (9, 1, 0), (10, 80, 0), (340, 121, 0), (1, 1, 9800), (340, 1, 1)] {
            #expect(StatusText.position(line: line, column: column, selected: selected).count <= widest)
        }
    }
}

@Suite struct IndentStyleTests {
    @Test func labels() {
        #expect(IndentStyle.tabs.label == "Tabs")
        #expect(IndentStyle.spaces(4).label == "Spaces: 4")
        #expect(IndentStyle.spaces(2).spoken == "2 spaces")
        #expect(IndentStyle.spaces(1).spoken == "1 space")
        #expect(IndentStyle.widestLabel == "Spaces: 8")
    }

    @Test func unitsAndWidths() {
        #expect(IndentStyle.tabs.unit == "\t")
        #expect(IndentStyle.tabs.width == 4)
        #expect(IndentStyle.spaces(2).unit == "  ")
        #expect(IndentStyle.spaces(2).width == 2)
    }

    @Test func noIndentedLineMeansTabs() {
        #expect(IndentStyle.detect(in: "") == .tabs)
        #expect(IndentStyle.detect(in: "one\ntwo\n") == .tabs)
        // Lines of nothing but spaces say nothing.
        #expect(IndentStyle.detect(in: "one\n    \ntwo\n") == .tabs)
    }

    @Test func theSmallestRunOfLeadingSpaces() {
        #expect(IndentStyle.detect(in: "struct A {\n    let a = 1\n        let b = 2\n}\n") == .spaces(4))
        #expect(IndentStyle.detect(in: "a:\n  b:\n    c: 1\n") == .spaces(2))
        #expect(IndentStyle.detect(in: "a\n            deep\n") == .spaces(8))
        // Spaces before a tab still count as the line's spaces.
        #expect(IndentStyle.detect(in: "a\n  \tb\n") == .spaces(2))
    }

    @Test func aLeadingTabMeansTabsUnlessSpacesCameFirst() {
        #expect(IndentStyle.detect(in: "func a() {\n\treturn\n}\n") == .tabs)
        #expect(IndentStyle.detect(in: "a\n\tb\n    c\n") == .tabs)
        #expect(IndentStyle.detect(in: "a\n    b\n\tc\n  d\n") == .spaces(4))
    }

    @Test func onlyTheHeadOfALongTextIsRead() {
        let filler = String(repeating: "x\n", count: IndentStyle.head)
        #expect(IndentStyle.detect(in: filler + "  indented\n") == .tabs)
        #expect(IndentStyle.detect(in: "  indented\n" + filler) == .spaces(2))
    }

    @Test func windowsAndOldMacLineEndings() {
        #expect(IndentStyle.detect(in: "a\r\n  b\r\n") == .spaces(2))
        #expect(IndentStyle.detect(in: "a\r\tb\r") == .tabs)
    }
}
