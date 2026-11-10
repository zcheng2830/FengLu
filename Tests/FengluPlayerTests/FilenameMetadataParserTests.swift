import Foundation
import Testing
@testable import FengluPlayer

struct FilenameMetadataParserTests {
    @Test(arguments: [
        ("99 Luftballons.mp3", "99 Luftballons", nil, nil),
        ("7 Rings.flac", "7 Rings", nil, nil),
        ("21 Guns.m4a", "21 Guns", nil, nil),
        ("24-7 Love.mp3", "24-7 Love", nil, nil),
        ("99.9 FM.mp3", "99.9 FM", nil, nil),
        ("03 Title.flac", "Title", nil, 3),
        ("3. Title.flac", "Title", nil, 3),
        ("03_Title.flac", "Title", nil, 3),
        ("12 - Title.flac", "Title", nil, 12),
        ("01 - Title - Live.mp3", "Title - Live", nil, 1),
        ("Title - Remastered 2011.mp3", "Title - Remastered 2011", nil, nil),
        ("01 - Artist - Title.mp3", "Title", "Artist", 1),
        ("Artist - Title.mp3", "Title", "Artist", nil),
        ("Artist - Title - Live.mp3", "Title - Live", "Artist", nil),
        ("Oasis - Live Forever.flac", "Live Forever", "Oasis", nil),
        ("Edward Maya - Stereo Love.mp3", "Stereo Love", "Edward Maya", nil),
        ("Queen - Radio Ga Ga.mp3", "Radio Ga Ga", "Queen", nil),
        ("Nirvana - Demo Tape Blues.mp3", "Demo Tape Blues", "Nirvana", nil),
        ("Title - Acoustic Version.mp3", "Title - Acoustic Version", nil, nil),
        ("Title - 2011 Remaster.mp3", "Title - 2011 Remaster", nil, nil),
        ("Title - Radio Edit.mp3", "Title - Radio Edit", nil, nil),
        ("Title - Live at Wembley.mp3", "Title - Live at Wembley", nil, nil),
        ("Title - (Live).mp3", "Title - (Live)", nil, nil),
        ("Plain Name.wav", "Plain Name", nil, nil)
    ] as [(String, String, String?, Int?)])
    func parsesFileNames(fileName: String, title: String, artist: String?, trackNumber: Int?) {
        let metadata = FilenameMetadataParser.parse(URL(fileURLWithPath: "/music/\(fileName)"))

        #expect(metadata == FilenameMetadata(title: title, artist: artist, trackNumber: trackNumber))
    }
}
