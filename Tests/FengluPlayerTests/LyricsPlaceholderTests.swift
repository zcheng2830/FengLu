import Testing
@testable import FengluPlayer

struct LyricsPlaceholderTests {
    @Test(arguments: LyricsPlaceholderFixture.allCases)
    func removesOnlyRecognizedUnavailableAnnotations(_ fixture: LyricsPlaceholderFixture) {
        let result = LyricsParser.removingPlaceholderAnnotations(from: fixture.input)

        #expect(result.text == fixture.expectedText)
        #expect(result.removed == fixture.expectedRemoved)
    }

    @Test(arguments: ["(instrumental)", "[pure music]"])
    func instrumentalOnlyTextStillFailsTheGeneralPlaceholderCheck(_ text: String) {
        #expect(LyricsParser.lyricContentLineLooksLikePlaceholder(text))
        #expect(!LyricsParser.looksUsable("\(text)\n\(text)"))
    }

    @Test(arguments: [33, 40])
    func depthLimitKeepsCompletedRemovalsAndRemainingText(_ depth: Int) {
        let remainder = String(repeating: "(", count: depth) + "tail"
        let rootRemoval = LyricsParser.removingPlaceholderAnnotations(from: "(lyrics not available)" + remainder)
        #expect(rootRemoval.text == remainder)
        #expect(rootRemoval.removed)

        let nestedRemoval = LyricsParser.removingPlaceholderAnnotations(from: "Intro (quietly (lyrics not available)" + remainder)
        #expect(nestedRemoval.text == "Intro (quietly " + remainder)
        #expect(nestedRemoval.removed)

        let unchanged = LyricsParser.removingPlaceholderAnnotations(from: "Intro " + remainder)
        #expect(unchanged.text == "Intro " + remainder)
        #expect(!unchanged.removed)

        let afterLimit = LyricsParser.removingPlaceholderAnnotations(
            from: "Intro " + remainder + " (lyrics not available) after"
        )
        #expect(afterLimit.text == "Intro " + remainder + " after")
        #expect(afterLimit.removed)

        let fullWidthAfterLimit = LyricsParser.removingPlaceholderAnnotations(
            from: "Intro " + remainder + "［no lyrics available］末"
        )
        #expect(fullWidthAfterLimit.text == "Intro " + remainder + "末")
        #expect(fullWidthAfterLimit.removed)

        let unclosedMarker = "Intro " + String(repeating: "(", count: depth) + "lyrics not available"
        let unclosedResult = LyricsParser.removingPlaceholderAnnotations(from: unclosedMarker)
        #expect(unclosedResult.text == unclosedMarker)
        #expect(!unclosedResult.removed)
    }

    @Test
    func tagBoundariesPreserveMalformedLyricTextAndSpacedMetadata() throws {
        let malformed = "[Oh baby, I told you [twice] go home"
        let nested = "[Oh[twice] go home"
        for line in [malformed, nested] {
            let parts = LyricsParser.lyricLineParts(line)
            #expect(parts.prefix.isEmpty)
            #expect(parts.content == line)
        }
        let tagged = LyricsParser.lyricLineParts("[ar:Taylor Swift][00:12.00]Words stay here")
        #expect(tagged.prefix == "[ar:Taylor Swift][00:12.00]")
        #expect(tagged.content == "Words stay here")
        #expect(LyricsParser.lyricLineParts("[no lyrics available]").content == "[no lyrics available]")

        let document = try #require(LyricsParser.parse(
            "[ar:Taylor Swift]\n[ti:Words stay here]\n" + malformed + "\n[Verse]Words stay here",
            sourceURL: nil, sourceDescription: "tag-boundary fixture"
        ))
        #expect(document.plainText == malformed + "\nWords stay here")
        #expect(document.lines.map(\.text) == [malformed, "Words stay here"])
    }

    @Test(arguments: [
        "[Verse 1]", "[Chorus 2]", "[Verse 1: Taylor Swift]",
        "[tool:LRC Editor Pro]", "[#:transcribed by fan club]"
    ])
    func spacedTagsAreNeitherDisplayedNorCounted(_ tag: String) throws {
        let parts = LyricsParser.lyricLineParts(tag)
        #expect(parts.prefix == tag)
        #expect(parts.content.isEmpty)
        #expect(LyricsParser.contentLineCount(tag) == 0)
        #expect(!LyricsParser.looksUsable(tag))
        #expect(LyricsParser.parse(tag, sourceURL: nil, sourceDescription: "tag-only fixture") == nil)

        let verses = "A quiet river follows the morning light\nThe distant hills return a silver sound"
        let text = tag + "\n" + verses
        let document = try #require(LyricsParser.parse(text, sourceURL: nil, sourceDescription: "spaced-tag fixture"))
        #expect(document.plainText == verses)
        #expect(LyricsParser.contentLineCount(text) == 2)
    }
}

struct LyricsPlaceholderFixture: Sendable {
    let input: String
    let expectedText: String
    let expectedRemoved: Bool

    static let allCases: [Self] = [
        .init(input: "(lyrics not available)", expectedText: "", expectedRemoved: true),
        .init(input: "[lyrics not available]", expectedText: "", expectedRemoved: true),
        .init(input: "No lyrics available", expectedText: "", expectedRemoved: true),
        .init(input: "  (LYRICS NOT AVAILABLE)  ", expectedText: "", expectedRemoved: true),
        // A stage note alone is not an unavailable-lyrics annotation.
        .init(input: "(instrumental)", expectedText: "(instrumental)", expectedRemoved: false),
        .init(input: "[pure music]", expectedText: "[pure music]", expectedRemoved: false),
        .init(input: "III. Finale (lyrics not available)", expectedText: "III. Finale", expectedRemoved: true),
        .init(input: "III. Finale [lyrics not available]", expectedText: "III. Finale", expectedRemoved: true),
        .init(input: "III. Finale (no lyrics)", expectedText: "III. Finale", expectedRemoved: true),
        .init(input: "III. Finale [no lyric]", expectedText: "III. Finale", expectedRemoved: true),
        .init(input: "Before (lyrics not available) after", expectedText: "Before after", expectedRemoved: true),
        .init(input: "Before(lyrics not available)after", expectedText: "Beforeafter", expectedRemoved: true),
        .init(input: "Intro (lyrics not available), the end", expectedText: "Intro, the end", expectedRemoved: true),
        .init(input: "Hello, (lyrics not available) world", expectedText: "Hello, world", expectedRemoved: true),
        .init(input: "Hello,(lyrics not available)world", expectedText: "Hello,world", expectedRemoved: true),
        .init(input: "Before (lyrics not available) (unfinished", expectedText: "Before (unfinished", expectedRemoved: true),
        .init(input: "Intro (lyrics not available).", expectedText: "Intro.", expectedRemoved: true),
        .init(input: "夜の（lyrics not available）歌", expectedText: "夜の歌", expectedRemoved: true),
        .init(input: "春［lyrics not available］风", expectedText: "春风", expectedRemoved: true),
        .init(input: "été(lyrics not available)hiver", expectedText: "étéhiver", expectedRemoved: true),
        .init(input: "Intro (lyrics not available) - Part II", expectedText: "Intro - Part II", expectedRemoved: true),
        .init(input: "Intro (lyrics not available) & another voice", expectedText: "Intro & another voice", expectedRemoved: true),
        .init(input: "Intro (lyrics not available) \"another voice\"", expectedText: "Intro \"another voice\"", expectedRemoved: true),
        .init(input: "Intro (lyrics not available) ¿quién?", expectedText: "Intro ¿quién?", expectedRemoved: true),
        .init(input: "Intro (lyrics not available) ¡ven!", expectedText: "Intro ¡ven!", expectedRemoved: true),
        .init(input: "Baby (lyrics not available) 君を", expectedText: "Baby 君を", expectedRemoved: true),
        .init(input: "君を (lyrics not available) Baby", expectedText: "君を Baby", expectedRemoved: true),
        .init(input: "君を(lyrics not available)Baby", expectedText: "君をBaby", expectedRemoved: true),
        .init(input: "ภาษา(lyrics not available)ไทย", expectedText: "ภาษาไทย", expectedRemoved: true),
        .init(input: "ພາສາ(lyrics not available)ລາວ", expectedText: "ພາສາລາວ", expectedRemoved: true),
        .init(input: "ភាសា(lyrics not available)ខ្មែរ", expectedText: "ភាសាខ្មែរ", expectedRemoved: true),
        .init(input: "မြန်မာ(lyrics not available)စာ", expectedText: "မြန်မာစာ", expectedRemoved: true),
        .init(input: "カ(lyrics not available)ー", expectedText: "カー", expectedRemoved: true),
        // Only whitespace touching a removed marker is normalized.
        .init(input: "A  quiet\tvoice (lyrics not available) answers  softly", expectedText: "A  quiet\tvoice answers  softly", expectedRemoved: true),
        .init(input: "Before \t (lyrics not available) \t after", expectedText: "Before after", expectedRemoved: true),
        .init(input: "(lyrics not available)  A  quiet\tvoice", expectedText: "A  quiet\tvoice", expectedRemoved: true),
        .init(input: "A  quiet\tvoice  (lyrics not available)", expectedText: "A  quiet\tvoice", expectedRemoved: true),
        .init(input: "  Before  (lyrics not available) after  ", expectedText: "  Before after  ", expectedRemoved: true),
        .init(input: "  A  quiet\tvoice (whispers)  ", expectedText: "  A  quiet\tvoice (whispers)  ", expectedRemoved: false),
        .init(input: "III. Finale (lyrics not available) [no lyrics available]", expectedText: "III. Finale", expectedRemoved: true),
        .init(input: "III. Finale ((lyrics not available))", expectedText: "III. Finale", expectedRemoved: true),
        .init(input: "III. Finale [(lyrics not available)]", expectedText: "III. Finale", expectedRemoved: true),
        .init(input: "III. Finale （lyrics not available）", expectedText: "III. Finale", expectedRemoved: true),
        .init(input: "III. Finale ［no lyrics available］", expectedText: "III. Finale", expectedRemoved: true),
        .init(input: "III. Finale 【lyrics not available】", expectedText: "III. Finale", expectedRemoved: true),
        .init(input: "夜の歌 （[lyrics not available]）", expectedText: "夜の歌", expectedRemoved: true),
        .init(input: "Intro (quietly (lyrics not available))", expectedText: "Intro (quietly)", expectedRemoved: true),
        .init(input: "Intro （quietly ［no lyrics available］）", expectedText: "Intro （quietly）", expectedRemoved: true),
        .init(input: "Intro (very  quietly\tnow (lyrics not available))  ends", expectedText: "Intro (very  quietly\tnow)  ends", expectedRemoved: true),
        .init(input: "Intro (  quietly  (lyrics not available))  ends", expectedText: "Intro (  quietly)  ends", expectedRemoved: true),
        .init(input: "Intro ((lyrics not available)  softly  now)  ends", expectedText: "Intro (softly  now)  ends", expectedRemoved: true),
        .init(input: "Intro (instrumental)", expectedText: "Intro (instrumental)", expectedRemoved: false),
        .init(input: "Backing [pure music]", expectedText: "Backing [pure music]", expectedRemoved: false),
        .init(input: "Intro （instrumental）", expectedText: "Intro （instrumental）", expectedRemoved: false),
        .init(input: "III. Finale (whispers)", expectedText: "III. Finale (whispers)", expectedRemoved: false),
        .init(input: "Keep (these words) in the song", expectedText: "Keep (these words) in the song", expectedRemoved: false),
        .init(input: "Keep ((these words)) in the song", expectedText: "Keep ((these words)) in the song", expectedRemoved: false),
        .init(input: "My (lyrics not available yet) remain", expectedText: "My (lyrics not available yet) remain", expectedRemoved: false),
        // Preserve unmatched characters while removing independently balanced groups.
        .init(input: "Intro (lyrics not available", expectedText: "Intro (lyrics not available", expectedRemoved: false),
        .init(input: "Intro ((lyrics not available)", expectedText: "Intro", expectedRemoved: true),
        .init(input: "Intro (((lyrics not available)", expectedText: "Intro", expectedRemoved: true),
        .init(input: "Intro （【［lyrics not available］", expectedText: "Intro", expectedRemoved: true),
        .init(input: "Intro (lyrics not available]", expectedText: "Intro (lyrics not available]", expectedRemoved: false),
        .init(input: "Intro (lyrics not available)]", expectedText: "Intro]", expectedRemoved: true),
        .init(input: "Intro ] (lyrics not available)", expectedText: "Intro ]", expectedRemoved: true),
        .init(input: "III. Finale :) (lyrics not available)", expectedText: "III. Finale :)", expectedRemoved: true),
        .init(input: "Intro （no lyrics available）］", expectedText: "Intro］", expectedRemoved: true),
        .init(input: "Before (lyrics not available) after (unfinished", expectedText: "Before after (unfinished", expectedRemoved: true),
        .init(input: "Before [unfinished (lyrics not available) after", expectedText: "Before [unfinished after", expectedRemoved: true),
        .init(input: "Before (unfinished] after [lyrics not available]", expectedText: "Before (unfinished] after", expectedRemoved: true),
        .init(input: "Before (lyrics not available) after (unfinished]", expectedText: "Before after (unfinished]", expectedRemoved: true),
        .init(input: "No lyrics were available until you came", expectedText: "No lyrics were available until you came", expectedRemoved: false)
    ]
}
