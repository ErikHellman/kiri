/// When each word of a file that opens fades in (the app's `TextReveal`):
/// line by line, one word at a time, each line starting when the one
/// before it is a fifth of the way through.
///
/// A line's words follow each other `stagger` apart and each takes `fade`
/// to come in, so a line of n words lasts (n − 1) × stagger + fade, and an
/// empty line no time at all. A screen full of text would take too long at
/// the resting pace, so the whole schedule is sped up evenly to fit
/// `budget`, which keeps the fifth exact; words never come in faster than
/// `minimumFade`, so a very tall window may run over its budget instead of
/// flashing.
public struct RevealSchedule: Sendable {
    /// The resting pace (seconds).
    public static let wordStagger = 0.018
    public static let wordFade = 0.14
    /// The fastest a word may come in.
    public static let minimumFade = 0.04
    /// How far through a line the next one starts.
    public static let lead = 0.2
    /// The longest the reveal of a full window should take.
    public static let defaultBudget = 0.4

    public let wordCounts: [Int]
    /// Each line's start, from the first line's start.
    public let lineStarts: [Double]
    public let stagger: Double
    public let fade: Double
    /// How much the resting pace was sped up by (1 when it wasn't).
    public let scale: Double
    /// When the last word is in.
    public let total: Double

    public init(wordCounts: [Int], budget: Double = RevealSchedule.defaultBudget) {
        self.wordCounts = wordCounts
        func plan(_ stagger: Double, _ fade: Double) -> (starts: [Double], total: Double) {
            var starts: [Double] = [], t = 0.0, end = 0.0
            for n in wordCounts {
                starts.append(t)
                let d = Self.duration(words: n, stagger: stagger, fade: fade)
                end = max(end, t + d)
                t += Self.lead * d
            }
            return (starts, end)
        }
        let resting = plan(Self.wordStagger, Self.wordFade)
        var scale = resting.total > budget ? budget / resting.total : 1
        scale = max(scale, Self.minimumFade / Self.wordFade)
        stagger = Self.wordStagger * scale
        fade = Self.wordFade * scale
        self.scale = scale
        let planned = scale == 1 ? resting : plan(stagger, fade)
        lineStarts = planned.starts
        total = planned.total
    }

    /// How long line `i`'s words take, from its first word's start to its
    /// last word being in.
    public func lineDuration(_ i: Int) -> Double {
        Self.duration(words: wordCounts[i], stagger: stagger, fade: fade)
    }

    /// When word `word` of line `line` starts to come in.
    public func wordBegin(line: Int, word: Int) -> Double {
        lineStarts[line] + Double(word) * stagger
    }

    private static func duration(words: Int, stagger: Double, fade: Double) -> Double {
        words == 0 ? 0 : Double(words - 1) * stagger + fade
    }

    /// The words of `line`: runs of anything but white space, as UTF-16
    /// offsets (what TextKit measures).
    public static func words(in line: String) -> [Range<Int>] {
        var words: [Range<Int>] = []
        var start: Int?
        var i = 0
        for unit in line.utf16 {
            let blank = unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0B || unit == 0x0C
                || unit == 0xA0 || unit == 0x2028 || unit == 0x2029 || unit == 0x3000
            if blank {
                if let s = start { words.append(s..<i); start = nil }
            } else if start == nil {
                start = i
            }
            i += 1
        }
        if let s = start { words.append(s..<i) }
        return words
    }
}
