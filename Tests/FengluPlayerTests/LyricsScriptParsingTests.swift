import Foundation
import Testing
@testable import FengluPlayer

struct LyricsScriptParsingTests {
    @Test(arguments: LyricsScriptFixture.allCases)
    func sharesScriptBoundariesAcrossHTMLProviders(_ fixture: LyricsScriptFixture) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LyricsScriptProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Script-Fixture": fixture.rawValue]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let track = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/script-fixture.flac"),
            title: "Snow On The Beach", artist: "Taylor Swift", album: fixture.sourceName == "darklyrics" ? "Midnights" : nil,
            trackNumber: nil, duration: 256.13
        )
        let result = await LyricsOnlineResolver(track: track, session: session)
            .lyrics(for: track, sourceNames: [fixture.sourceName])
        if !fixture.shouldMatch {
            #expect(result == nil)
        } else {
            let resolution = try #require(result)
            #expect(resolution.rawLyrics == ShazamEvidenceFixture.lyrics)
        }
    }
}

enum LyricsScriptFixture: String, CaseIterable, Sendable {
    case lyricFindQuotedAngleBeforeID
    case lyricFindQuotedFakeIDIsInert
    case lyricFindSpacedClosingTag
    case lyricFindTemplateScriptIsInert
    case lyricFindCommentedScriptIsInert
    case lyricFindEmptyComment
    case lyricFindEmptyDashComment
    case lyricFindDoubleEscapedScriptIsInert
    case lyricFindSlashIntroducedID
    case lyricFindMinifiedID
    case lyricFindClosingAttributes
    case lyricFindClosingSolidus
    case lyricFindIDIsCaseSensitive
    case lyricFindUnclosedScriptAtEOF
    case lyricFindTruncatedScriptAtEOF
    case lyricFindMalformedAttributeHidesScript
    case lyricFindBodyFallbackExcludesTitle
    case songLyricsQuotedAngleAndSpacedClosing
    case songLyricsScriptOnly
    case songLyricsStyleContainingScript
    case songLyricsEmptyComment
    case songLyricsEmptyDashComment
    case songLyricsDoubleEscapedScript
    case songLyricsTemplateContainerIsInert
    case songLyricsNoScriptContainerIsInert
    case songLyricsSVGContainerIsInert
    case azLyricsCommentAndNestedVerses
    case darkLyricsSelectsSecondSection
    case lyricsifyNestedContainer
    case letrasNestedContainer
    case bandcampNestedContainer
    case letrasBoomTitleOnlyAnchor
    case letrasBoomBodyHeadingOverridesTitleAnchor
    case letrasBoomMissingTitleAnchor
    case letrasBoomWrongTitleAnchor
    case letrasBoomTitleWithoutLyricsMarker

    var sourceName: String {
        switch self {
        case .azLyricsCommentAndNestedVerses: "azlyrics"
        case .darkLyricsSelectsSecondSection: "darklyrics"
        case .lyricsifyNestedContainer: "lyricsify"
        case .letrasNestedContainer: "letras"
        case .bandcampNestedContainer: "bandcamp"
        case .letrasBoomTitleOnlyAnchor, .letrasBoomBodyHeadingOverridesTitleAnchor,
             .letrasBoomMissingTitleAnchor, .letrasBoomWrongTitleAnchor,
             .letrasBoomTitleWithoutLyricsMarker: "letrasboom"
        default: rawValue.hasPrefix("songLyrics") ? "songlyrics" : "lyricfind"
        }
    }

    var shouldMatch: Bool {
        ![.songLyricsScriptOnly, .lyricFindIDIsCaseSensitive,
          .lyricFindMalformedAttributeHidesScript, .lyricFindTruncatedScriptAtEOF,
          .letrasBoomMissingTitleAnchor, .letrasBoomWrongTitleAnchor,
          .letrasBoomTitleWithoutLyricsMarker].contains(self)
    }

    var html: String {
        let heading = "<title>Snow On The Beach - Taylor Swift Lyrics</title>"
        if sourceName == "letrasboom" || self == .lyricFindBodyFallbackExcludesTitle {
            let verses = ShazamEvidenceFixture.lyrics.components(separatedBy: "\n")
                .map { "<div>\($0)</div>" }.joined()
            if self == .lyricFindBodyFallbackExcludesTitle {
                return "<html><head>\(heading)</head><body><main>\(verses)</main></body></html>"
            }
            let pageHeading: String
            switch self {
            case .letrasBoomMissingTitleAnchor:
                // Metadata validation may succeed, but og:title never supplied
                // the old visible-text start anchor and must not create one now.
                pageHeading = "<meta property='og:title' content='Snow On The Beach - Taylor Swift Lyrics'>"
            case .letrasBoomWrongTitleAnchor:
                pageHeading = "<title>Other Song - Other Artist Lyrics</title>"
            case .letrasBoomTitleWithoutLyricsMarker:
                pageHeading = "<title>Snow On The Beach - Taylor Swift</title>"
            default: pageHeading = heading
            }
            let prefix = self == .letrasBoomBodyHeadingOverridesTitleAnchor
                ? "<nav>Browse this catalog</nav><h1>Snow On The Beach - Taylor Swift Lyrics</h1>"
                : ""
            let lyricContent = self == .letrasBoomTitleOnlyAnchor
                ? "<div class='lb-lyrics lyricbody' id='lb-lyrics' data-lb-lyrics>\(verses)</div>"
                : verses
            return "<html><head>\(pageHeading)</head><body>\(prefix)\(lyricContent)<div>Información de Taylor Swift</div><p>Unrelated footer content</p></body></html>"
        }
        if !["songlyrics", "lyricfind"].contains(sourceName) {
            let verses = ShazamEvidenceFixture.lyrics.components(separatedBy: "\n")
                .map { "<div><span>\($0)</span></div>" }.joined()
            let wrong = ShazamEvidenceFixture.wrongLyrics.components(separatedBy: "\n")
                .map { "<div>\($0)</div>" }.joined()
            let body: String
            switch self {
            case .azLyricsCommentAndNestedVerses:
                let marker = "<!-- Usage of azlyrics.com content by any third-party lyrics provider is prohibited by our licensing agreement. Sorry about that. -->"
                body = "<template><div>\(marker)\(wrong)</div></template><main><div><p>Navigation before the marker</p>\(marker)\(verses)</div><aside>\(wrong)</aside></main>"
            case .darkLyricsSelectsSecondSection:
                body = "<div class='lyrics'><h3>1. Other Song</h3>\(wrong)<h3>2. Snow On The Beach</h3>\(verses)</div><aside>\(wrong)</aside>"
            case .lyricsifyNestedContainer:
                body = "<div id='lyrics_song_details'>\(verses)</div><aside>\(wrong)</aside>"
            case .letrasNestedContainer:
                body = "<div class='content lyric-original'>\(verses)</div><aside>\(wrong)</aside>"
            case .bandcampNestedContainer:
                body = "<div class='content lyricsText'>\(verses)</div><aside>\(wrong)</aside>"
            default: preconditionFailure("Other providers handled below")
            }
            return "<html><head>\(heading)</head><body>\(body)</body></html>"
        }
        if sourceName == "songlyrics" {
            let hidden = ShazamEvidenceFixture.wrongLyrics.components(separatedBy: "\n").joined(separator: "<br>")
            let verses = self == .songLyricsScriptOnly ? ""
                : ShazamEvidenceFixture.lyrics.components(separatedBy: "\n").joined(separator: "<br>")
            let inertContainer = "<p id='songLyricsDiv'>\(hidden)</p>"
            let containerPrefix: String
            switch self {
            case .songLyricsTemplateContainerIsInert:
                containerPrefix = "<template>\(inertContainer)</template>"
            case .songLyricsNoScriptContainerIsInert:
                containerPrefix = "<noscript>\(inertContainer)</noscript>"
            case .songLyricsSVGContainerIsInert:
                containerPrefix = "<svg><foreignObject>\(inertContainer)</foreignObject></svg>"
            default: containerPrefix = ""
            }
            let prefix: String
            switch self {
            case .songLyricsStyleContainingScript:
                prefix = "<style>/* <script>\(hidden) */</style>"
            case .songLyricsEmptyComment: prefix = "<!-->"
            case .songLyricsEmptyDashComment: prefix = "<!--->"
            case .songLyricsDoubleEscapedScript:
                prefix = "<script><!-- <script>\(hidden)</script> //--></script>"
            default: prefix = "<script data-note='a > b'>\(hidden)</script >"
            }
            return "<html><head>\(heading)</head><body>\(containerPrefix)<p id='songLyricsDiv'>\(prefix)\(verses)</p></body></html>"
        }
        func nextData(_ lyrics: String) -> String {
            let object: [String: Any] = ["props": ["pageProps": ["songData": ["track": ["lyrics": lyrics]]]]]
            return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        let target = nextData(ShazamEvidenceFixture.lyrics)
        let wrong = "<script id='__NEXT_DATA__' type='application/json'>\(nextData(ShazamEvidenceFixture.wrongLyrics))</script>"
        let scripts: String
        switch self {
        case .lyricFindQuotedAngleBeforeID:
            scripts = "<script data-note='a > b' id='__NEXT_DATA__' type='application/json'>\(target)</script>"
        case .lyricFindQuotedFakeIDIsInert:
            scripts = "<script data-note='a > id=\"__NEXT_DATA__\"' type='application/json'>\(nextData(ShazamEvidenceFixture.wrongLyrics))</script><script id='__NEXT_DATA__'>\(target)</script>"
        case .lyricFindSpacedClosingTag:
            scripts = "<script id='__NEXT_DATA__' type='application/json'>\(target)</script >"
        case .lyricFindTemplateScriptIsInert:
            scripts = "<script type='text/template'>\(wrong)</script><script id='__NEXT_DATA__'>\(target)</script>"
        case .lyricFindCommentedScriptIsInert:
            scripts = "<!-- \(wrong) --><script id='__NEXT_DATA__'>\(target)</script>"
        case .lyricFindEmptyComment:
            scripts = "<!--><script id='__NEXT_DATA__'>\(target)</script>"
        case .lyricFindEmptyDashComment:
            scripts = "<!---><script id='__NEXT_DATA__'>\(target)</script>"
        case .lyricFindDoubleEscapedScriptIsInert:
            scripts = "<script><!-- <script>inner</script>\(wrong) //--></script><script id='__NEXT_DATA__'>\(target)</script>"
        case .lyricFindSlashIntroducedID:
            scripts = "<script/id='__NEXT_DATA__'/type='application/json'>\(target)</script>"
        case .lyricFindMinifiedID:
            scripts = "<script type='application/json'id='__NEXT_DATA__'>\(target)</script>"
        case .lyricFindClosingAttributes:
            scripts = "<script id='__NEXT_DATA__'>\(target)</script foo=1>"
        case .lyricFindClosingSolidus:
            scripts = "<script id='__NEXT_DATA__'>\(target)</script/>"
        case .lyricFindIDIsCaseSensitive:
            scripts = "<script id='__next_data__'>\(target)</script>"
        case .lyricFindUnclosedScriptAtEOF:
            // The DOM retains an actual script's raw body at EOF. Only a complete
            // JSON payload can supply lyrics; no enclosing page tail is appended.
            return "<html><head>\(heading)<script id='__NEXT_DATA__'>\(target)"
        case .lyricFindTruncatedScriptAtEOF:
            return "<html><head>\(heading)<script id='__NEXT_DATA__'>\(target.dropLast())"
        case .lyricFindMalformedAttributeHidesScript:
            scripts = "<div class=\"x><script id=\"__NEXT_DATA__\">\(target)</script>"
        default:
            preconditionFailure("SongLyrics cases handled above")
        }
        return "<html><head>\(heading)\(scripts)</head><body></body></html>"
    }
}

private final class LyricsScriptProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let value = request.value(forHTTPHeaderField: "X-Script-Fixture"),
              let fixture = LyricsScriptFixture(rawValue: value),
              ["lyrics.lyricfind.com", "songlyrics.com", "www.songlyrics.com", "www.azlyrics.com",
               "darklyrics.com", "www.lyricsify.com", "www.letras.com", "taylorswift.bandcamp.com",
               "www.letrasboom.com"].contains(url.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let html = fixture.sourceName == "letrasboom" && url.path.hasPrefix("/artista/")
            ? "<a href='/letra/taylor-swift/snow-on-the-beach'>Snow On The Beach</a>"
            : fixture.html
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
