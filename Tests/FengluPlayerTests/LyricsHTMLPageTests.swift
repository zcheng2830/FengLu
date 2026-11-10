import Foundation
import Testing
@testable import FengluPlayer

struct LyricsHTMLPageTests {
    @Test
    func retainedTextRegionDoesNotRetainParsedDocument() throws {
        weak var retainedPage: LyricsHTMLPage?
        let region: LyricsHTMLPage.TextRegion
        do {
            let page = try LyricsHTMLPage("<div id='lb-lyrics'>First verse</div>")
            retainedPage = page
            region = try #require(page.textRegion(preferred: "#lb-lyrics", excluding: "nav"))
        }
        #expect(retainedPage == nil)
        #expect(region.text.trimmingCharacters(in: .whitespacesAndNewlines) == "First verse")
    }

    @Test
    func inlineTextIsSeparatedFromTheFollowingBlock() throws {
        let page = try LyricsHTMLPage("Site logo<header><h1>Song Lyrics</h1></header><p>First verse</p>")
        let region = try #require(page.textRegion(preferred: "#lb-lyrics", excluding: "nav, button"))
        let lines = region.text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        #expect(lines == ["Site logo", "Song Lyrics", "First verse"])
    }

    @Test
    func legacyHeaderAnchorsKeepTheirPositionWithoutControls() throws {
        let page = try LyricsHTMLPage("""
            <div>Before the heading</div>
            <header class="lb-noprint"><h1>Excluded heading</h1></header>
            <header><nav><h1>Navigation heading</h1></nav><div>Share this song</div>
            <h1>Song Lyrics</h1><button>Share</button></header><p>First verse</p>
            """)
        let region = try #require(page.textRegion(preferred: "#lb-lyrics", excluding: "nav, button, .lb-noprint"))
        #expect(!region.isBounded)
        let lines = region.text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        #expect(lines == ["Before the heading", "Song Lyrics", "First verse"])
    }

    @Test(arguments: [true, false])
    func invalidRegionSelectorsDoNotFallBackToBody(invalidContainer: Bool) throws {
        let page = try LyricsHTMLPage("<div id='lb-lyrics'>Verse</div><aside>Other text</aside>")
        #expect(page.textRegion(
            preferred: invalidContainer ? "[" : "#lb-lyrics",
            excluding: invalidContainer ? "aside" : "["
        ) == nil)
    }

    @Test(arguments: [true, false])
    func optionalExclusionKeepsBoundedLyricsWhenSelectorFails(invalidSelector: Bool) throws {
        let page = try LyricsHTMLPage("""
            <nav>Browse the catalog</nav><div id="lb-lyrics"><nav>More songs</nav>
            <p>First verse</p><button>Share this song</button><p>Second verse</p></div>
            <p>Unrelated body text</p>
            """)
        let region = try #require(page.textRegion(
            preferred: "#lb-lyrics", excluding: "nav, button",
            excludingInContainer: invalidSelector ? "[" : "header"
        ))

        #expect(region.isBounded)
        #expect(region.text.trimmingCharacters(in: .whitespacesAndNewlines) == "First verse\nSecond verse")
    }

    @Test
    func documentTitleStaysSeparateFromVisibleLyrics() throws {
        let page = try LyricsHTMLPage("""
            <html><head><title>Song &amp; Artist Lyrics</title>
            <meta property="og:title" content="Other metadata title"></head>
            <body><p>First verse<br>Second verse</p></body></html>
            """)

        #expect(page.documentTitle == "Song & Artist Lyrics")
        #expect(page.visibleText() == "First verse\nSecond verse\n")
        #expect(page.metadataTitles.contains("Other metadata title"))
    }

    @Test
    func tableCellFragmentsDecodeEntitiesAndIgnoreInertContent() throws {
        let text = try #require(LyricsHTMLPage.fragmentText("""
            <template><a>Wrong artist</a></template><script>Wrong artist</script><a href="/artist">Simon &amp; <b>Garfunkel</b></a>
            """, context: "Metal-Archives test cell"))

        #expect(text == "Simon & Garfunkel")
    }

    @Test
    func fragmentParsingNeverExposesDocumentTitles() throws {
        let text = try #require(LyricsHTMLPage.fragmentText("""
            <html><head><title>Access denied</title></head><body>(lyrics not available)</body></html>
            """, context: "full document returned for fragment"))

        #expect(text == "(lyrics not available)")
    }

    @Test(arguments: ["textarea", "title", "style", "xmp"])
    func rawTextElementsCannotOpenScripts(_ tag: String) throws {
        let payload = #"{"name":"Real recording"}"#
        let page = try LyricsHTMLPage(
            "<html><head></head><body><\(tag)><script id='__NEXT_DATA__' type='application/ld+json'>inert</script></\(tag)>" +
            "<p id='lyrics'>First verse<br>Second verse</p>" +
            "<script type='application/ld+json'>\(payload)</script></body></html>"
        )

        #expect(page.structuredData == [payload])
        #expect(page.scriptContent(withID: "__NEXT_DATA__").isEmpty)
        #expect(page.visibleText().contains("First verse\nSecond verse"))
        #expect(page.visibleText(in: "#lyrics") == "First verse\nSecond verse\n")
        if tag == "textarea" || tag == "xmp" {
            // Literal markup in these visible raw-text elements stays text.
            #expect(page.visibleText().contains("<script id='__NEXT_DATA__'"))
        }
    }

    @Test
    func quotedAnglesBelongToAttributeValues() throws {
        let canonical = "https://www.shazam.com/song/123/recording?label=A>B"
        let page = try LyricsHTMLPage("""
            <html><head>
            <meta property="og:title" content="A > B - Artist">
            <link data-note="A > B" rel="canonical" href="\(canonical)">
            <meta data-note="A > B" property="og:url" content="\(canonical)">
            </head><body><div title="<script id='__NEXT_DATA__'>inert</script>">Verse</div></body></html>
            """)

        #expect(page.metadataTitles == ["A > B - Artist"])
        #expect(page.identityURLReferences == [canonical, canonical])
        #expect(page.scriptContent(withID: "__NEXT_DATA__").isEmpty)
        #expect(page.visibleText() == "Verse\n")
    }

    @Test
    func inertMarkupCannotDeclarePageIdentity() throws {
        let page = try LyricsHTMLPage("""
            <html><head>
            <!-- <link rel="canonical" href="https://www.shazam.com/song/999/wrong"> -->
            <template><meta property="og:url" content="https://www.shazam.com/song/999/wrong"></template>
            <link rel="canonical" href="https://www.shazam.com/song/123/recording">
            </head><body><p>Visible verse</p></body></html>
            """)

        #expect(page.identityURLReferences == ["https://www.shazam.com/song/123/recording"])
        #expect(page.visibleText().contains("Visible verse"))
    }

    @Test(arguments: ["template", "noscript", "svg"])
    func lyricSelectionSkipsHiddenAncestors(_ tag: String) throws {
        let wrong = "<p id='lyrics'>Wrong verse</p>"
        // foreignObject keeps the paragraph inside SVG in the parsed HTML tree.
        let inert = tag == "svg" ? "<foreignObject>\(wrong)</foreignObject>" : wrong
        let page = try LyricsHTMLPage(
            "<html><body><\(tag)>\(inert)</\(tag)><p id='lyrics'>Real verse</p></body></html>"
        )

        #expect(page.visibleText(in: "#lyrics") == "Real verse\n")
        #expect(!page.visibleText().contains("Wrong verse"))
    }
}
