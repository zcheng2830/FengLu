import Foundation
import Testing
@testable import FengluPlayer

struct CapturedLetrasBoomTests {
    @Test(arguments: CapturedLetrasBoomFixture.allCases)
    func extractsOnlyVersesFromCapturedPage(_ fixture: CapturedLetrasBoomFixture) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturedLetrasBoomProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Captured-LetrasBoom-Fixture": fixture.rawValue]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let track = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/captured-letrasboom.flac"),
            title: fixture.title, artist: "Taylor Swift", album: "Midnights",
            trackNumber: nil, duration: nil
        )

        let result = await LyricsOnlineResolver(track: track, session: session)
            .lyrics(for: track, sourceNames: ["letrasboom"])
        let resolution = try #require(result)
        #expect(resolution.rawLyrics == fixture.expectedLyrics)
    }
}

enum CapturedLetrasBoomFixture: String, CaseIterable, Sendable {
    case snowOnTheBeach = "snow-on-the-beach"
    case moreLanaVersion = "more-lana-version"

    var title: String {
        switch self {
        case .snowOnTheBeach: "Snow On The Beach"
        case .moreLanaVersion: "Snow on the Beach (More Lana Del Rey Version)"
        }
    }

    var songPath: String {
        switch self {
        case .snowOnTheBeach: "/letra/snow-on-the-beach-taylor-swift"
        case .moreLanaVersion: "/letra/snow-on-the-beach-more-lana-del-rey-version-taylor-swift"
        }
    }

    var expectedLyrics: String {
        let finalVerse = self == .snowOnTheBeach ? 69 : 61
        // These ranges come from the captured paragraphs and explicit <br> nodes,
        // independently of the production HTML renderer.
        let stanzas = [
            1...8, 9...16, 17...20, 21...28, 29...36,
            37...40, 41...45, 46...53, 54...59, 60...finalVerse
        ]
        return stanzas.map { stanza in
            stanza.map { String(format: "Fixture verse %03d follows the quiet river", $0) }
                .joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    func pageData() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: rawValue, withExtension: "html", subdirectory: "Fixtures/LetrasBoom"
        ))
        return try Data(contentsOf: url)
    }
}

private final class CapturedLetrasBoomProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.host == "www.letrasboom.com",
              let value = request.value(forHTTPHeaderField: "X-Captured-LetrasBoom-Fixture"),
              let fixture = CapturedLetrasBoomFixture(rawValue: value) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let data: Data
            if url.path.hasPrefix("/artista/") {
                data = Data("<a href='\(fixture.songPath)'>\(fixture.title)</a>".utf8)
            } else {
                data = try fixture.pageData()
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
