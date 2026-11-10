import Foundation
import Testing
@testable import FengluPlayer

struct TextFileLoaderTests {
    private static let chinese = "FILE \"七里香.wav\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"我的地盘\"\n    PERFORMER \"周杰伦\"\n"
    private static let japanese = "FILE \"アルバム.wav\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"さくらの花びらたち\"\n    PERFORMER \"宇多田ヒカル\"\n"

    @Test
    func unicodeEncodingsDecodeWithoutAByteOrderMarkCharacter() throws {
        let text = "FILE \"Ünïcödé 七里香.flac\" WAVE\n"
        let utf8 = Data(text.utf8)
        let utf8BOM = Data([0xEF, 0xBB, 0xBF]) + utf8
        let utf16LE = Data([0xFF, 0xFE]) + (try #require(text.data(using: .utf16LittleEndian)))
        let utf16BE = Data([0xFE, 0xFF]) + (try #require(text.data(using: .utf16BigEndian)))
        let ascii = "FILE \"plain.flac\" WAVE\n"
        let bomlessUTF16LE = try #require(ascii.data(using: .utf16LittleEndian))

        #expect(TextFileLoader.decode(utf8).text == text)
        #expect(TextFileLoader.decode(utf8BOM).text == text)
        #expect(TextFileLoader.decode(utf16LE).text == text)
        #expect(TextFileLoader.decode(utf16BE).text == text)
        #expect(TextFileLoader.decode(bomlessUTF16LE).text == ascii)
    }

    @Test
    func legacyEncodingIsChosenByTheReferencedFile() throws {
        let cases: [(String, String.Encoding, String)] = [
            (Self.chinese, PlaylistTestSupport.encoding(.GB_18030_2000), "七里香.wav"),
            (Self.japanese, .shiftJIS, "アルバム.wav"),
            ("FILE \"周杰倫 - 葉惠美.wav\" WAVE\n", PlaylistTestSupport.encoding(.big5), "周杰倫 - 葉惠美.wav"),
            ("FILE \"소녀시대 - 다시 만난 세계.wav\" WAVE\n", PlaylistTestSupport.encoding(.EUC_KR), "소녀시대 - 다시 만난 세계.wav"),
            ("FILE \"Björk - Jóga.wav\" WAVE\n", .windowsCP1252, "Björk - Jóga.wav")
        ]

        for (text, encoding, fileName) in cases {
            let data = try #require(text.data(using: encoding))
            let decoded = TextFileLoader.decode(data) { $0.contains(fileName) }
            #expect(decoded.text == text, "encoding \(encoding)")
        }
    }

    @Test
    func asciiFileNameDoesNotDecideTheEncoding() throws {
        // "album.wav" reads the same in every legacy encoding, so every
        // decoding "finds" the referenced file; the metadata must still decode
        // in the encoding it was written in.
        let cases: [(String, String.Encoding)] = [
            (
                "PERFORMER \"宇多田ヒカル\"\nTITLE \"First Love\"\nFILE \"album.wav\" WAVE\n" +
                "  TRACK 01 AUDIO\n    TITLE \"オートマティック\"\n    INDEX 01 00:00:00\n",
                .shiftJIS
            ),
            (
                "PERFORMER \"Björk\"\nTITLE \"Homogenic\"\nFILE \"album.wav\" WAVE\n" +
                "  TRACK 01 AUDIO\n    TITLE \"Jóga\"\n    INDEX 01 00:00:00\n",
                .windowsCP1252
            ),
            (
                "PERFORMER \"周杰伦\"\nTITLE \"七里香\"\nFILE \"album.wav\" WAVE\n" +
                "  TRACK 01 AUDIO\n    TITLE \"我的地盘\"\n    INDEX 01 00:00:00\n",
                PlaylistTestSupport.encoding(.GB_18030_2000)
            ),
            (
                "PERFORMER \"張學友\"\nTITLE \"吻別\"\nFILE \"album.wav\" WAVE\n" +
                "  TRACK 01 AUDIO\n    TITLE \"秋意濃\"\n    INDEX 01 00:00:00\n",
                PlaylistTestSupport.encoding(.big5)
            ),
            (
                "PERFORMER \"아이유\"\nTITLE \"좋은 날\"\nFILE \"album.wav\" WAVE\n" +
                "  TRACK 01 AUDIO\n    TITLE \"밤편지\"\n    INDEX 01 00:00:00\n",
                PlaylistTestSupport.encoding(.EUC_KR)
            )
        ]

        for (text, encoding) in cases {
            let data = try #require(text.data(using: encoding))
            let decoded = TextFileLoader.decode(data) { $0.contains("album.wav") }
            #expect(decoded.text == text, "encoding \(encoding)")
        }
    }

    @Test
    func chineseAndJapaneseTextAreDetectedWithoutAHint() throws {
        let gb18030 = try #require(Self.chinese.data(using: PlaylistTestSupport.encoding(.GB_18030_2000)))
        let shiftJIS = try #require(Self.japanese.data(using: .shiftJIS))

        #expect(TextFileLoader.decode(gb18030).text == Self.chinese)
        #expect(TextFileLoader.decode(shiftJIS).text == Self.japanese)
    }

    @Test
    func undecodableBytesStillProduceText() {
        let data = Data([0x46, 0x49, 0x4C, 0x45, 0x20, 0x81, 0x8D, 0x8F, 0x90, 0x9D, 0x0A])
        #expect(TextFileLoader.decode(data).text.hasPrefix("FILE "))
    }
}
