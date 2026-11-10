import Foundation
import Testing
@testable import FengluPlayer

struct XSPFRoundTripTests {
    private let baseURL = PlaylistTestSupport.baseURL
    private let environment = PlaylistTestSupport.environment(existing: [])

    @Test
    func exportedPlaylistParsesBackToTheSameTracks() throws {
        let original = [
            AudioTrack(
                url: URL(fileURLWithPath: "/music/R&B <best> \"of\"/Tom's #1 song 100%.flac"),
                title: "Tom's <#1> & \"only\"",
                artist: "AC/DC & Friends",
                album: "A < B > C",
                trackNumber: 7,
                duration: 201.5
            ),
            AudioTrack(
                url: URL(fileURLWithPath: "/music/七里香/七里香.ape"),
                title: "我的地盘",
                artist: "周杰伦",
                album: "七里香",
                trackNumber: 2,
                duration: 3000,
                cueStart: 240.493333,
                cueEnd: 510.25,
                source: .cue
            ),
            AudioTrack(
                url: URL(fileURLWithPath: "/music/album/image.flac"),
                title: "Opening",
                cueStart: 0,
                cueEnd: 61,
                source: .cue
            )
        ]

        let document = XSPFExporter().documentString(for: original, title: "Mix & <Match>")
        let parsed = try XSPFParser(environment: environment)
            .parse(data: Data(document.utf8), baseURL: baseURL, playlistName: "Mix")

        #expect(parsed.map(\.url) == original.map(\.url))
        #expect(parsed.map(\.title) == original.map(\.title))
        #expect(parsed.map(\.artist) == original.map(\.artist))
        #expect(parsed.map(\.album) == original.map(\.album))
        #expect(parsed.map(\.trackNumber) == original.map(\.trackNumber))
        #expect(parsed.map(\.source) == [.playlist, .cue, .cue])
        #expect(parsed.map(\.cueStart) == [nil, 240.493333, 0])
        #expect(parsed.map(\.cueEnd) == [nil, 510.25, 61])
        #expect(parsed[0].duration == 201.5)
    }

    @Test(arguments: [
        ("sub/My%20Song.mp3", "/music/album/sub/My Song.mp3"),
        ("My Song.mp3", "/music/album/My Song.mp3"),
        ("file:///abs/My%20Song.mp3", "/abs/My Song.mp3"),
        ("/abs/plain.mp3", "/abs/plain.mp3"),
        (#"sub\one.mp3"#, "/music/album/sub/one.mp3")
    ])
    func locationsResolveAsURIs(location: String, expectedPath: String) throws {
        let tracks = try XSPFParser(environment: environment)
            .parse(data: Data(document(location: location).utf8), baseURL: baseURL)

        #expect(tracks.map(\.url.path) == [expectedPath])
    }

    @Test
    func literalPercentNameWinsWhenOnlyThatFileExists() throws {
        let parser = XSPFParser(environment: PlaylistTestSupport.environment(existing: ["/music/album/My%20Song.mp3"]))
        let tracks = try parser.parse(data: Data(document(location: "My%20Song.mp3").utf8), baseURL: baseURL)

        #expect(tracks.map(\.url.path) == ["/music/album/My%20Song.mp3"])
    }

    @Test(arguments: ["1e40", "-1", "0", "nan"])
    func absurdDurationsAreIgnored(duration: String) throws {
        let xml = document(location: "one.mp3", extra: "<duration>\(duration)</duration>")
        let tracks = try XSPFParser(environment: environment).parse(data: Data(xml.utf8), baseURL: baseURL)

        #expect(tracks.map(\.duration) == [nil])
        #expect(tracks.map(\.displayDuration) == ["--:--"])
    }

    @Test
    func malformedDocumentReportsTheLine() {
        let xml = "<playlist>\n<trackList>\n<track><location>a.mp3</location>\n</playlist>"

        #expect(throws: PlaylistParseError.self) {
            try XSPFParser(environment: environment).parse(data: Data(xml.utf8), baseURL: baseURL)
        }
    }

    private func document(location: String, extra: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <playlist version="1" xmlns="http://xspf.org/ns/0/">
          <trackList>
            <track><location>\(location)</location>\(extra)</track>
          </trackList>
        </playlist>
        """
    }
}
