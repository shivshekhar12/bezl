import Foundation
import Testing
@testable import BezlCore

@Suite struct LRCTests {
    @Test func parsesBasicLines() throws {
        let lrc = """
        [ar: Someone]
        [ti: Song]
        [00:01.50] First line
        [00:04.25]Second line
        [01:02.123] Third
        """
        let lyrics = try #require(SyncedLyrics.parse(lrc))
        #expect(lyrics.lines.count == 3)
        #expect(lyrics.lines[0] == .init(time: 1.5, text: "First line"))
        #expect(lyrics.lines[1].text == "Second line")
        #expect(abs(lyrics.lines[2].time - 62.123) < 1e-9)
    }

    @Test func multipleTimestampsAndSorting() throws {
        let lyrics = try #require(SyncedLyrics.parse("[00:30.00][00:10.00] Chorus\n[00:20.00] Verse"))
        #expect(lyrics.lines.map(\.time) == [10, 20, 30])
        #expect(lyrics.lines.map(\.text) == ["Chorus", "Verse", "Chorus"])
    }

    @Test func emptyLinesAreKeptAsBreaks() throws {
        let lyrics = try #require(SyncedLyrics.parse("[00:01.00] A\n[00:02.00]\n[00:03.00] B"))
        #expect(lyrics.lines.count == 3)
        #expect(lyrics.lines[1].text.isEmpty)
    }

    @Test func offsetTagShiftsTimes() throws {
        let lyrics = try #require(SyncedLyrics.parse("[offset:+500]\n[00:02.00] A"))
        #expect(abs(lyrics.lines[0].time - 1.5) < 1e-9)
    }

    @Test func plainTextIsNotSynced() {
        #expect(SyncedLyrics.parse("just some words\nno timestamps") == nil)
        #expect(SyncedLyrics.parse("") == nil)
    }

    @Test func lineLookup() throws {
        let lyrics = try #require(SyncedLyrics.parse("[00:01.00] A\n[00:05.00] B\n[00:09.00] C"))
        #expect(lyrics.lineIndex(at: 0.5) == nil)
        #expect(lyrics.lineIndex(at: 1.0) == 0)
        #expect(lyrics.lineIndex(at: 4.99) == 0)
        #expect(lyrics.lineIndex(at: 5) == 1)
        #expect(lyrics.lineIndex(at: 100) == 2)
    }
}

@Suite struct SemanticVersionTests {
    @Test func parsing() throws {
        let v = try #require(SemanticVersion("v1.2.3"))
        #expect(v.major == 1 && v.minor == 2 && v.patch == 3 && v.prerelease == nil)
        #expect(SemanticVersion("2")?.description == "2.0.0")
        #expect(SemanticVersion("1.0.0-beta.2")?.prerelease == "beta.2")
        #expect(SemanticVersion("banana") == nil)
        #expect(SemanticVersion("1.x") == nil)
    }

    @Test func ordering() throws {
        func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }
        #expect(v("0.1.0") < v("0.2.0"))
        #expect(v("0.9.9") < v("1.0.0"))
        #expect(v("1.0.0-beta") < v("1.0.0"))
        #expect(v("1.0.0-beta.2") < v("1.0.0-beta.10"))
        #expect(v("v1.2") == v("1.2.0"))
        #expect(!(v("1.0.0") < v("1.0.0")))
    }
}
