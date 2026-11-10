import Foundation
import Testing
@testable import FengluPlayer

struct HTMLProviderBoundaryTests {
    @Test(arguments: [true, false])
    func artistlessLyricsKeepPunctuationOnlyLines(bounded: Bool) throws {
        let track = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/artistless-boundary-fixture.flac"), title: "Snow On The Beach",
            artist: nil, album: nil, trackNumber: nil, duration: nil
        )
        let expected = ["...", "♪♪", ShazamEvidenceFixture.lyrics].joined(separator: "\n")
        let verses = expected.components(separatedBy: "\n").map { "<div>\($0)</div>" }.joined()
        let html = bounded ? "<div id='lb-lyrics'>\(verses)</div>" :
            "<h1>Snow On The Beach Lyrics</h1>\(verses)<div>Información de esta canción</div>"
        let page = try LyricsHTMLPage(html)

        // Artist-less tracks have no artist-page URL, so exercise extraction
        // directly rather than depending on a lookup the provider cannot make.
        #expect(LyricsOnlineResolver(track: track).letrasBoomLyricsString(in: page, track: track) == expected)
    }

    @Test(arguments: HTMLProviderBoundaryFixture.allCases)
    func excludesDocumentMetadataAndPageControls(_ fixture: HTMLProviderBoundaryFixture) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTMLProviderBoundaryProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Boundary-Fixture": fixture.rawValue]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let track = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/boundary-fixture.flac"), title: fixture.title,
            artist: "Taylor Swift", album: "Midnights", trackNumber: nil, duration: 256.13
        )

        let result = await LyricsOnlineResolver(track: track, session: session)
            .lyrics(for: track, sourceNames: [fixture.sourceName])
        if !fixture.shouldMatch {
            #expect(result == nil)
        } else {
            let resolution = try #require(result)
            #expect(resolution.rawLyrics == fixture.expectedLyrics)
        }
    }
}

enum HTMLProviderBoundaryFixture: String, CaseIterable, Sendable {
    case metalArchivesUnavailableDocument
    case metalArchivesUnavailableWithBanner
    case metalArchivesLyricsDocument
    case metalArchivesLyricsFragment
    case metalArchivesMultipartUnavailableMovement
    case metalArchivesAllMovementsUnavailable
    case metalArchivesDashHeadingsUnavailable
    case metalArchivesColonHeadingsUnavailable
    case metalArchivesPartHeadingsUnavailable
    case metalArchivesBareRomanHeadingsUnavailable
    case metalArchivesBareArabicHeadingsUnavailable
    case metalArchivesLowercaseHeadingsUnavailable
    case metalArchivesCompactHeadingsUnavailable
    case metalArchivesUppercasePartHeadingsUnavailable
    case metalArchivesInlineUnavailableMovement
    case metalArchivesInlineUnavailableMovementWithLyrics
    case metalArchivesInlineLabelsWithSparseLyrics
    case metalArchivesInlineLabelsWithFourLyricLines
    case metalArchivesPronounVersesAfterUnavailableMovement
    case metalArchivesLowercaseRomanLetterWords
    case metalArchivesThreeLineRemainder
    case metalArchivesFourLineRemainder
    case metalArchivesHeadingShapedVerses
    case metalArchivesOrphanedMovementsAroundLyrics
    case metalArchivesInstrumentalStageNote
    case metalArchivesInstrumentalInlineSingleVerse
    case metalArchivesStandaloneInstrumentalInterlude
    case metalArchivesInstrumentalOnlyMovements
    case metalArchivesLongInstrumentalOnlyMovements
    case metalArchivesInstrumentalThreeLineRemainder
    case metalArchivesInstrumentalFourLineRemainder
    case metalArchivesUnavailableBlocksKeepStanzaGap
    case metalArchivesStrayBracketUnavailable
    case metalArchivesStrayBracketWithLyrics
    case letrasBoomCancionTitleAndHeading
    case letrasBoomArtistaTitleAndHeading
    case letrasBoomTitleFallbackWithControls
    case letrasBoomBodyHeadingWithControls
    case letrasBoomTitleFallbackWithNavigationRole
    case letrasBoomTitleFallbackWithUnmarkedIntroOutsideContainer
    case letrasBoomTitleOnlyUnboundedIntro
    case letrasBoomCancionTitleFallbackContainer
    case letrasBoomFooterCannotRestartHeading
    case letrasBoomRecommendationCannotSupplyHeading
    case letrasBoomExcludedAncestorCannotSupplyContainer
    case letrasBoomContainerHeadingArtistAndFooter
    case letrasBoomContainerArtistLabelDoesNotTruncateVerses
    case letrasBoomHeaderHeadingLegacy
    case letrasBoomCancionFooterCannotRestartHeading
    case letrasBoomFooterCannotSupplyFirstHeading
    case letrasBoomContainerMetadataDoesNotTruncateVerses
    case letrasBoomContainerUsesPrecedingHeading
    case letrasBoomContainerNeedsNoHeading
    case letrasBoomContainerKeepsCancionVerse
    case letrasBoomContainerMetadataBeforeVerses
    case letrasBoomContainerKeepsFirstLyricsVerse
    case letrasBoomContainerKeepsMiddleLyricsVerse
    case letrasBoomContainerHeaderControls
    case letrasBoomLegacyDefinitionListFooter
    case letrasBoomLegacySplitLabelFooter

    var sourceName: String { rawValue.hasPrefix("metalArchives") ? "metalarchives" : "letrasboom" }
    var shouldMatch: Bool {
        ![.metalArchivesUnavailableDocument, .metalArchivesUnavailableWithBanner,
          .metalArchivesAllMovementsUnavailable, .metalArchivesInlineUnavailableMovement,
          .metalArchivesDashHeadingsUnavailable, .metalArchivesColonHeadingsUnavailable,
          .metalArchivesPartHeadingsUnavailable, .metalArchivesBareRomanHeadingsUnavailable,
          .metalArchivesBareArabicHeadingsUnavailable, .metalArchivesLowercaseHeadingsUnavailable,
          .metalArchivesCompactHeadingsUnavailable, .metalArchivesUppercasePartHeadingsUnavailable,
          .metalArchivesThreeLineRemainder, .metalArchivesStrayBracketUnavailable,
          .metalArchivesInlineLabelsWithSparseLyrics, .metalArchivesInstrumentalOnlyMovements,
          .metalArchivesLongInstrumentalOnlyMovements, .metalArchivesInstrumentalThreeLineRemainder,
          .letrasBoomTitleOnlyUnboundedIntro, .letrasBoomRecommendationCannotSupplyHeading,
          .letrasBoomFooterCannotSupplyFirstHeading].contains(self)
    }

    var expectedLyrics: String {
        var lines = ShazamEvidenceFixture.lyrics.components(separatedBy: "\n")
        switch self {
        case .metalArchivesInlineUnavailableMovementWithLyrics:
            lines.insert(contentsOf: ["III. Finale", "IV. Sunrise"], at: 0)
        case .metalArchivesInlineLabelsWithFourLyricLines:
            lines = ["I. Dawn", "II. Dusk", "III. Finale"] + Array(lines.prefix(4))
        case .metalArchivesPronounVersesAfterUnavailableMovement:
            lines = ["I hear the waves", "I see the stars", "I watch the dawn", "I find my way"]
        case .metalArchivesLowercaseRomanLetterWords:
            lines = ["vivid. The colors find the dawn", "civil. The voices find their home",
                     "vivid. The clouds cross the shore", "civil. The morning opens the door"]
        case .metalArchivesThreeLineRemainder:
            lines = Array(lines.prefix(3))
        case .metalArchivesFourLineRemainder:
            lines = Array(lines.prefix(4))
        case .metalArchivesHeadingShapedVerses:
            lines = ["I - I can't let go", "I: the one who stayed", "I", "10", "3", "2", "1"]
        case .metalArchivesOrphanedMovementsAroundLyrics:
            lines.insert(contentsOf: ["I. Dawn", "", "II. Dusk"], at: 0)
            lines.append("III. Finale")
        case .metalArchivesInstrumentalStageNote:
            lines.insert("Intro (instrumental)", at: 0)
        case .metalArchivesInstrumentalInlineSingleVerse:
            lines = ["A distant light (instrumental) keeps the night awake"]
        case .metalArchivesStandaloneInstrumentalInterlude:
            lines.insert(contentsOf: ["I. Interlude", "(instrumental)", "II. Dusk"], at: 0)
        case .metalArchivesInstrumentalThreeLineRemainder:
            lines = ["(instrumental)"] + Array(lines.prefix(3))
        case .metalArchivesInstrumentalFourLineRemainder:
            lines = ["(instrumental)"] + Array(lines.prefix(4))
        case .metalArchivesUnavailableBlocksKeepStanzaGap:
            lines.insert("", at: 3)
        case .metalArchivesStrayBracketWithLyrics:
            lines.insert("III. Finale :)", at: 0)
        case .letrasBoomContainerKeepsCancionVerse:
            lines[0] = "Canción del viento fills the evening air"
        case .letrasBoomContainerKeepsFirstLyricsVerse:
            lines[0] = "Snow On The Beach lyrics drift over the evening waves"
        case .letrasBoomContainerKeepsMiddleLyricsVerse:
            lines[3] = "Snow On The Beach lyrics drift over the evening waves"
        default: break
        }
        return lines.joined(separator: "\n")
    }

    var title: String {
        switch self {
        case .letrasBoomCancionTitleAndHeading, .letrasBoomCancionTitleFallbackContainer: "Canción del Mar"
        case .letrasBoomArtistaTitleAndHeading: "Artista de la Noche"
        default: "Snow On The Beach"
        }
    }

    var songPath: String {
        let slug = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().replacingOccurrences(of: " ", with: "-")
        return "/letra/taylor-swift/\(slug)"
    }

    var html: String {
        let verses = expectedLyrics.components(separatedBy: "\n")
            .map { "<div>\($0)</div>" }.joined()
        if self == .metalArchivesUnavailableDocument {
            return "<html><head><title>Access denied</title></head><body>(lyrics not available)</body></html>"
        }
        if self == .metalArchivesUnavailableWithBanner {
            return "<html><head><title>Service notice</title></head><body><div>Please return later while our service is temporarily unavailable</div><div>(lyrics not available)</div></body></html>"
        }
        if self == .metalArchivesLyricsDocument {
            return "<html><head><title>Metal Archives song details</title></head><body>\(verses)</body></html>"
        }
        if self == .metalArchivesLyricsFragment { return verses }
        if self == .metalArchivesMultipartUnavailableMovement {
            return "<html><head><title>Multi-part song</title></head><body><section><p>(lyrics not available)</p></section><section>\(verses)</section></body></html>"
        }
        if self == .metalArchivesAllMovementsUnavailable {
            // Keep enough heading text to pass the generic minimum length, so
            // the unavailable-content minimum must reject this response.
            return "<h2>I. Dawn</h2><p>(lyrics not available)</p><h2>II. Dusk</h2><p>(lyrics not available)</p><h2>III. Finale</h2><p>(lyrics not available)</p>"
        }
        let unavailableHeadings: [String]?
        switch self {
        case .metalArchivesDashHeadingsUnavailable:
            unavailableHeadings = ["I - Dawn", "II – Dusk", "III — Finale"]
        case .metalArchivesColonHeadingsUnavailable:
            unavailableHeadings = ["I: Dawn", "II: Dusk", "III: Finale"]
        case .metalArchivesPartHeadingsUnavailable:
            unavailableHeadings = ["Part I", "Part II", "Part III"]
        case .metalArchivesBareRomanHeadingsUnavailable:
            unavailableHeadings = ["I.", "II.", "III.", "IV", "V", "VI", "VII", "VIII"]
        case .metalArchivesBareArabicHeadingsUnavailable:
            unavailableHeadings = ["1.", "2.", "3.", "4", "5", "6", "7", "8", "9", "10"]
        case .metalArchivesLowercaseHeadingsUnavailable:
            unavailableHeadings = ["i. Dawn", "ii. Dusk", "iii. Finale"]
        case .metalArchivesCompactHeadingsUnavailable:
            unavailableHeadings = ["1.Intro", "I.Dawn", "II.Dusk"]
        case .metalArchivesUppercasePartHeadingsUnavailable:
            unavailableHeadings = ["PART I", "PART II", "PART III"]
        default: unavailableHeadings = nil
        }
        if let unavailableHeadings {
            return unavailableHeadings.map { "<h2>\($0)</h2><p>(lyrics not available)</p>" }.joined()
        }
        if self == .metalArchivesInlineUnavailableMovement {
            return "<p>III. Finale (lyrics not available)</p>"
        }
        if self == .metalArchivesInlineUnavailableMovementWithLyrics {
            let availableVerses = ShazamEvidenceFixture.lyrics.components(separatedBy: "\n")
                .map { "<div>\($0)</div>" }.joined()
            return "<p>III. Finale (lyrics not available)</p><h2>IV. Sunrise</h2>\(availableVerses)"
        }
        if self == .metalArchivesInlineLabelsWithSparseLyrics || self == .metalArchivesInlineLabelsWithFourLyricLines {
            let unavailableLabels = ["I. Dawn", "II. Dusk", "III. Finale"]
                .map { "<p>\($0) (lyrics not available)</p>" }.joined()
            let realLines = ShazamEvidenceFixture.lyrics.components(separatedBy: "\n")
            if self == .metalArchivesInlineLabelsWithSparseLyrics {
                return unavailableLabels + "<h2>IV. Sunrise</h2><p>\(realLines[0])</p>"
            }
            return unavailableLabels + realLines.prefix(4).map { "<p>\($0)</p>" }.joined()
        }
        if [.metalArchivesPronounVersesAfterUnavailableMovement, .metalArchivesLowercaseRomanLetterWords,
            .metalArchivesThreeLineRemainder, .metalArchivesFourLineRemainder,
            .metalArchivesHeadingShapedVerses].contains(self) {
            return "<p>(lyrics not available)</p>\(verses)"
        }
        if self == .metalArchivesOrphanedMovementsAroundLyrics {
            let availableVerses = ShazamEvidenceFixture.lyrics.components(separatedBy: "\n")
                .map { "<div>\($0)</div>" }.joined()
            return "<h2>I. Dawn</h2><p>(lyrics not available)</p><h2>II. Dusk</h2>\(availableVerses)<h2>III. Finale</h2><p>(lyrics not available)</p>"
        }
        if [.metalArchivesInstrumentalStageNote, .metalArchivesInstrumentalInlineSingleVerse,
            .metalArchivesStandaloneInstrumentalInterlude, .metalArchivesInstrumentalThreeLineRemainder,
            .metalArchivesInstrumentalFourLineRemainder].contains(self) {
            return verses
        }
        if self == .metalArchivesInstrumentalOnlyMovements || self == .metalArchivesLongInstrumentalOnlyMovements {
            let count = self == .metalArchivesInstrumentalOnlyMovements ? 3 : 8
            return (1...count).map { "<h2>Part \($0) - Interlude</h2><p>(instrumental)</p>" }.joined()
        }
        if self == .metalArchivesUnavailableBlocksKeepStanzaGap {
            let realLines = ShazamEvidenceFixture.lyrics.components(separatedBy: "\n")
            let firstStanza = realLines.prefix(3).map { "<p>\($0)</p>" }.joined()
            let secondStanza = realLines.dropFirst(3).map { "<p>\($0)</p>" }.joined()
            return firstStanza + "<br><p>(lyrics not available)</p><br><p>(lyrics not available)</p><br>" + secondStanza
        }
        if self == .metalArchivesStrayBracketUnavailable {
            return "<p>III. Finale :) (lyrics not available)</p>"
        }
        if self == .metalArchivesStrayBracketWithLyrics {
            let availableVerses = ShazamEvidenceFixture.lyrics.components(separatedBy: "\n")
                .map { "<div>\($0)</div>" }.joined()
            return "<p>III. Finale :) (lyrics not available)</p>\(availableVerses)"
        }

        let heading = "\(title) - Taylor Swift Lyrics"
        let documentTitle = [.letrasBoomContainerUsesPrecedingHeading, .letrasBoomContainerNeedsNoHeading].contains(self)
            ? "\(title) - Taylor Swift" : heading
        let headingLikeFooter = "<div>Canción: \(heading)</div><div>\(ShazamEvidenceFixture.wrongLyrics)</div>"
        let verseLines = expectedLyrics.components(separatedBy: "\n")
        let earlyVerses = verseLines.prefix(3).map { "<div>\($0)</div>" }.joined()
        let laterVerses = verseLines.dropFirst(3).map { "<div>\($0)</div>" }.joined()
        let specialBody: String?
        switch self {
        case .letrasBoomContainerHeadingArtistAndFooter:
            // The captured site keeps the information/recommendation area
            // outside its lyric container. Only credit lines remain inside.
            specialBody = "<div id='lb-lyrics'><h2>\(heading)</h2><div>Taylor Swift</div><div>Artista: Taylor Swift</div>\(verses)</div><div>Información de Taylor Swift</div><div>\(ShazamEvidenceFixture.wrongLyrics)</div>"
        case .letrasBoomContainerArtistLabelDoesNotTruncateVerses:
            specialBody = "<div id='lb-lyrics'><h2>\(heading)</h2>\(earlyVerses)<div>Artista: Taylor Swift</div>\(laterVerses)</div><div>\(ShazamEvidenceFixture.wrongLyrics)</div>"
        case .letrasBoomHeaderHeadingLegacy:
            specialBody = "<header><nav>Browse the catalog</nav><h1>\(heading)</h1><div>Share this song with your friends</div></header>\(verses)<div>Información de Taylor Swift</div>"
        case .letrasBoomCancionFooterCannotRestartHeading:
            specialBody = "<h1>\(heading)</h1>\(verses)\(headingLikeFooter)<div>Información de Taylor Swift</div>"
        case .letrasBoomFooterCannotSupplyFirstHeading:
            specialBody = "<div>Browse the catalog</div>\(headingLikeFooter)<div>Información de Taylor Swift</div>"
        case .letrasBoomContainerMetadataDoesNotTruncateVerses:
            specialBody = "<div id='lb-lyrics'><h2>\(heading)</h2>\(earlyVerses)<div>Canción: \(heading)</div>\(laterVerses)</div>\(headingLikeFooter)"
        case .letrasBoomContainerUsesPrecedingHeading:
            specialBody = "<header><h1>\(heading)</h1></header><div id='lb-lyrics'>\(verses)</div><div>Información de Taylor Swift</div>"
        case .letrasBoomContainerNeedsNoHeading:
            specialBody = "<div id='lb-lyrics'>\(verses)</div><div>Información de Taylor Swift</div><h1>\(heading)</h1>"
        case .letrasBoomContainerKeepsCancionVerse, .letrasBoomContainerKeepsFirstLyricsVerse,
             .letrasBoomContainerKeepsMiddleLyricsVerse:
            specialBody = "<div id='lb-lyrics'>\(verses)</div><div>Información de Taylor Swift</div>"
        case .letrasBoomContainerMetadataBeforeVerses:
            specialBody = "<div id='lb-lyrics'><div>Artista: Taylor Swift feat. Lana Del Rey</div><div>Visitas: 1234</div>\(verses)</div><div>Información de Taylor Swift</div>"
        case .letrasBoomContainerHeaderControls:
            specialBody = "<div id='lb-lyrics'><header><h2>\(heading)</h2><p>Share this song with your friends</p></header>\(verses)</div><div>Información de Taylor Swift</div>"
        case .letrasBoomLegacyDefinitionListFooter:
            specialBody = "<h1>\(heading)</h1>\(verses)<dl><dt>Artista</dt><dd>Taylor Swift</dd><dt>Canción</dt><dd>\(title)</dd></dl><div>\(ShazamEvidenceFixture.wrongLyrics)</div>"
        case .letrasBoomLegacySplitLabelFooter:
            specialBody = "<h1>\(heading)</h1>\(verses)<div>Visitas</div><div>1234</div><div>\(ShazamEvidenceFixture.wrongLyrics)</div>"
        default:
            specialBody = nil
        }
        if let specialBody {
            return "<html><head><title>\(documentTitle)</title></head><body>\(specialBody)</body></html>"
        }
        let bodyHeading: String
        switch self {
        case .letrasBoomCancionTitleAndHeading, .letrasBoomArtistaTitleAndHeading,
             .letrasBoomBodyHeadingWithControls, .letrasBoomFooterCannotRestartHeading:
            bodyHeading = "<h1>\(heading)</h1>"
        default: bodyHeading = ""
        }
        let controls: String
        switch self {
        case .letrasBoomTitleFallbackWithControls, .letrasBoomBodyHeadingWithControls:
            controls = "<header>Browse our collection</header><nav><a>Artists</a><a>Songs</a></nav><button>Share this song</button>"
        case .letrasBoomTitleFallbackWithNavigationRole:
            controls = "<div role='navigation'><a>Browse artists</a><a>Share with friends</a></div>"
        case .letrasBoomTitleFallbackWithUnmarkedIntroOutsideContainer, .letrasBoomTitleOnlyUnboundedIntro:
            controls = "<div>Browse our collection and share this song with friends</div>"
        case .letrasBoomExcludedAncestorCannotSupplyContainer:
            controls = "<nav><div id='lb-lyrics'>\(ShazamEvidenceFixture.wrongLyrics)</div></nav><div class='lb-noprint'><div id='lb-lyrics'>\(ShazamEvidenceFixture.wrongLyrics)</div></div>"
        default: controls = ""
        }
        let lyricContent: String
        switch self {
        case .letrasBoomTitleFallbackWithControls, .letrasBoomTitleFallbackWithNavigationRole,
             .letrasBoomTitleFallbackWithUnmarkedIntroOutsideContainer, .letrasBoomCancionTitleFallbackContainer,
             .letrasBoomExcludedAncestorCannotSupplyContainer:
            // Use the actual site's lyric container and ad-slot classes. Text
            // elsewhere on the page must not become lyrics via the title anchor.
            lyricContent = "<div class='lb-lyrics lyricbody' id='lb-lyrics' data-lb-lyrics><div class='lb-noprint'>Share with friends</div>\(verses)<div class='lb-adslot'>Sponsored content</div></div>"
        default:
            lyricContent = verses
        }
        let recommendations = [.letrasBoomFooterCannotRestartHeading, .letrasBoomRecommendationCannotSupplyHeading].contains(self)
            ? "<h2>\(heading)</h2><div>\(ShazamEvidenceFixture.wrongLyrics)</div>" : ""
        return "<html><head><title>\(heading)</title></head><body>\(controls)\(bodyHeading)\(lyricContent)<div>Información de Taylor Swift</div><p>Unrelated footer content</p>\(recommendations)</body></html>"
    }
}

private final class HTMLProviderBoundaryProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let value = request.value(forHTTPHeaderField: "X-Boundary-Fixture"),
              let fixture = HTMLProviderBoundaryFixture(rawValue: value),
              ["www.metal-archives.com", "www.letrasboom.com"].contains(url.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let body: Data
        if url.host == "www.metal-archives.com", url.path.hasPrefix("/search/") {
            let row = ["<a>Taylor <b>Swift</b></a>", "<a>Midnights</a>", "Album", fixture.title, "<a id='lyricsLink_42'>Lyrics</a>"]
            body = try! JSONSerialization.data(withJSONObject: ["aaData": [row]])
        } else if url.host == "www.letrasboom.com", url.path.hasPrefix("/artista/") {
            body = Data("<a href='\(fixture.songPath)'>\(fixture.title)</a>".utf8)
        } else {
            body = Data(fixture.html.utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
