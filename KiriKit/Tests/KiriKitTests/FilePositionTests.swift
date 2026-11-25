import Foundation
import Testing
@testable import KiriKit

@Suite struct FilePositionTests {
    let text = "first\nsecond line\n\nfourth"

    @Test func aSelectionIsKeptAsLinesAndColumns() {
        let index = LineIndex(text)
        // "line" on the second line.
        let position = FilePosition(selection: 13..<17, topLine: 1, in: index)
        #expect(position.start == FilePosition.Point(line: 1, column: 7))
        #expect(position.end == FilePosition.Point(line: 1, column: 11))
        #expect(position.selection(in: index) == 13..<17)
        #expect(position.topOffset(in: index) == 6)
    }

    @Test func aCaretIsAnEmptySelection() {
        let index = LineIndex(text)
        let position = FilePosition(selection: 20..<20, topLine: 0, in: index)
        #expect(position.start == position.end)
        #expect(position.selection(in: index) == 20..<20)
    }

    @Test func aFileThatShrankKeepsThePositionInsideIt() {
        let position = FilePosition(start: .init(line: 3, column: 4), end: .init(line: 9, column: 2), topLine: 8)
        let index = LineIndex("one\ntwo")
        // Line 3 is gone: the end of the text.
        #expect(position.selection(in: index) == 7..<7)
        #expect(position.topOffset(in: index) == 4)
        // A column past its line's end is the end of that line.
        let long = FilePosition(start: .init(line: 0, column: 40), end: .init(line: 0, column: 40))
        #expect(long.selection(in: index) == 3..<3)
    }

    @Test func anEditAfterThePositionLeavesItWhereItWas() {
        let before = LineIndex(text)
        let position = FilePosition(selection: 13..<17, topLine: 1, in: before)
        let after = LineIndex(text + "\nmore\nlines")
        #expect(position.selection(in: after) == 13..<17)
    }

    @Test func theHeadOfTheFileIsTop() {
        let index = LineIndex(text)
        #expect(FilePosition(selection: 0..<0, topLine: 0, in: index).isTop)
        #expect(!FilePosition(selection: 0..<0, topLine: 0, topDelta: 3, in: index).isTop)
        #expect(FilePosition(selection: 5..<5, topLine: 0, in: index).scrolledToTop)
        #expect(!FilePosition(selection: 0..<0, topLine: 2, in: index).scrolledToTop)
    }

    @Test func theStoreKeepsAPositionPerPath() {
        var store = FilePositionStore()
        let a = FilePosition(start: .init(line: 4, column: 1), end: .init(line: 4, column: 1), topLine: 2)
        let first = store.set(a, for: "/a.txt")
        let again = store.set(a, for: "/a.txt")
        #expect(first)
        #expect(!again)
        #expect(store.position(for: "/a.txt") == a)
        #expect(store.position(for: "/b.txt") == nil)
        // The head of the file needs no keeping.
        let forgot = store.set(.top, for: "/a.txt")
        #expect(forgot)
        #expect(store.position(for: "/a.txt") == nil)
        #expect(store.count == 0)
    }

    @Test func theStoreForgetsThePositionsUsedLongestAgo() {
        var store = FilePositionStore(limit: 3)
        func at(_ line: Int) -> FilePosition { FilePosition(start: .init(line: line, column: 0), end: .init(line: line, column: 0)) }
        store.set(at(1), for: "/1")
        store.set(at(2), for: "/2")
        store.set(at(3), for: "/3")
        // Used again: the newest now.
        store.set(at(1), for: "/1")
        store.set(at(4), for: "/4")
        #expect(store.count == 3)
        #expect(store.position(for: "/2") == nil)
        #expect(store.position(for: "/1") == at(1))
        #expect(store.position(for: "/4") == at(4))
    }

    @Test func theStoreComesBackAsSaved() {
        var store = FilePositionStore()
        let a = FilePosition(start: .init(line: 4, column: 1), end: .init(line: 6, column: 0), topLine: 2, topDelta: 7.5,
                             scrollX: 30)
        store.set(a, for: "/a.txt")
        let back = FilePositionStore.decoded(store.encoded())
        #expect(back.position(for: "/a.txt") == a)
        #expect(FilePositionStore.decoded(Data("nonsense".utf8)).count == 0)
        #expect(FilePositionStore.decoded(nil).count == 0)
    }
}
