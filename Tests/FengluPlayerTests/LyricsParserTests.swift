import Foundation
import Testing
@testable import FengluPlayer

struct LyricsParserTests {
    private func times(_ text: String) throws -> [TimeInterval] {
        let document = try #require(LyricsParser.parse(text, sourceURL: nil, sourceDescription: "test"))
        #expect(document.isSynchronized)
        return try document.lines.map { try #require($0.time) }
    }

    @Test(arguments: [
        ("[00:01.50]line", 1.5),
        ("[00:01.500]line", 1.5),
        ("[00:01.5]line", 1.5),
        ("[01:02]line", 62.0),
        ("[1:02.25]line", 62.25),
        ("[100:00.00]line", 6000.0)
    ])
    func parsesTimestampPrecisions(_ line: String, _ expected: TimeInterval) throws {
        let parsed = try times(line + "\n[199:59.00]tail of the song")
        #expect(abs(parsed[0] - expected) < 0.0005)
    }

    @Test func expandsSeveralTimestampsOnOneLineInTimeOrder() throws {
        let document = try #require(LyricsParser.parse(
            "[00:30.00][00:10.00]Chorus line\n[00:20.00]Verse line",
            sourceURL: nil, sourceDescription: "test"
        ))
        #expect(document.lines.map(\.text) == ["Chorus line", "Verse line", "Chorus line"])
        #expect(document.lines.compactMap(\.time) == [10, 20, 30])
    }

    @Test(arguments: [
        ("[offset:500]", 9.5),
        ("[offset:+500]", 9.5),
        ("[offset: +500]", 9.5),
        ("[offset:+ 500]", 9.5),
        ("[ offset : 500 ]", 9.5),
        ("[OFFSET:-500]", 10.5),
        ("[offset: -250.5]", 10.2505),
        ("[offset:0]", 10.0)
    ])
    func positiveOffsetShowsLyricsEarlier(_ tag: String, _ expected: TimeInterval) throws {
        let parsed = try times("\(tag)\n[00:10.00]First line\n[00:20.00]Second line")
        #expect(abs(parsed[0] - expected) < 0.0005)
        #expect(abs(parsed[1] - (expected + 10)) < 0.0005)
    }

    @Test func offsetAppliesToLinesBeforeTheTagAndClampsAtZero() throws {
        let parsed = try times("[00:00.20]Early line\n[00:10.00]First line\n[offset:500]\n[00:20.00]Second line")
        #expect(parsed == [0, 9.5, 19.5])
    }
}
