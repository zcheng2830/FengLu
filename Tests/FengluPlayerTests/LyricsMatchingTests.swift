import Foundation
import Testing
@testable import FengluPlayer

/// Which search results may be taken for the playing track, and which of
/// several accepted results is shown.
struct LyricsMatchingTests {
    private func track(
        _ title: String, artist: String? = nil, album: String? = nil,
        trackNumber: Int? = nil, duration: TimeInterval? = 180
    ) -> AudioTrack {
        AudioTrack(
            url: URL(fileURLWithPath: "/tmp/lyrics-matching/\(title).flac"),
            title: title, artist: artist, album: album, trackNumber: trackNumber, duration: duration
        )
    }

    private func netEaseSearch(_ songs: [[String: Any]]) -> LyricsStubResponse {
        .json(["result": ["songs": songs]])
    }

    private func netEaseSong(
        _ name: String, artist: String, album: String = "", seconds: Double = 180, id: Int = 7
    ) -> [String: Any] {
        ["id": id, "name": name, "artists": [["name": artist]], "album": ["name": album], "duration": seconds * 1000]
    }

    // MARK: Metadata acceptance

    @Test func titleScoresSeparateEqualContainedAndSharedWordTitles() {
        let resolver = LyricsOnlineResolver(track: track("Love Story"))
        let loveStory = track("Love Story")
        #expect(resolver.titleMatchScore(candidateTitle: "Love Story", track: loveStory) == 12)
        #expect(resolver.titleMatchScore(candidateTitle: "love  story!", track: loveStory) == 12)
        #expect(resolver.titleMatchScore(candidateTitle: "Love Story (Taylor's Version)", track: loveStory) >= 7)
        #expect(resolver.titleMatchScore(candidateTitle: "Love Story - Remastered 2011", track: loveStory) >= 7)
        #expect((1...6).contains(resolver.titleMatchScore(candidateTitle: "Love Me Like You Do", track: loveStory)))
        #expect(resolver.titleMatchScore(candidateTitle: "Blank Space", track: loveStory) == 0)

        // Containment needs a word boundary: "Home" is not in "Homecoming".
        #expect(resolver.titleMatchScore(candidateTitle: "Homecoming", track: track("Home")) == 0)
        #expect(resolver.titleMatchScore(candidateTitle: "Warlord", track: track("War")) == 0)
        #expect(resolver.titleMatchScore(candidateTitle: "War (2011 Remaster)", track: track("War")) >= 7)
        #expect(resolver.titleMatchScore(candidateTitle: "晴天 (Live)", track: track("晴天")) >= 7)
        #expect(resolver.titleMatchScore(candidateTitle: "晴天娃娃", track: track("晴天")) == 0)
    }

    @Test func oneSharedWordIsNotEnoughWithoutAnArtist() {
        let untagged = track("Love Story")
        let resolver = LyricsOnlineResolver(track: untagged)
        #expect(resolver.metadataMatch(title: "Love Me Like You Do", artist: "Ellie Goulding", duration: 180, track: untagged) == nil)
        #expect(resolver.metadataMatch(title: "Love Me Like You Do", artist: "", duration: 180, track: untagged) == nil)
        // The title itself is evidence enough when nothing contradicts it.
        #expect(resolver.metadataMatch(title: "Love Story", artist: "Taylor Swift", track: untagged)?.isStrongTitle == true)
    }

    @Test func wrongArtistNeedsMoreThanACloseDuration() {
        let tagged = track("Love Story", artist: "Taylor Swift", album: "Fearless")
        let resolver = LyricsOnlineResolver(track: tagged)
        // A different song by someone else whose length happens to be close.
        #expect(resolver.metadataMatch(title: "Love Me Like You Do", artist: "Ellie Goulding", duration: 183, track: tagged) == nil)
        // Same title, different artist, nothing else in common: a namesake.
        #expect(resolver.metadataMatch(title: "Love Story", artist: "Andy Williams", duration: 200, track: tagged) == nil)
        // Same title and the same length, artist written differently.
        #expect(resolver.metadataMatch(title: "Love Story", artist: "泰勒·斯威夫特", duration: 181, track: tagged)?.isStrongTitle == true)
        // Shared words by the right artist still need the whole title.
        #expect(resolver.metadataMatch(title: "Love Me Like You Do", artist: "Taylor Swift", track: tagged) == nil)
        #expect(resolver.metadataMatch(title: "Story of Love", artist: "Taylor Swift", track: tagged)?.isStrongTitle == false)
        #expect(resolver.metadataMatch(title: "Love Story", artist: "Taylor Swift", track: tagged)?.isExactIdentity == true)
    }

    @Test func creditsSharingAPerformerCountAsTheSameArtist() {
        let duet = track("千里之外", artist: "周杰伦/费玉清")
        let resolver = LyricsOnlineResolver(track: duet)
        #expect(resolver.metadataMatch(title: "千里之外", artist: "周杰伦", track: duet)?.isExactIdentity == true)
        let featured = track("Snow On The Beach", artist: "Taylor Swift feat. Lana Del Rey")
        #expect(resolver.metadataMatch(title: "Snow On The Beach", artist: "Taylor Swift", track: featured)?.isExactIdentity == true)
        #expect(resolver.metadataMatch(title: "Snow On The Beach", artist: "Taylor Swiftly", track: featured) == nil)
    }

    @Test func albumSiblingIsRejectedWithoutATitleMatch() {
        let playing = track("Enchanted", artist: "Taylor Swift", album: "Speak Now", trackNumber: 9, duration: 352)
        let resolver = LyricsOnlineResolver(track: playing)
        // Same artist, album and length, different song.
        #expect(resolver.metadataMatch(
            title: "Dear John", artist: "Taylor Swift", album: "Speak Now", duration: 353, track: playing
        ) == nil)
        #expect(resolver.metadataMatch(
            title: "Dear John", artist: "Taylor Swift", album: "Speak Now", duration: 353, trackNumber: 5, track: playing
        ) == nil)
        // Another script for the same position on the same release.
        #expect(resolver.metadataMatch(
            title: "魔法", artist: "Taylor Swift", album: "Speak Now", duration: 352, trackNumber: 9, track: playing
        )?.isStrongTitle == false)
    }

    @Test func searchResultForAnotherSongYieldsNothing() async {
        let untagged = track("Love Story")
        let (session, key) = LyricsStubProtocol.session { [self] url in
            url.path == "/api/search/get"
                ? netEaseSearch([netEaseSong("Love Me Like You Do", artist: "Ellie Goulding")])
                : .json(["lrc": ["lyric": LyricsTestText.synchronized()]])
        }
        defer { session.invalidateAndCancel() }
        let result = await LyricsOnlineResolver(track: untagged, session: session)
            .lyrics(for: untagged, sourceNames: ["netease"])
        #expect(result == nil)
        #expect(!LyricsStubProtocol.requestedURLs(key).contains { $0.path == "/api/song/lyric" })
    }

    // MARK: Cross-provider selection

    @Test func sharedWordSynchronizedResultLosesToExactTitlePlainResult() async throws {
        let playing = track("Midnight Rain", artist: "The Lanterns")
        let (session, _) = LyricsStubProtocol.session { [self] url in
            switch (url.host, url.path) {
            case ("music.163.com", "/api/search/get"):
                return netEaseSearch([netEaseSong("Rain at Midnight", artist: "The Lanterns")])
            case ("music.163.com", _):
                return .json(["lrc": ["lyric": LyricsTestText.synchronized()]])
            case ("lrclib.net", "/api/search"):
                return .json([[
                    "trackName": "Midnight Rain", "artistName": "The Lanterns", "duration": 180,
                    "plainLyrics": LyricsTestText.plain
                ]])
            default:
                return nil
            }
        }
        defer { session.invalidateAndCancel() }
        let resolver = LyricsOnlineResolver(track: playing, session: session)

        let both = try #require(await resolver.lyrics(for: playing, sourceNames: ["netease", "lrclib-search"]))
        #expect(both.sourceName == "lrclib-search")
        #expect(!both.document.isSynchronized)
        // On its own the weaker result is still usable.
        let alone = try #require(await resolver.lyrics(for: playing, sourceNames: ["netease"]))
        #expect(alone.document.isSynchronized)
    }

    @Test func exactSynchronizedMatchEndsTheLookupEarly() async throws {
        let playing = track("River Road", artist: "The Lanterns", album: "Bridges")
        let (session, _) = LyricsStubProtocol.session { url in
            switch url.host {
            case "lrclib.net":
                return .json([
                    "trackName": "River Road", "artistName": "The Lanterns", "albumName": "Bridges",
                    "duration": 180, "syncedLyrics": LyricsTestText.synchronized()
                ])
            default:
                return .json(["result": ["songs": []]], delay: 8)
            }
        }
        defer { session.invalidateAndCancel() }
        let started = Date()
        let result = try #require(await LyricsOnlineResolver(track: playing, session: session)
            .lyrics(for: playing, sourceNames: ["lrclib-exact", "netease", "kugou"]))
        #expect(result.sourceName == "lrclib-exact")
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func lookupGivesUpAtItsDeadline() async {
        let playing = track("River Road", artist: "The Lanterns")
        let (session, _) = LyricsStubProtocol.session { _ in .json(["result": ["songs": []]], delay: 8) }
        defer { session.invalidateAndCancel() }
        let started = Date()
        let result = await LyricsOnlineResolver(track: playing, session: session, lookupDeadline: 0.3)
            .lyrics(for: playing, sourceNames: ["netease", "kugou"])
        #expect(result == nil)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    // MARK: Providers

    @Test func lrcAPINeverReturnsLyricsOfRejectedResults() async throws {
        let playing = track("River Road", artist: "The Lanterns")
        let rejected: [[String: Any]] = [
            ["title": "Mountain Pass", "artist": "Someone Else", "lyrics": LyricsTestText.synchronized()],
            ["title": "Harbour Lights", "artist": "Another Band", "lrc": LyricsTestText.synchronized()]
        ]
        let accepted: [String: Any] = [
            "title": "River Road", "artist": "The Lanterns", "lyrics": LyricsTestText.synchronized()
        ]
        for (results, shouldMatch) in [(rejected, false), (rejected + [accepted], true)] {
            let reply = LyricsStubResponse.json(results)
            let (session, _) = LyricsStubProtocol.session { _ in reply }
            defer { session.invalidateAndCancel() }
            let result = await LyricsOnlineResolver(track: playing, session: session)
                .lyrics(for: playing, sourceNames: ["lrcapi"])
            #expect((result != nil) == shouldMatch)
        }
    }

    @Test(arguments: [
        ("Halo", "Beyoncé", "Beyoncé - Halo Lyrics", true),
        ("Stay", "Rihanna", "Rihanna - Stay Lyrics | AZLyrics", true),
        ("晴天", "周杰伦", "周杰伦 晴天 歌词", true),
        ("Stay", "Rihanna", "Rihanna - Staying Alive Lyrics", false),
        ("Halo", "Beyoncé", "Beyoncé - Hello Lyrics", false),
        ("Halo", "Beyoncé", "Depeche Mode - Halo Lyrics", false)
    ])
    func shortOneWordTitlesValidateAsWholeWords(
        title: String, artist: String, pageTitle: String, matches: Bool
    ) throws {
        let playing = track(title, artist: artist)
        let page = try LyricsHTMLPage("<html><head><title>\(pageTitle)</title></head><body></body></html>")
        #expect(LyricsOnlineResolver(track: playing).htmlLyricsPageMatches(
            page: page, pageURL: URL(string: "https://lyrics.example/recording/123")!,
            track: playing, providerName: "test"
        ) == matches)
    }

    @Test func geniusURLNeedsTheTitleAndAcceptsShortTitles() {
        let hello = track("Hello", artist: "Adele")
        let resolver = LyricsOnlineResolver(track: hello)
        let plain = resolver.geniusURLScore(URL(string: "https://genius.com/Adele-hello-lyrics")!, track: hello)
        let live = resolver.geniusURLScore(
            URL(string: "https://genius.com/Adele-hello-live-at-the-royal-albert-hall-lyrics")!, track: hello
        )
        #expect(plain > 0)
        #expect(plain > live)
        #expect(resolver.geniusURLScore(URL(string: "https://genius.com/Adele-skyfall-lyrics")!, track: hello) == 0)
        #expect(resolver.geniusURLScore(URL(string: "https://genius.com/Lionel-richie-hello-lyrics")!, track: hello) == 0)

        // Slugs drop apostrophes.
        let journey = track("Don't Stop Believin'", artist: "Journey")
        #expect(resolver.geniusURLScore(
            URL(string: "https://genius.com/Journey-dont-stop-believin-lyrics")!, track: journey
        ) > 0)
        // A title that is also the artist's name has to appear twice.
        let selfTitled = track("Bad Company", artist: "Bad Company")
        #expect(resolver.geniusURLScore(
            URL(string: "https://genius.com/Bad-company-feel-like-makin-love-lyrics")!, track: selfTitled
        ) == 0)
        #expect(resolver.geniusURLScore(
            URL(string: "https://genius.com/Bad-company-bad-company-lyrics")!, track: selfTitled
        ) > 0)

        // Every word of the artist is in the URL, none of the title.
        let byTheWay = track("By the Way", artist: "Red Hot Chili Peppers")
        #expect(resolver.geniusURLScore(
            URL(string: "https://genius.com/Red-hot-chili-peppers-californication-lyrics")!, track: byTheWay
        ) == 0)
        #expect(resolver.geniusURLScore(
            URL(string: "https://genius.com/Red-hot-chili-peppers-by-the-way-lyrics")!, track: byTheWay
        ) > 0)
    }

    @Test func geniusPageThatNamesAnotherSongIsRejected() async {
        let hello = track("Hello", artist: "Adele")
        for (pageTitle, shouldMatch) in [("Adele – Hello Lyrics | Genius Lyrics", true), ("Adele – Skyfall Lyrics | Genius Lyrics", false)] {
            let lines = LyricsTestText.verses.joined(separator: "<br>")
            let (session, _) = LyricsStubProtocol.session { url in
                url.path.hasPrefix("/search")
                    ? .html(#"<a href="https://genius.com/Adele-hello-lyrics">Hello</a>"#)
                    : .html("""
                    <html><head><title>\(pageTitle)</title></head><body>
                    <div data-lyrics-container="true">\(lines)</div></body></html>
                    """)
            }
            defer { session.invalidateAndCancel() }
            let result = await LyricsOnlineResolver(track: hello, session: session)
                .lyrics(for: hello, sourceNames: ["genius"])
            #expect((result != nil) == shouldMatch)
        }
    }

    @Test func metalArchivesDoesNotFallThroughToALongerNamesake() async {
        let war = track("War", artist: "Band", album: "First Album")
        func row(_ title: String, lyricsID: Int?) -> [Any] {
            [
                #"<a href="https://www.metal-archives.com/bands/Band/1">Band</a>"#,
                #"<a href="https://www.metal-archives.com/albums/Band/First_Album/2">First Album</a>"#,
                "Full-length", title,
                lyricsID.map { #"<a href="javascript:;" id="lyricsLink_\#($0)">Show lyrics</a>"# } ?? ""
            ]
        }
        let lyricsPage = LyricsTestText.verses.joined(separator: "<br />\n")
        for (rows, shouldMatch) in [
            ([row("War", lyricsID: nil), row("Warlord", lyricsID: 5)], false),
            ([row("Warlord", lyricsID: 5), row("War", lyricsID: 6)], true),
            // Lyrics exist only for a row by the right band but another title.
            ([row("Peace", lyricsID: 9)], false)
        ] {
            let search = LyricsStubResponse.json(["aaData": rows])
            let (session, key) = LyricsStubProtocol.session { url in
                url.path.contains("/search/") ? search : .html(lyricsPage)
            }
            defer { session.invalidateAndCancel() }
            let result = await LyricsOnlineResolver(track: war, session: session)
                .lyrics(for: war, sourceNames: ["metalarchives"])
            #expect((result != nil) == shouldMatch)
            let lyricRequests = LyricsStubProtocol.requestedURLs(key).filter { $0.path.contains("ajax-view-lyrics") }
            #expect(lyricRequests.map(\.lastPathComponent) == (shouldMatch ? ["6"] : []))
        }
    }

    @Test func darkLyricsSelectsTheSectionWhoseHeadingIsTheTitle() async throws {
        let war = track("War", artist: "Band", album: "First Album")
        let warlord = (1...6).map { "Warlord verse number \($0) rides out" }.joined(separator: "<br>")
        let lines = LyricsTestText.verses.joined(separator: "<br>")
        let (session, _) = LyricsStubProtocol.session { _ in
            .html("""
            <html><head><title>BAND LYRICS - "First Album" (1999) album</title></head><body>
            <div class="lyrics"><h3>1. Warlord</h3>\(warlord)<h3>2. War</h3>\(lines)</div></body></html>
            """)
        }
        defer { session.invalidateAndCancel() }
        let result = try #require(await LyricsOnlineResolver(track: war, session: session)
            .lyrics(for: war, sourceNames: ["darklyrics"]))
        #expect(result.rawLyrics == LyricsTestText.plain)
    }

    // MARK: Fetch layer

    @Test func plusInQueryValuesIsPercentEncoded() async {
        let playing = track("1+1", artist: "Beyoncé", album: "4")
        let (session, key) = LyricsStubProtocol.session { _ in LyricsStubResponse(status: 404) }
        defer { session.invalidateAndCancel() }
        _ = await LyricsOnlineResolver(track: playing, session: session)
            .lyrics(for: playing, sourceNames: ["lrclib-exact"])
        let queries = LyricsStubProtocol.requestedURLs(key).compactMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        }
        #expect(!queries.isEmpty)
        #expect(queries.allSatisfy { $0.contains("track_name=1%2B1") && !$0.contains("+") })
        // The album-less retry goes out as well.
        #expect(queries.contains { $0.contains("album_name=4") })
        #expect(queries.contains { !$0.contains("album_name") })
    }

    @Test func oversizedResponseIsDiscarded() async {
        let playing = track("River Road", artist: "The Lanterns")
        let padding = String(repeating: " ", count: LyricsOnlineResolver.maximumResponseBytes)
        let object: [String: Any] = [
            "trackName": "River Road", "artistName": "The Lanterns", "duration": 180,
            "syncedLyrics": LyricsTestText.synchronized(), "padding": padding
        ]
        let reply = LyricsStubResponse.json(object)
        let (session, _) = LyricsStubProtocol.session { _ in reply }
        defer { session.invalidateAndCancel() }
        let result = await LyricsOnlineResolver(track: playing, session: session)
            .lyrics(for: playing, sourceNames: ["lrclib-exact"])
        #expect(result == nil)
    }

    @Test(arguments: [true, false])
    func legacyCharsetPagesAreDecoded(declaredInHeader: Bool) async throws {
        let playing = track("Qing Tian", artist: "Jay Chou")
        let verses = ["故事的小黄花", "从出生那年就飘着", "童年的荡秋千", "随记忆一直晃到现在", "吹着前奏望着天空", "我想起花瓣试着掉落"]
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let meta = declaredInHeader ? "" : #"<meta http-equiv="Content-Type" content="text/html; charset=gb2312">"#
        let html = """
        <html><head>\(meta)<title>Jay Chou 周杰伦 - Qing Tian 晴天 歌词</title></head><body>
        <div id="songLyricsDiv">\(verses.joined(separator: "<br>"))</div></body></html>
        """
        let body = try #require(html.data(using: gb18030))
        #expect(String(data: body, encoding: .utf8) == nil)
        let headers = ["Content-Type": declaredInHeader ? "text/html; charset=GBK" : "text/html"]
        let (session, _) = LyricsStubProtocol.session { _ in LyricsStubResponse(body: body, headers: headers) }
        defer { session.invalidateAndCancel() }
        let result = try #require(await LyricsOnlineResolver(track: playing, session: session)
            .lyrics(for: playing, sourceNames: ["songlyrics"]))
        #expect(result.rawLyrics == verses.joined(separator: "\n"))
    }

    @Test func tokensAreRedactedFromLoggedURLs() {
        let url = URL(string: "https://apic-desktop.musixmatch.com/ws/1.1/track.search?q_track=Hello&usertoken=SECRET123&app_id=web")!
        let logged = LyricsOnlineResolver.redactedURLString(url)
        #expect(!logged.contains("SECRET123"))
        #expect(logged.contains("q_track=Hello"))
        #expect(logged.contains("usertoken=REDACTED"))
        let plain = URL(string: "https://lrclib.net/api/get?track_name=Hello")!
        #expect(LyricsOnlineResolver.redactedURLString(plain) == plain.absoluteString)
    }
}
