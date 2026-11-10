import Foundation
import Testing
@testable import FengluPlayer

struct CueSheetParserTests {
    private let baseURL = PlaylistTestSupport.baseURL

    @Test
    func singleFileSheetSplitsTracksAtIndex01() {
        let sheet = """
        REM GENRE Rock
        PERFORMER "Album Artist"
        TITLE "The Album"
        FILE "album.flac" WAVE
          TRACK 01 AUDIO
            TITLE "First"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Second"
            PERFORMER "Guest"
            INDEX 00 03:58:00
            INDEX 01 04:00:37
          TRACK 03 AUDIO
            TITLE "Third"
            INDEX 01 08:30:00
        """
        let parser = CueSheetParser(environment: PlaylistTestSupport.environment(["/music/album/album.flac": 700]))
        let tracks = parser.parse(contents: sheet, baseURL: baseURL, playlistName: "The Album")

        #expect(tracks.map(\.title) == ["First", "Second", "Third"])
        #expect(tracks.map(\.artist) == ["Album Artist", "Guest", "Album Artist"])
        #expect(tracks.allSatisfy { $0.album == "The Album" && $0.source == .cue })
        #expect(tracks.allSatisfy { $0.url.path == "/music/album/album.flac" })
        #expect(tracks.map(\.cueStart) == [0, 240.0 + 37.0 / 75.0, 510])
        // INDEX 00 is a pregap marker and never a boundary; the last track ends with the file.
        #expect(tracks.map(\.cueEnd) == [240.0 + 37.0 / 75.0, 510, 700])
    }

    @Test
    func fileAfterTrackBindsTheTrackToTheNewFile() {
        // EAC "non-compliant" layout: the next FILE follows TRACK and the INDEX 00 pregap.
        let sheet = """
        FILE "01.wav" WAVE
          TRACK 01 AUDIO
            TITLE "One"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Two"
            INDEX 00 03:58:00
        FILE "02.wav" WAVE
            INDEX 01 00:00:00
          TRACK 03 AUDIO
            TITLE "Three"
            INDEX 00 04:10:00
        FILE "03.wav" WAVE
            INDEX 01 00:00:00
        """
        let parser = CueSheetParser(environment: PlaylistTestSupport.environment([
            "/music/album/01.wav": 240,
            "/music/album/02.wav": 252,
            "/music/album/03.wav": 199
        ]))
        let tracks = parser.parse(contents: sheet, baseURL: baseURL)

        #expect(tracks.map(\.url.lastPathComponent) == ["01.wav", "02.wav", "03.wav"])
        #expect(tracks.map(\.cueStart) == [0, 0, 0])
        #expect(tracks.map(\.cueEnd) == [240, 252, 199])
    }

    @Test
    func compliantMultiFileSheetKeepsEachTrackInItsOwnFile() {
        let sheet = """
        FILE "a.flac" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            INDEX 01 02:00:00
        FILE "b.flac" WAVE
          TRACK 03 AUDIO
            INDEX 01 00:00:00
        """
        let parser = CueSheetParser(environment: PlaylistTestSupport.environment([
            "/music/album/a.flac": 300,
            "/music/album/b.flac": 100
        ]))
        let tracks = parser.parse(contents: sheet, baseURL: baseURL)

        #expect(tracks.map(\.url.lastPathComponent) == ["a.flac", "a.flac", "b.flac"])
        #expect(tracks.map(\.cueStart) == [0, 120, 0])
        #expect(tracks.map(\.cueEnd) == [120, 300, 100])
    }

    @Test(arguments: [
        ("album.wav", "/music/album/album.flac"),
        ("album.wav", "/music/album/album.ape"),
        (#"C:\Rips\Album\album.wav"#, "/music/album/album.wav"),
        (#"disc 1\album.flac"#, "/music/album/disc 1/album.flac")
    ])
    func missingMediaFallsBackToWhatIsOnDisk(declared: String, existing: String) {
        let sheet = """
        FILE "\(declared)" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
        """
        let parser = CueSheetParser(environment: PlaylistTestSupport.environment(existing: [existing]))
        let tracks = parser.parse(contents: sheet, baseURL: baseURL)

        #expect(tracks.map(\.url.path) == [existing])
    }

    @Test
    func unquotedFileNamesAndMissingIndexAreTolerated() {
        let sheet = """
        file album.flac WAVE
          track 01 audio
            title Loose Title
          TRACK 02 AUDIO
            INDEX 01 01:00:00
        """
        let parser = CueSheetParser(environment: PlaylistTestSupport.environment(["/music/album/album.flac": 200]))
        let tracks = parser.parse(contents: sheet, baseURL: baseURL)

        #expect(tracks.count == 2)
        #expect(tracks[0].title == "Loose Title")
        #expect(tracks[0].cueStart == nil)
        #expect(tracks[0].cueEnd == 60)
        #expect(tracks[1].cueStart == 60)
        #expect(tracks[1].cueEnd == 200)
    }

    @Test
    func legacyChineseSheetIsDecodedByFindingItsMediaFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fenglu-cue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let sheet = "PERFORMER \"周杰伦\"\r\nTITLE \"七里香\"\r\nFILE \"七里香.wav\" WAVE\r\n  TRACK 01 AUDIO\r\n    TITLE \"我的地盘\"\r\n    INDEX 01 00:00:00\r\n"
        let data = try #require(sheet.data(using: PlaylistTestSupport.encoding(.GB_18030_2000)))
        let cueURL = directory.appendingPathComponent("七里香.cue")
        try data.write(to: cueURL)
        try Data().write(to: directory.appendingPathComponent("七里香.wav"))

        let tracks = try CueSheetParser().parse(cueURL)

        #expect(tracks.map(\.title) == ["我的地盘"])
        #expect(tracks.map(\.artist) == ["周杰伦"])
        #expect(tracks.map(\.url.lastPathComponent) == ["七里香.wav"])
    }
}
