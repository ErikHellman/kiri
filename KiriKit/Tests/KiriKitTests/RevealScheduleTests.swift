import Testing
@testable import KiriKit

@Suite struct RevealScheduleTests {
    @Test func wordsAreRunsOfNonWhiteSpace() {
        #expect(RevealSchedule.words(in: "let name = 1") == [0..<3, 4..<8, 9..<10, 11..<12])
        #expect(RevealSchedule.words(in: "    return x\n") == [4..<10, 11..<12])
        #expect(RevealSchedule.words(in: "\tfoo\t\tbar") == [1..<4, 6..<9])
        #expect(RevealSchedule.words(in: "") == [])
        #expect(RevealSchedule.words(in: "   \n") == [])
    }

    @Test func wordsCountUTF16Units() {
        // "é" is one unit, the emoji two.
        #expect(RevealSchedule.words(in: "é 😀x") == [0..<1, 2..<5])
    }

    @Test func eachLineStartsWhenTheOneBeforeIsAFifthDone() {
        let s = RevealSchedule(wordCounts: [3, 5, 2], budget: 100)
        #expect(s.scale == 1)
        let first = s.lineDuration(0)
        #expect(close(first, 2 * RevealSchedule.wordStagger + RevealSchedule.wordFade))
        #expect(close(s.lineStarts[0], 0))
        #expect(close(s.lineStarts[1], 0.2 * first))
        #expect(close(s.lineStarts[2], s.lineStarts[1] + 0.2 * s.lineDuration(1)))
        // The longest line ends last, not the last line.
        #expect(close(s.total, (0..<3).map { s.lineStarts[$0] + s.lineDuration($0) }.max()!))
    }

    @Test func wordsWithinALineFollowEachOther() {
        let s = RevealSchedule(wordCounts: [4, 4], budget: 100)
        #expect(close(s.wordBegin(line: 1, word: 0), s.lineStarts[1]))
        #expect(close(s.wordBegin(line: 1, word: 3), s.lineStarts[1] + 3 * s.stagger))
        #expect(close(s.wordBegin(line: 1, word: 3) + s.fade, s.lineStarts[1] + s.lineDuration(1)))
    }

    @Test func anEmptyLineTakesNoTime() {
        let s = RevealSchedule(wordCounts: [2, 0, 2], budget: 100)
        #expect(s.lineDuration(1) == 0)
        #expect(close(s.lineStarts[2], s.lineStarts[1]))
    }

    @Test func aFullScreenIsHurriedToTheBudgetKeepingTheFifth() {
        let counts = Array(repeating: 7, count: 50)
        let s = RevealSchedule(wordCounts: counts, budget: 0.9)
        #expect(s.scale < 1)
        #expect(s.total <= 0.9 + 1e-9 || close(s.fade, RevealSchedule.minimumFade))
        // The lead is still a fifth of the line before, however fast.
        for i in 1..<counts.count {
            #expect(close(s.lineStarts[i] - s.lineStarts[i - 1], 0.2 * s.lineDuration(i - 1)))
        }
    }

    @Test func wordsNeverFadeFasterThanTheFloor() {
        let s = RevealSchedule(wordCounts: Array(repeating: 12, count: 200), budget: 0.9)
        #expect(close(s.fade, RevealSchedule.minimumFade))
        #expect(s.total > 0.9)
    }

    @Test func nothingToShowTakesNoTime() {
        #expect(RevealSchedule(wordCounts: [], budget: 1).total == 0)
        #expect(RevealSchedule(wordCounts: [0, 0], budget: 1).total == 0)
    }

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
}
