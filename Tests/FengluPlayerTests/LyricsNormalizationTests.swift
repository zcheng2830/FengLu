import Testing
@testable import FengluPlayer

struct LyricsNormalizationTests {
    @Test(arguments: [
        "Privacy  policy\nCookie\t\tpolicy",
        "Prívacy—policy\nCOOKIE___POLICY",
        "PRIVACY...POLICY\nCookie  policy"
    ])
    func rejectsPageChromeDespiteFormattingDifferences(_ text: String) {
        #expect(!LyricsParser.looksUsable(text))
    }
}
