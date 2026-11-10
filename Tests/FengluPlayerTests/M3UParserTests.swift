import Foundation
import Testing
@testable import FengluPlayer

struct M3UParserTests {
    private let baseURL = PlaylistTestSupport.baseURL

    @Test
    func extendedInfoSuppliesMetadataAndDuration() {
        let playlist = """
        #EXTM3U
        #EXTINF:215,Artist - Song - Live
        one.mp3
        # a comment
        #extinf:-1 tvg-id="x",Only Title
        two.mp3

        three.mp3
        """
        let parser = M3UParser(environment: PlaylistTestSupport.environment([
            "/music/album/one.mp3": 1,
            "/music/album/two.mp3": 122,
            "/music/album/three.mp3": 33
        ]))
        let tracks = parser.parse(contents: playlist, baseURL: baseURL, playlistName: "Mix")

        #expect(tracks.map(\.title) == ["Song - Live", "Only Title", "three"])
        #expect(tracks.map(\.artist) == ["Artist", nil, nil])
        // A declared length wins; unknown (-1) and absent lengths are probed.
        #expect(tracks.map(\.duration) == [215, 122, 33])
        #expect(tracks.allSatisfy { $0.source == .playlist && $0.playlistName == "Mix" })
    }

    @Test(arguments: [
        ("one.mp3", "/music/album/one.mp3"),
        ("sub/one.mp3", "/music/album/sub/one.mp3"),
        (#"Disc 1\one.mp3"#, "/music/album/Disc 1/one.mp3"),
        (#"..\other\one.mp3"#, "/music/other/one.mp3"),
        ("/abs/one.mp3", "/abs/one.mp3"),
        ("Re: Zero.mp3", "/music/album/Re: Zero.mp3"),
        ("file:///abs/My%20Song.mp3", "/abs/My Song.mp3"),
        ("100% Pure.mp3", "/music/album/100% Pure.mp3")
    ])
    func pathsResolveAgainstThePlaylistFolder(entry: String, expectedPath: String) {
        let tracks = M3UParser(environment: PlaylistTestSupport.environment(existing: []))
            .parse(contents: entry, baseURL: baseURL)

        #expect(tracks.map(\.url.path) == [expectedPath])
        #expect(tracks.allSatisfy { $0.url.isFileURL })
    }

    @Test
    func windowsDrivePathFallsBackToTheFileBesideThePlaylist() {
        let parser = M3UParser(environment: PlaylistTestSupport.environment(existing: ["/music/album/a.mp3"]))
        let tracks = parser.parse(contents: #"C:\Music\Album\a.mp3"#, baseURL: baseURL)

        #expect(tracks.map(\.url.path) == ["/music/album/a.mp3"])
    }

    @Test
    func percentEncodedEntryIsUsedOnlyWhenTheLiteralNameIsMissing() {
        let entry = "My%20Song.mp3"
        let decoded = M3UParser(environment: PlaylistTestSupport.environment(existing: ["/music/album/My Song.mp3"]))
            .parse(contents: entry, baseURL: baseURL)
        let literal = M3UParser(environment: PlaylistTestSupport.environment(existing: ["/music/album/My%20Song.mp3"]))
            .parse(contents: entry, baseURL: baseURL)

        #expect(decoded.map(\.url.path) == ["/music/album/My Song.mp3"])
        #expect(literal.map(\.url.path) == ["/music/album/My%20Song.mp3"])
    }

    @Test
    func streamURLsStayRemote() {
        let tracks = M3UParser(environment: PlaylistTestSupport.environment(existing: []))
            .parse(contents: "https://example.com/live/stream.mp3", baseURL: baseURL)

        #expect(tracks.map(\.url.absoluteString) == ["https://example.com/live/stream.mp3"])
    }

    @Test(arguments: ["1e30", "inf", "nan", "0", "-5", "99999999999"])
    func absurdDeclaredLengthsAreIgnored(length: String) {
        let tracks = M3UParser(environment: PlaylistTestSupport.environment(existing: []))
            .parse(contents: "#EXTINF:\(length),Title\none.mp3", baseURL: baseURL)

        #expect(tracks.map(\.duration) == [nil])
        #expect(tracks.map(\.displayDuration) == ["--:--"])
    }
}
