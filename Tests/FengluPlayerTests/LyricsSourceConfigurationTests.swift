import Foundation
import Testing
@testable import FengluPlayer

struct LyricsSourceConfigurationTests {
    // A user may deliberately copy a previous default into any configuration source.
    private let copiedSourceList = "embedded,local,cache,lrclib-exact,lrclib-search,netease,qqmusic,lrcapi,kuwo,kugou,musixmatch,shazam,letrasboom,azlyrics,songlyrics,lyricsify,letras,lyricfind,bandcamp,darklyrics,metalarchives,genius"

    @Test func explicitListsArePreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("lyrics.conf")
        let environment = [LyricsConfiguration.configPathEnvironmentKey: configURL.path]
        let expected = copiedSourceList.components(separatedBy: ",")
        let resolver = LyricsResolver()

        #expect(resolver.configuredSourceNames(environment: environment, savedSourceList: nil)
            == LyricsConfiguration.defaultSourceList.components(separatedBy: ","))
        #expect(resolver.configuredSourceNames(environment: environment, savedSourceList: copiedSourceList) == expected)
        var explicitEnvironment = environment
        explicitEnvironment[LyricsConfiguration.sourceListEnvironmentKey] = copiedSourceList
        #expect(resolver.configuredSourceNames(environment: explicitEnvironment, savedSourceList: "local") == expected)
        try "sources=\(copiedSourceList)".write(to: configURL, atomically: true, encoding: .utf8)
        #expect(resolver.configuredSourceNames(environment: environment, savedSourceList: "local") == expected)
    }

    @Test(arguments: ["default", "defaults"])
    func currentDefaultsCanOverrideSavedLegacyList(_ defaultToken: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("lyrics.conf")
        let environment = [LyricsConfiguration.configPathEnvironmentKey: configURL.path]
        let legacySourceList = "local,cache,lrclib-exact,lrclib-search"
        let currentDefaults = LyricsConfiguration.defaultSourceList.components(separatedBy: ",")
        let resolver = LyricsResolver()

        #expect(resolver.configuredSourceNames(environment: environment, savedSourceList: legacySourceList)
            == legacySourceList.components(separatedBy: ","))
        try "sources=\(defaultToken)".write(to: configURL, atomically: true, encoding: .utf8)
        #expect(resolver.configuredSourceNames(environment: environment, savedSourceList: legacySourceList)
            == currentDefaults)
        try "sources=\(defaultToken),shazam".write(to: configURL, atomically: true, encoding: .utf8)
        #expect(resolver.configuredSourceNames(environment: environment, savedSourceList: legacySourceList)
            == currentDefaults + ["shazam"])
        try "sources=\(defaultToken),shazam,\(defaultToken),shazam".write(to: configURL, atomically: true, encoding: .utf8)
        #expect(resolver.configuredSourceNames(environment: environment, savedSourceList: legacySourceList)
            == currentDefaults + ["shazam"])
    }
}
