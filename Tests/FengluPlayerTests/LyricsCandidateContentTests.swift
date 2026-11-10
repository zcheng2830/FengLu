import Foundation
import Testing
@testable import FengluPlayer

struct LyricsCandidateContentTests {
    @Test(arguments: CandidateContentFixture.allCases)
    func validatesContentAcrossProviders(_ fixture: CandidateContentFixture) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CandidateContentProtocol.self]
        configuration.httpAdditionalHeaders = [
            "X-Candidate-Provider": fixture.provider.rawValue,
            "X-Candidate-Content": fixture.content.rawValue
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let track = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/shared-candidate-content.flac"),
            title: "Snow On The Beach", artist: "Taylor Swift", album: "Midnights",
            trackNumber: nil, duration: 50
        )

        let result = await LyricsOnlineResolver(track: track, session: session)
            .lyrics(for: track, sourceNames: [fixture.provider.rawValue])
        guard let expected = fixture.content.expectedLyrics else {
            #expect(result == nil)
            return
        }
        let resolution = try #require(result)
        #expect(resolution.rawLyrics == expected)
        if fixture.content == .unmatchedBracketVerse {
            #expect(resolution.document.plainText.contains("[Oh baby, I told you [twice] go home"))
        }
        if fixture.content == .sectionHeadersWithVerses {
            #expect(resolution.document.plainText == CandidateContent.verses.joined(separator: "\n"))
            #expect(LyricsParser.contentLineCount(resolution.rawLyrics) == CandidateContent.verses.count)
        }
        if fixture.content == .timedPartial {
            #expect(resolution.document.isSynchronized)
            let lines = resolution.document.lines.filter { !$0.text.isEmpty }
            // [offset:500]: a positive offset shows the lyrics half a second earlier.
            #expect(lines.compactMap(\.time) == [9.5, 19.5, 24.5, 29.5, 39.5])
            #expect(lines.map(\.text) == [
                CandidateContent.verses[0], CandidateContent.verses[1], "Bridge",
                CandidateContent.verses[2], CandidateContent.verses[3]
            ])
        }
    }
}

enum CandidateContentProvider: String, Sendable {
    case letrasboom
    case songlyrics
    case bandcamp
    case genius
    case lrclib = "lrclib-exact"
}

struct CandidateContentFixture: Sendable {
    let provider: CandidateContentProvider
    let content: CandidateContent

    static let allCases: [Self] = {
        let htmlContent: [CandidateContent] = [
            .unavailableLabels, .partialLyrics, .instrumentalLabels,
            .taggedInstrumentalLabels, .taggedPartial,
            .bracketedUnavailableLabels, .bracketedInstrumentalLabels,
            .literalHTMLEntities, .unmatchedBracketVerse,
            .markerInsideUnmatchedBracket, .markerBeyondDepthLimit,
            .sectionHeadersOnly, .sectionHeadersWithUnavailable, .sectionHeadersWithVerses
        ]
        let htmlProviders: [CandidateContentProvider] = [.letrasboom, .songlyrics]
        return htmlProviders.flatMap { provider in
            htmlContent.map { Self(provider: provider, content: $0) }
        } + [
            Self(provider: .lrclib, content: .timedPartial),
            Self(provider: .lrclib, content: .timedInstrumentalLabels),
            Self(provider: .lrclib, content: .literalJSONEntities),
            Self(provider: .bandcamp, content: .literalHTMLEntities),
            Self(provider: .genius, content: .literalHTMLEntities)
        ]
    }()
}

enum CandidateContent: String, Sendable {
    case unavailableLabels
    case partialLyrics
    case instrumentalLabels
    case taggedInstrumentalLabels
    case taggedPartial
    case bracketedUnavailableLabels
    case bracketedInstrumentalLabels
    case timedPartial
    case timedInstrumentalLabels
    case literalHTMLEntities
    case literalJSONEntities
    case unmatchedBracketVerse
    case markerInsideUnmatchedBracket
    case markerBeyondDepthLimit
    case sectionHeadersOnly
    case sectionHeadersWithUnavailable
    case sectionHeadersWithVerses

    static let verses = [
        "A quiet river follows the morning light",
        "The distant hills return a silver sound",
        "Our paper boats drift slowly out of sight",
        "Another dawn brings every traveler round"
    ]

    static let sectionHeaders = ["[Verse 1]", "[Chorus 2]", "[Verse 1: Taylor Swift]", "[Outro 4]"]

    var inputLines: [String] {
        switch self {
        case .unavailableLabels:
            return ["I. Dawn", "II. Dusk", "III. Finale"].flatMap { [$0, "(lyrics not available)"] }
        case .partialLyrics:
            return ["III. Finale (lyrics not available)"] + Self.verses
        case .instrumentalLabels, .taggedInstrumentalLabels:
            let note = self == .taggedInstrumentalLabels ? "[Interlude] (instrumental)" : "(instrumental)"
            return ["I. Dawn", "II. Dusk", "III. Finale"].flatMap { [$0, note] }
        case .bracketedUnavailableLabels, .bracketedInstrumentalLabels:
            let note = self == .bracketedUnavailableLabels ? "[no lyrics]" : "[instrumental]"
            return ["I. Dawn", "II. Dusk", "III. Finale"].flatMap { [$0, note] }
        case .taggedPartial:
            return ["[Bridge] III. Finale (lyrics not available)"] + [
                "[Verse] \(Self.verses[0])", "[Verse]\(Self.verses[1])",
                "[Chorus] \(Self.verses[2])", Self.verses[3]
            ]
        case .timedPartial:
            return [
                "[ar:Taylor Swift]", "[ti:Snow On The Beach]", "[al:(lyrics not available)]", "[offset:500]",
                "[00:10.00]\(Self.verses[0])", "[00:20.00]\(Self.verses[1])",
                "[00:25.00]Bridge (lyrics not available)",
                "[00:30.00]\(Self.verses[2])", "[00:40.00]\(Self.verses[3])"
            ]
        case .timedInstrumentalLabels:
            return [
                "[00:01.00]I. Dawn", "[00:02.00][Interlude] (instrumental)",
                "[00:03.00]II. Dusk", "[00:04.00][Interlude] (instrumental)",
                "[00:05.00]III. Finale", "[00:06.00][Interlude] (instrumental)"
            ]
        case .literalHTMLEntities:
            // These are HTML source strings, intentionally escaped twice. The
            // DOM removes one layer; the remaining entity notation is lyric text.
            return [
                "First &amp;amp; second follow the quiet river",
                "A &amp;quot;word&amp;quot; waits in the morning light",
                "Write &amp;#39; beside the distant silver sound",
                Self.verses[3]
            ]
        case .literalJSONEntities:
            // JSON strings have no HTML entity layer to decode.
            return [
                "[00:10.00]First &amp; second follow the quiet river",
                "[00:20.00]A &quot;word&quot; waits in the morning light",
                "[00:30.00]Write &#39; beside the distant silver sound",
                "[00:40.00]\(Self.verses[3])"
            ]
        case .unmatchedBracketVerse:
            return ["(lyrics not available)", "[Oh baby, I told you [twice] go home"] + Array(Self.verses.prefix(3))
        case .markerInsideUnmatchedBracket:
            return ["[Oh baby (lyrics not available) [twice] go home"] + Array(Self.verses.prefix(3))
        case .markerBeyondDepthLimit:
            return [String(repeating: "(", count: 40) + "tail (lyrics not available)"] + Array(Self.verses.prefix(3))
        case .sectionHeadersOnly:
            return Self.sectionHeaders
        case .sectionHeadersWithUnavailable:
            return Self.sectionHeaders + ["(lyrics not available)"]
        case .sectionHeadersWithVerses:
            return ["[tool:LRC Editor Pro]", "[#:transcribed by fan club]"] +
                zip(Self.sectionHeaders, Self.verses).flatMap { [$0, $1] }
        }
    }

    var expectedLyrics: String? {
        switch self {
        case .partialLyrics:
            return (["III. Finale"] + Self.verses).joined(separator: "\n")
        case .taggedPartial:
            return (["[Bridge] III. Finale"] + [
                "[Verse] \(Self.verses[0])", "[Verse]\(Self.verses[1])",
                "[Chorus] \(Self.verses[2])", Self.verses[3]
            ]).joined(separator: "\n")
        case .timedPartial:
            return [
                "[ar:Taylor Swift]", "[ti:Snow On The Beach]", "[al:(lyrics not available)]", "[offset:500]",
                "[00:10.00]\(Self.verses[0])", "[00:20.00]\(Self.verses[1])",
                "[00:25.00]Bridge",
                "[00:30.00]\(Self.verses[2])", "[00:40.00]\(Self.verses[3])"
            ].joined(separator: "\n")
        case .literalHTMLEntities:
            return [
                "First &amp; second follow the quiet river",
                "A &quot;word&quot; waits in the morning light",
                "Write &#39; beside the distant silver sound",
                Self.verses[3]
            ].joined(separator: "\n")
        case .literalJSONEntities:
            return inputLines.joined(separator: "\n")
        case .sectionHeadersWithVerses:
            return inputLines.joined(separator: "\n")
        case .unmatchedBracketVerse:
            return (["[Oh baby, I told you [twice] go home"] + Array(Self.verses.prefix(3))).joined(separator: "\n")
        default:
            return nil
        }
    }
}

private final class CandidateContentProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let providerValue = request.value(forHTTPHeaderField: "X-Candidate-Provider"),
              let provider = CandidateContentProvider(rawValue: providerValue),
              let contentValue = request.value(forHTTPHeaderField: "X-Candidate-Content"),
              let content = CandidateContent(rawValue: contentValue) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let body: Data
        switch provider {
        case .lrclib:
            guard url.host == "lrclib.net" else { return failRequest() }
            body = try! JSONSerialization.data(withJSONObject: [
                "trackName": "Snow On The Beach", "artistName": "Taylor Swift",
                "albumName": "Midnights", "duration": 50,
                "syncedLyrics": content.inputLines.joined(separator: "\n")
            ])
        case .genius:
            let lyricPath = "/Taylor-swift-snow-on-the-beach-lyrics"
            if url.host == "api.genius.com" {
                // Support both configured-token and anonymous lookup routes.
                body = try! JSONSerialization.data(withJSONObject: [
                    "response": ["hits": [["result": ["url": "https://genius.com\(lyricPath)"]]]]
                ])
            } else if url.host == "genius.com", url.path.hasPrefix("/search") {
                body = Data("<a href='\(lyricPath)'>Snow On The Beach</a>".utf8)
            } else if url.host == "genius.com", url.path == lyricPath {
                let verses = content.inputLines.map { "<p>\($0)</p>" }.joined()
                body = Data("<div data-lyrics-container='true'>\(verses)</div>".utf8)
            } else {
                return failRequest()
            }
        case .letrasboom, .songlyrics, .bandcamp:
            let host: String
            switch provider {
            case .letrasboom: host = "www.letrasboom.com"
            case .songlyrics: host = "songlyrics.com"
            case .bandcamp: host = "taylorswift.bandcamp.com"
            case .lrclib, .genius: preconditionFailure("Provider handled above")
            }
            guard url.host == host else { return failRequest() }
            if provider == .letrasboom && url.path.hasPrefix("/artista/") {
                body = Data("<a href='/letra/taylor-swift/snow-on-the-beach'>Snow On The Beach</a>".utf8)
            } else {
                let containerAttributes: String
                switch provider {
                case .letrasboom: containerAttributes = "id=\"lb-lyrics\""
                case .songlyrics: containerAttributes = "id=\"songLyricsDiv\""
                case .bandcamp: containerAttributes = "class=\"lyricsText\""
                case .lrclib, .genius: preconditionFailure("Provider handled above")
                }
                let verses = content.inputLines.map { "<p>\($0)</p>" }.joined()
                body = Data("""
                    <html><head><title>Snow On The Beach - Taylor Swift Lyrics</title></head>
                    <body><div \(containerAttributes)>\(verses)</div></body></html>
                    """.utf8)
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func failRequest() {
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {}
}
