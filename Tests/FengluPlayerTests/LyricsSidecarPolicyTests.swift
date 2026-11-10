import Foundation
import Testing
@testable import FengluPlayer

/// What the resolver may write next to the music: synchronized results only,
/// never over an existing file, never from a cancelled lookup.
struct LyricsSidecarPolicyTests {
    private let sources = ["local", "cache", "lrclib-exact"]

    private func lrclibReply(synced: String?, plain: String? = nil, delay: TimeInterval = 0) -> LyricsStubResponse {
        var object: [String: Any] = [
            "trackName": "River Road", "artistName": "The Lanterns", "albumName": "Bridges", "duration": 180
        ]
        object["syncedLyrics"] = synced
        object["plainLyrics"] = plain
        return .json(object, delay: delay)
    }

    private func makeTrack(in directory: URL) -> AudioTrack {
        AudioTrack(
            url: directory.appendingPathComponent("01 River Road.flac"),
            title: "River Road", artist: "The Lanterns", album: "Bridges", duration: 180
        )
    }

    private func cacheFiles(_ cacheRoot: URL) -> [String] {
        let directory = cacheRoot.appendingPathComponent(LyricsConfiguration.cacheDirectoryName)
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    @Test func synchronizedResultIsSavedOnceAndThenReadLocally() async throws {
        let directory = try LyricsTestText.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lyrics = LyricsTestText.synchronized()
        let (session, key) = LyricsStubProtocol.session { [self] url in
            url.host == "lrclib.net" ? lrclibReply(synced: lyrics) : nil
        }
        defer { session.invalidateAndCancel() }
        let track = makeTrack(in: directory)
        let resolver = LyricsResolver(session: session, cacheRootDirectory: directory.appendingPathComponent("cache"))

        let document = await resolver.lyrics(for: track, sourceNames: sources, onlineEnabled: true)
        #expect(document.isSynchronized)
        let sidecar = directory.appendingPathComponent("01 River Road.lrc")
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == lyrics)
        #expect(cacheFiles(directory.appendingPathComponent("cache")).count == 1)

        let requestCount = LyricsStubProtocol.requestedURLs(key).count
        let second = await resolver.lyrics(for: track, sourceNames: sources, onlineEnabled: true)
        #expect(second.sourceDescription.hasPrefix("Local lyrics"))
        #expect(LyricsStubProtocol.requestedURLs(key).count == requestCount)
    }

    @Test(arguments: ["my notes", "[ti:River Road]\n[ar:The Lanterns]", "Instrumental"])
    func existingFileIsNeverOverwritten(_ userContents: String) async throws {
        let directory = try LyricsTestText.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sidecar = directory.appendingPathComponent("01 River Road.lrc")
        try userContents.write(to: sidecar, atomically: true, encoding: .utf8)
        let (session, _) = LyricsStubProtocol.session { [self] url in
            url.host == "lrclib.net" ? lrclibReply(synced: LyricsTestText.synchronized()) : nil
        }
        defer { session.invalidateAndCancel() }
        let resolver = LyricsResolver(session: session, cacheRootDirectory: directory.appendingPathComponent("cache"))

        // Without "local" in the list the file is not even consulted, and
        // must still survive.
        for sourceNames in [sources, ["lrclib-exact"]] {
            let document = await resolver.lyrics(for: makeTrack(in: directory), sourceNames: sourceNames, onlineEnabled: true)
            #expect(document.isSynchronized)
            #expect(try String(contentsOf: sidecar, encoding: .utf8) == userContents)
        }
    }

    @Test func plainResultIsShownButNotWritten() async throws {
        let directory = try LyricsTestText.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, _) = LyricsStubProtocol.session { [self] url in
            url.host == "lrclib.net" ? lrclibReply(synced: nil, plain: LyricsTestText.plain) : nil
        }
        defer { session.invalidateAndCancel() }
        let resolver = LyricsResolver(session: session, cacheRootDirectory: directory.appendingPathComponent("cache"))

        let document = await resolver.lyrics(for: makeTrack(in: directory), sourceNames: sources, onlineEnabled: true)
        #expect(!document.isSynchronized)
        #expect(document.plainText == LyricsTestText.plain)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".lrc") }.isEmpty)
        #expect(cacheFiles(directory.appendingPathComponent("cache")).isEmpty)
    }

    @Test func cancelledLookupWritesNothing() async throws {
        let directory = try LyricsTestText.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // One provider has already answered with usable synchronized lyrics
        // when the user moves on; the better provider is still pending.
        let (session, key) = LyricsStubProtocol.session { [self] url in
            switch url.host {
            case "lrclib.net":
                return lrclibReply(synced: LyricsTestText.synchronized(), delay: 5)
            case "music.163.com" where url.path == "/api/search/get":
                return .json(["result": ["songs": [[
                    "id": 7, "name": "River Road", "artists": [["name": "The Lanterns"]],
                    "album": ["name": "Bridges"], "duration": 180_000
                ]]]])
            case "music.163.com":
                // Outlasts the last timestamp check, so this is not an early return.
                return .json(["lrc": ["lyric": LyricsTestText.synchronized(lastTime: 100)]])
            default:
                return nil
            }
        }
        defer { session.invalidateAndCancel() }
        let track = makeTrack(in: directory)
        let cacheRoot = directory.appendingPathComponent("cache")
        let resolver = LyricsResolver(session: session, cacheRootDirectory: cacheRoot)

        let lookup = Task {
            await resolver.lyrics(for: track, sourceNames: ["local", "cache", "lrclib-exact", "netease"], onlineEnabled: true)
        }
        // Wait until NetEase has delivered its lyrics, then cancel.
        for _ in 0..<200 where !LyricsStubProtocol.requestedURLs(key).contains(where: { $0.path == "/api/song/lyric" }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        lookup.cancel()
        let document = await lookup.value

        #expect(!document.isSynchronized)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".lrc") }.isEmpty)
        #expect(cacheFiles(cacheRoot).isEmpty)
    }

    @Test func cueTracksNeverShareTheImageBaseName() throws {
        let image = URL(fileURLWithPath: "/music/Album.flac")
        let resolver = LyricsResolver()
        let untagged = [
            AudioTrack(url: image, title: "Part 1", trackNumber: 1, source: .cue),
            AudioTrack(url: image, title: "Part 2", trackNumber: 2, source: .cue)
        ]
        let saveNames = untagged.map { resolver.sidecarSaveURL(for: $0).lastPathComponent }
        #expect(saveNames == ["Album - 01 Part 1.lrc", "Album - 02 Part 2.lrc"])

        for track in untagged {
            let candidates = resolver.localCandidateURLs(for: track).map(\.lastPathComponent)
            #expect(!candidates.contains("Album.lrc"))
            #expect(!candidates.contains("Album.txt"))
            #expect(candidates.contains(resolver.sidecarSaveURL(for: track).lastPathComponent))
        }

        let tagged = AudioTrack(url: image, title: "T.N.T.", artist: "AC/DC", trackNumber: 3, source: .cue)
        #expect(resolver.sidecarSaveURL(for: tagged).path == "/music/AC-DC - T.N.T..lrc")
        #expect(resolver.localCandidateURLs(for: tagged).map(\.lastPathComponent)
            == ["AC-DC - T.N.T..lrc", "AC-DC - T.N.T..txt", "Album - 03 T.N.T..lrc", "Album - 03 T.N.T..txt"])

        let file = AudioTrack(url: URL(fileURLWithPath: "/music/Song.flac"), title: "Song", artist: "Band")
        #expect(resolver.sidecarSaveURL(for: file).lastPathComponent == "Song.lrc")
        #expect(resolver.localCandidateURLs(for: file).map(\.lastPathComponent)
            == ["Song.lrc", "Song.txt", "Band - Song.lrc", "Band - Song.txt"])
    }

    @Test func cacheKeySeparatesSparselyTaggedFiles() throws {
        let resolver = LyricsResolver()
        let first = AudioTrack(url: URL(fileURLWithPath: "/music/a/Intro.flac"), title: "Intro", duration: 61)
        let second = AudioTrack(url: URL(fileURLWithPath: "/music/b/Intro.flac"), title: "Intro", duration: 61)
        #expect(resolver.cacheKey(for: first) != resolver.cacheKey(for: second))
        #expect(resolver.cacheKey(for: first) == resolver.cacheKey(for: first))

        // Tagged recordings of different lengths are different recordings;
        // the same recording keeps one key wherever the file lives.
        let studio = AudioTrack(url: first.url, title: "Intro", artist: "Band", album: "LP", duration: 61)
        let live = AudioTrack(url: first.url, title: "Intro", artist: "Band", album: "LP", duration: 305)
        let moved = AudioTrack(url: second.url, title: "Intro", artist: "Band", album: "LP", duration: 61.2)
        #expect(resolver.cacheKey(for: studio) == "band-lp-intro-61s.lrc")
        #expect(resolver.cacheKey(for: studio) != resolver.cacheKey(for: live))
        #expect(resolver.cacheKey(for: studio) == resolver.cacheKey(for: moved))

        let cueOne = AudioTrack(url: first.url, title: "Intro", trackNumber: 1, cueStart: 0, cueEnd: 61, source: .cue)
        let cueTwo = AudioTrack(url: first.url, title: "Intro", trackNumber: 9, cueStart: 500, cueEnd: 561, source: .cue)
        #expect(resolver.cacheKey(for: cueOne) != resolver.cacheKey(for: cueTwo))
    }
}
