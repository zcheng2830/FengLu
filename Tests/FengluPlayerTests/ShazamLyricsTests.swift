import Foundation
import Testing
@testable import FengluPlayer

struct ShazamLyricsTests {
    @Test(arguments: ShazamPageFixture.allCases)
    func validatesDownloadedSongBeforeReturningLyrics(_ fixture: ShazamPageFixture) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShazamFixtureProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Lyrics-Fixture": fixture.rawValue]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if [.aliasedMetadata, .aliasedMetadataWithDifferentSearchTitle, .aliasedWhitespace].contains(fixture) {
            let aliasTitle = fixture == .aliasedWhitespace ? "Snow On The Beach" : fixture.title
            let aliases = [[aliasTitle, "Winter Shore"], [fixture.artist, "Artist Alias"]]
            try JSONEncoder().encode(aliases).write(to: directory.appendingPathComponent("snow.lyrics-aliases.json"))
        }
        if [.trackAliasOverridesWhitespace, .staleAliasAfterWhitespaceOverride].contains(fixture) {
            let aliases: [String: Any] = [
                "aliasGroups": [["Snow On The Beach", "Old Shore"], [fixture.artist, "Artist Alias"]],
                "tracks": ["4": ["aliasGroups": [["Snow  On\tThe Beach", "Winter Shore"]]]]
            ]
            try JSONSerialization.data(withJSONObject: aliases)
                .write(to: directory.appendingPathComponent("snow.lyrics-aliases.json"))
        }
        let track = AudioTrack(
            url: directory.appendingPathComponent(fixture.fileName),
            title: fixture.title,
            artist: fixture.localArtist,
            album: fixture.localAlbum,
            trackNumber: fixture.hasSparseTags || fixture == .artistlessWeakContext ? nil : 4,
            duration: fixture.hasSparseTags ? nil : 256.13
        )
        let result = await LyricsOnlineResolver(track: track, session: session)
            .lyrics(for: track, sourceNames: [fixture.sourceName])

        if fixture.shouldMatch {
            let resolution = try #require(result)
            #expect(resolution.sourceName == fixture.sourceName)
            #expect(resolution.rawLyrics == fixture.expectedLyrics)
        } else {
            #expect(result == nil)
        }
    }

    @Test(arguments: [true, false])
    func validatesHTMLTitleWhenArtistTagIsMissing(matchingTitle: Bool) throws {
        let track = AudioTrack(
            url: URL(fileURLWithPath: "/tmp/title-only.flac"),
            title: "Snow On The Beach",
            artist: nil,
            album: nil,
            trackNumber: nil,
            duration: 256.13
        )
        let title = matchingTitle ? "Snow On The Beach" : "Other Song"
        let html = "<html><head><title>Taylor Swift - \(title) Lyrics | Lyricsify</title></head></html>"
        let matches = LyricsOnlineResolver(track: track).htmlLyricsPageMatches(
            page: try LyricsHTMLPage(html),
            pageURL: URL(string: "https://www.lyricsify.com/recording/123")!,
            track: track,
            providerName: "Lyricsify"
        )
        #expect(matches == matchingTitle)
    }
}

enum ShazamPageFixture: String, CaseIterable, Sendable {
    case wrongSong
    case wrongSongSameArtist
    case wrongArtist
    case sharedArtistToken
    case similarSongTitle
    case artistNameWithUnrelatedSuffix
    case coverFeaturingOriginalArtist
    case artistMentionInTitle
    case missingMetadata
    case bodyOnlyMatch
    case conflictingMetadata
    case matchingTitle
    case matchingOpenGraph
    case matchingTwitter
    case matchingPunctuation
    case apostropheSong
    case apostropheArtist
    case doubleQuoteInSingleQuotedAttribute
    case featuredCreditMoved
    case remasteredSuffix
    case explicitSuffix
    case multipleArtists
    case artistWithHyphen
    case localizedSuffix
    case localizedStructuredMetadata
    case structuredArtistArray
    case wrongStructuredSong
    case wrongStructuredArtist
    case aliasedMetadata
    case sharedFeatureDifferentSong
    case substringTitle
    case coverJointCredit
    case colonDifferentPart
    case colonSamePart
    case lilNasX
    case florenceAndTheMachine
    case dataContentIgnored
    case dataContentCannotValidate
    case structuredSiblings
    case structuredMissingArtist
    case nestedMainEntity
    case nestedTrack
    case nestedItemList
    case structuredExcerpt
    case matchingRecommendationOnWrongPage
    case songLyricsHeading
    case songLyricsWrongSong
    case artistFirstCoverCredit
    case mainEntityReference
    case primaryCanonicalURL
    case incompleteWrongPrimary
    case wrongPrimaryDespiteMatchingHeading
    case unanchoredRecommendation
    case wrongSearchSelection
    case lyricsifyHeading
    case letrasHeading
    case matchingOpenGraphWithUnknownSuffix
    case htmlFeaturedArtistNotTagged
    case htmlCommaSeparatedArtists
    case htmlSlashSeparatedArtists
    case htmlReversedArtistOrder
    case htmlLiveVersion
    case htmlAlbumVersion
    case htmlDeluxeEdition
    case emptyOpenGraph
    case htmlEmptyOpenGraph
    case fragmentRecommendation
    case fragmentRecommendationOnWrongPage
    case ambiguousGraphWithFragmentRecommendation
    case aliasedMetadataWithDifferentSearchTitle
    case shazamReversedArtistOrder
    case shazamCommaSeparatedArtists
    case shazamLowercaseCommaSeparatedArtists
    case shazamBareSlashSeparatedArtists
    case shazamSlashSeparatedArtists
    case shazamDashRemaster
    case shazamSearchTaylorVersion
    case shazamSearchLiveVersion
    case shazamPageDashRemaster
    case shazamSearchCoverCredit
    case shazamExtraFeaturedCredit
    case artistWithLiteralSlash
    case artistWithLiteralComma
    case uppercaseArtistWithLiteralComma
    case partialSlashArtist
    case partialCommaArtist
    case uppercasePartialCommaArtist
    case matchingTitleOnlyOpenGraphWithSchema
    case titleOnlyOpenGraphWithoutSchema
    case wrongNonHyphenatedOpenGraph
    case duplicateCanonicalRecordings
    case conflictingCanonicalRecordings
    case localizedCanonicalURL
    case trailingSlashCanonicalURL
    case differentCanonicalSongID
    case shazamMissingArtist
    case shazamMissingArtistWrongPage
    case frenchHeadingCanonical
    case frenchHeadingMainEntity
    case frenchHeadingWithoutPrimary
    case frenchHeadingWrongSong
    case frenchHeadingWrongArtist
    case frenchHeadingRootWithoutAnchor
    case frenchHeadingNoSpaceColon
    case artistFirstUnknownSubtitle
    case andCreditToAmpersand
    case ampersandCreditToAnd
    case florencePartialArtist
    case trackCanonicalURL
    case scriptLocaleCanonicalURL
    case numericLocaleCanonicalURL
    case literalFeatTitle
    case literalFeatWrongSearchTitle
    case literalFTArtist
    case bracketedBareFeature
    case commaBareFeature
    case exactSecondSearchResult
    case wrongCanonicalIDWithMatchingIdentity
    case wrongOpenGraphIDWithMatchingIdentity
    case requestedIDAcrossLocale
    case byHeadingMainEntity
    case dotHeadingMainEntity
    case byHeadingWrongSong
    case studioTrackLivePage
    case studioTrackCleanPage
    case localLivePlainPage
    case localLiveMatchingPage
    case differentVersionLabels
    case featureBeforeLiveLabel
    case bandSoloPage
    case bandSoloSearchArtist
    case matchingBandCredit
    case rootArrayRecommendation
    case nestedAbout
    case nestedHasPart
    case nestedSubjectOf
    case structuredOverRomanisedBody
    case structuredPlaceholderFallback
    case unquotedWrongCanonicalID
    case unquotedWrongOpenGraphID
    case unquotedCanonicalAnchor
    case unquotedDataHrefIgnored
    case unquotedDataHrefCannotValidate
    case featuredHeadingWithShazamSuffix
    case headingWithShazamSuffix
    case artistFirstFrenchHeading
    case artistFirstFrenchWrongSong
    case artistFirstFrenchMainEntityOnly
    case standByMeLocalizedHeading
    case standByMeWithoutAnchor
    case arrayRecordingURLs
    case arrayRecordingURLsWrongID
    case arrayMainEntityOfPage
    case arrayMainEntityWrongArtist
    case relativeCanonicalAnchor
    case redirectedRelativeCanonicalAnchor
    case relativeWrongCanonicalID
    case aliasedWhitespace
    case duoSoloSearchArtist
    case duoSoloPage
    case fullDuoReorderedSearch
    case fullDuoReorderedPage
    case trackAliasOverridesWhitespace
    case staleAliasAfterWhitespaceOverride
    case fullLilNasXCredit
    case fullFlorenceCredit
    case fullCommaSeparatedCredit
    case fullSlashSeparatedCredit
    case filenameTitle
    case filenameWithoutTags
    case filenameWrongSearchTitle
    case filenameWrongPageTitle
    case commaContinuationSearchCredit
    case commaContinuationPageCredit
    case ampersandToCommaCredit
    case slashContinuationSearchCredit
    case slashContinuationPageCredit
    case ampersandToSlashCredit
    case structuredTheArtistArray
    case structuredAArtistArray
    case leadOnlyDuetCanonical
    case leadOnlyDuetOpenGraph
    case leadOnlyDuetWithoutID
    case leadOnlyDuetSearchSoloPageWithoutID
    case leadOnlyDuetWrongID
    case leadOnlyDuetPageCanonical
    case leadOnlyDuetMainEntityWithoutID
    case leadOnlyDuetStructuredCanonical
    case leadOnlyDuetReversedStructuredCanonical
    case leadOnlyDuetSearchSoloPageCanonical
    case leadOnlyDuetCoverSearchCredit
    case leadOnlyDuetCoverPageCredit
    case redirectedWrongSongID
    case redirectedWrongTrackID
    case redirectedWrongIDMatchingCanonical
    case redirectedMatchingSongID
    case bareApostropheMetaMatching
    case bareApostropheMetaWrongTitle
    case bareApostropheLinkMatching
    case bareApostropheLinkWrongCanonical
    case canonicalMissingArtistWithUnknownHeading
    case mainMissingArtistWithUnknownHeading
    case multipleCanonicalMissingArtist
    case multipleMainMissingArtist
    case multipleMissingArtistWrongTitle
    case multipleMissingArtistWrongArtist
    case anchoredMissingArtistUnknownHeading
    case multipleMissingArtistNeutralHeading
    case unidentifiedNestedRecommendation
    case radioEditLocalPlain
    case radioEditLocalMatching
    case radioEditRemoteSearch
    case radioEditRemotePage
    case singleVersionLocalPlain
    case singleVersionLocalMatching
    case singleVersionRemoteSearch
    case singleVersionRemotePage
    case acousticLocalPlain
    case acousticRemoteSearch
    case demoLocalPlain
    case demoRemotePage
    case bonusTrackLocalPlain
    case bonusTrackRemoteSearch
    case soundtrackLocalPlain
    case soundtrackRemotePage
    case literalFromTitle
    case trailingLyricsAnchored
    case trailingLyricsWrongSong
    case trailingLyricsWithoutSchema
    case featureBeforeDashLiveLabel
    case studioTrackFeatureBeforeDashLivePage
    case ambiguousUnanchoredRootRecordings
    case ambiguousUnanchoredNestedRecordings
    case artistlessAmbiguousTitle
    case artistlessUniqueTitle
    case artistlessContextSecondResult
    case artistlessContextTie
    case artistlessWeakContext
    case artistlessDuplicateResult
    case pipeHeadingSoleRoot
    case unknownHeadingSoleRoot
    case unknownHeadingWrongSoleRoot
    case unrelatedDashHeadingSoleRoot
    case unrelatedPipeHeadingSoleRoot
    case minifiedOpenGraphTitle
    case minifiedOpenGraphWrongTitle
    case minifiedCanonicalAnchor
    case minifiedCanonicalWrongID
    case minifiedOpenGraphWrongID
    case bareInlineFeat
    case bareInlineFT
    case remoteBareInlineFeat
    case remasteredCandidatePlainTag

    var hasSparseTags: Bool {
        [.filenameWithoutTags, .artistlessAmbiguousTitle, .artistlessUniqueTitle, .artistlessDuplicateResult].contains(self)
    }

    var localAlbum: String? {
        if hasSparseTags || self == .artistlessWeakContext { return nil }
        if [.artistlessContextSecondResult, .artistlessContextTie].contains(self) { return "Can't Slow Down" }
        return "Midnights (The Late Night Edition)"
    }

    var fileName: String {
        if [.artistlessAmbiguousTitle, .artistlessUniqueTitle, .artistlessDuplicateResult].contains(self) { return "Hello.flac" }
        return [.filenameTitle, .filenameWithoutTags, .filenameWrongSearchTitle, .filenameWrongPageTitle].contains(self)
            ? "Snow On The Beach.flac" : "snow.flac"
    }

    var searchTitle: String {
        switch self {
        case .artistlessAmbiguousTitle, .artistlessUniqueTitle, .artistlessContextSecondResult,
             .artistlessContextTie, .artistlessWeakContext, .artistlessDuplicateResult: "Hello"
        case .bareInlineFeat, .bareInlineFT: Self.song
        case .remoteBareInlineFeat: "Snow On The Beach feat Lana Del Rey"
        case .remasteredCandidatePlainTag: "Hotel California (2013 Remaster)"
        case .filenameTitle, .filenameWithoutTags, .filenameWrongPageTitle: "Snow On The Beach"
        case .filenameWrongSearchTitle: "Anti-Hero"
        case .wrongSearchSelection: "Song B"
        case .aliasedMetadataWithDifferentSearchTitle: "Snow On The Beach [Explicit]"
        case .shazamDashRemaster: "Snow On The Beach"
        case .shazamSearchTaylorVersion: "Snow On The Beach (Taylor's Version)"
        case .shazamSearchLiveVersion: "Snow On The Beach (Live)"
        case .literalFeatWrongSearchTitle: "A"
        case .localLivePlainPage: "Snow On The Beach"
        case .differentVersionLabels: "Snow On The Beach (Remastered)"
        case .featureBeforeLiveLabel: "Snow On The Beach (Live)"
        case .radioEditLocalPlain, .singleVersionLocalPlain, .acousticLocalPlain, .demoLocalPlain,
             .bonusTrackLocalPlain, .soundtrackLocalPlain:
            "Snow On The Beach"
        case .radioEditRemoteSearch: "Snow On The Beach (Radio Edit)"
        case .singleVersionRemoteSearch: "Snow On The Beach (Single Version)"
        case .acousticRemoteSearch: "Snow On The Beach (Acoustic)"
        case .bonusTrackRemoteSearch: "Snow On The Beach (Bonus Track)"
        case .featureBeforeDashLiveLabel: "Snow On The Beach (Live)"
        case .aliasedWhitespace, .trackAliasOverridesWhitespace: "Winter Shore"
        case .staleAliasAfterWhitespaceOverride: "Old Shore"
        default: title
        }
    }

    var localArtist: String? {
        [.shazamMissingArtist, .shazamMissingArtistWrongPage, .filenameWithoutTags,
         .artistlessAmbiguousTitle, .artistlessUniqueTitle, .artistlessContextSecondResult,
         .artistlessContextTie, .artistlessWeakContext, .artistlessDuplicateResult].contains(self) ? nil : artist
    }

    var searchResults: [[String: Any]] {
        if [.artistlessAmbiguousTitle, .artistlessUniqueTitle, .artistlessContextSecondResult,
            .artistlessContextTie, .artistlessWeakContext, .artistlessDuplicateResult].contains(self) {
            var adele: [String: Any] = ["trackId": 1650859889, "trackName": "Hello", "artistName": "Adele"]
            var lionel: [String: Any] = ["trackId": 111111, "trackName": "Hello", "artistName": "Lionel Richie"]
            if self == .artistlessUniqueTitle { lionel["trackName"] = "Other Song" }
            if self == .artistlessDuplicateResult { return [adele, adele] }
            if self == .artistlessWeakContext {
                adele["trackTimeMillis"] = 256130
                lionel["trackTimeMillis"] = 295000
            }
            if [.artistlessContextSecondResult, .artistlessContextTie].contains(self) {
                adele["collectionName"] = self == .artistlessContextTie ? "Can't Slow Down" : "25"
                adele["trackNumber"] = self == .artistlessContextTie ? 4 : 1
                adele["trackTimeMillis"] = self == .artistlessContextTie ? 256130 : 295000
                lionel["collectionName"] = "Can't Slow Down"
                lionel["trackNumber"] = 4
                lionel["trackTimeMillis"] = 256130
            }
            if self == .artistlessContextSecondResult {
                adele["trackId"] = 111111
                lionel["trackId"] = 1650859889
            }
            return [adele, lionel]
        }
        let result: [String: Any] = [
            "trackId": 1650859889, "trackName": searchTitle,
            "artistName": searchArtist, "collectionName": "Midnights (3am Edition)",
            "trackTimeMillis": 256130, "trackNumber": 4
        ]
        guard self == .exactSecondSearchResult else { return [result] }
        // Context makes the acoustic near-miss outrank the exact title under the
        // shared search heuristic. Identity filtering must run before selecting it.
        var acoustic = result
        acoustic["trackId"] = 111111
        acoustic["trackName"] = "Snow On The Beach (Acoustic)"
        acoustic["collectionName"] = "Midnights (The Late Night Edition)"
        let exact: [String: Any] = [
            "trackId": 1650859889, "trackName": title, "artistName": artist
        ]
        return [acoustic, exact]
    }

    var searchArtist: String {
        switch self {
        case .shazamReversedArtistOrder, .shazamCommaSeparatedArtists, .shazamSlashSeparatedArtists,
             .shazamLowercaseCommaSeparatedArtists, .shazamBareSlashSeparatedArtists:
            "Taylor Swift"
        case .shazamSearchCoverCredit: "Cover Band & Taylor Swift"
        case .partialSlashArtist: "AC"
        case .partialCommaArtist, .uppercasePartialCommaArtist: "Tyler"
        case .andCreditToAmpersand: "Simon & Garfunkel"
        case .ampersandCreditToAnd: "Simon and Garfunkel"
        case .florencePartialArtist: "Florence"
        case .featureBeforeLiveLabel, .featureBeforeDashLiveLabel:
            "Taylor Swift & Lana Del Rey"
        case .bandSoloSearchArtist: "Nick Cave"
        case .duoSoloSearchArtist: "Simon"
        case .fullDuoReorderedSearch: "Garfunkel & Simon"
        case .fullCommaSeparatedCredit, .fullSlashSeparatedCredit: "Lana Del Rey & Taylor Swift"
        case .commaContinuationSearchCredit: "Taylor Swift & The National"
        case .ampersandToCommaCredit: "Taylor Swift, The National"
        case .slashContinuationSearchCredit: "Lil Nas X & A Boogie wit da Hoodie"
        case .ampersandToSlashCredit: "Lil Nas X / A Boogie wit da Hoodie"
        case .leadOnlyDuetCanonical, .leadOnlyDuetOpenGraph, .leadOnlyDuetWithoutID,
             .leadOnlyDuetWrongID, .leadOnlyDuetMainEntityWithoutID, .leadOnlyDuetStructuredCanonical,
             .leadOnlyDuetSearchSoloPageWithoutID, .leadOnlyDuetReversedStructuredCanonical,
             .leadOnlyDuetSearchSoloPageCanonical:
            "Taylor Swift & Lana Del Rey"
        case .leadOnlyDuetCoverSearchCredit: "Cover Band & Taylor Swift"
        default: artist
        }
    }

    var sourceName: String {
        switch self {
        case .songLyricsHeading, .songLyricsWrongSong,
             .htmlFeaturedArtistNotTagged, .htmlCommaSeparatedArtists, .htmlSlashSeparatedArtists,
             .htmlReversedArtistOrder, .htmlLiveVersion, .htmlAlbumVersion, .htmlDeluxeEdition,
             .htmlEmptyOpenGraph:
            "songlyrics"
        case .lyricsifyHeading, .matchingOpenGraphWithUnknownSuffix: "lyricsify"
        case .letrasHeading: "letras"
        default: "shazam"
        }
    }

    static let song = "Snow On The Beach (feat. Lana Del Rey)"
    static let heading = "\(song) - Taylor Swift: Song Lyrics, Music Videos & Concerts"
    // Synthetic text keeps the test independent of live providers.
    static let lyrics = "A silver lantern lights the road\nThe quiet river carries on\nWe watch the distant morning glow\nA paper boat floats into view\nThe garden gate is open wide\nAnd every star returns to blue"

    var expectedLyrics: String {
        self == .structuredExcerpt
            ? Self.lyrics.components(separatedBy: "\n").prefix(4).joined(separator: "\n")
            : Self.lyrics
    }

    var title: String {
        switch self {
        case .artistlessAmbiguousTitle, .artistlessUniqueTitle, .artistlessDuplicateResult: ""
        case .artistlessContextSecondResult, .artistlessContextTie, .artistlessWeakContext: "Hello"
        case .bareInlineFeat: "Snow On The Beach feat Lana Del Rey"
        case .bareInlineFT: "Snow On The Beach ft Lana Del Rey"
        case .remasteredCandidatePlainTag: "Hotel California"
        case .filenameTitle, .filenameWithoutTags, .filenameWrongSearchTitle, .filenameWrongPageTitle: ""
        case .commaContinuationSearchCredit, .commaContinuationPageCredit, .ampersandToCommaCredit,
             .slashContinuationSearchCredit, .slashContinuationPageCredit, .ampersandToSlashCredit,
             .structuredTheArtistArray, .structuredAArtistArray,
             .leadOnlyDuetCanonical, .leadOnlyDuetOpenGraph, .leadOnlyDuetWithoutID,
             .leadOnlyDuetWrongID, .leadOnlyDuetPageCanonical, .leadOnlyDuetMainEntityWithoutID,
             .leadOnlyDuetStructuredCanonical, .leadOnlyDuetCoverSearchCredit, .leadOnlyDuetCoverPageCredit,
             .leadOnlyDuetSearchSoloPageWithoutID, .leadOnlyDuetReversedStructuredCanonical,
             .leadOnlyDuetSearchSoloPageCanonical:
            "Snow On The Beach"
        case .apostropheSong: "Don't Start Now"
        case .apostropheArtist: "One More Night"
        case .doubleQuoteInSingleQuotedAttribute: "The \"Night\""
        case .remasteredSuffix: "Snow On The Beach (Remastered)"
        case .explicitSuffix: "Snow On The Beach [Explicit]"
        case .aliasedMetadataWithDifferentSearchTitle: "Snow On The Beach (feat. Lana Del Rey) [Explicit]"
        case .sharedFeatureDifferentSong: "Song A (feat. Lil Wayne)"
        case .wrongSearchSelection: "Song A"
        case .substringTitle: "Hero"
        case .colonDifferentPart, .colonSamePart: "Rewrite: Part 1"
        case .htmlFeaturedArtistNotTagged, .shazamSearchTaylorVersion, .shazamSearchLiveVersion,
             .shazamPageDashRemaster, .shazamExtraFeaturedCredit:
            "Snow On The Beach"
        case .shazamDashRemaster: "Snow On The Beach - 2023 Remaster"
        case .htmlLiveVersion: "Snow On The Beach (Live)"
        case .htmlAlbumVersion: "Snow On The Beach (Album Version)"
        case .htmlDeluxeEdition: "Snow On The Beach [Deluxe Edition]"
        case .literalFeatTitle, .literalFeatWrongSearchTitle: "A Feat of Strength"
        case .bracketedBareFeature: "Snow On The Beach (feat Lana Del Rey)"
        case .exactSecondSearchResult: "Snow On The Beach"
        case .artistFirstUnknownSubtitle: "Rewrite"
        case .studioTrackLivePage, .studioTrackCleanPage: "Snow On The Beach"
        case .localLivePlainPage, .localLiveMatchingPage, .differentVersionLabels: "Snow On The Beach (Live)"
        case .featureBeforeLiveLabel: "Snow On The Beach feat. Lana Del Rey (Live)"
        case .radioEditLocalPlain, .radioEditLocalMatching: "Snow On The Beach (Radio Edit)"
        case .singleVersionLocalPlain, .singleVersionLocalMatching: "Snow On The Beach - Single Version"
        case .acousticLocalPlain: "Snow On The Beach (Acoustic)"
        case .demoLocalPlain: "Snow On The Beach - Demo"
        case .bonusTrackLocalPlain: "Snow On The Beach [Bonus Track]"
        case .soundtrackLocalPlain: "Snow On The Beach (From \"Example Film\")"
        case .literalFromTitle: "From Here to Eternity"
        case .radioEditRemoteSearch, .radioEditRemotePage, .singleVersionRemoteSearch, .singleVersionRemotePage,
             .acousticRemoteSearch, .demoRemotePage, .bonusTrackRemoteSearch, .soundtrackRemotePage,
             .trailingLyricsAnchored, .trailingLyricsWrongSong, .trailingLyricsWithoutSchema,
             .studioTrackFeatureBeforeDashLivePage:
            "Snow On The Beach"
        case .featureBeforeDashLiveLabel: "Snow On The Beach feat. Lana Del Rey - Live"
        case .standByMeLocalizedHeading, .standByMeWithoutAnchor: "Stand By Me"
        case .aliasedWhitespace, .trackAliasOverridesWhitespace, .staleAliasAfterWhitespaceOverride:
            "Snow  On\tThe Beach"
        case .duoSoloSearchArtist, .duoSoloPage, .fullDuoReorderedSearch, .fullDuoReorderedPage:
            "Winter Morning"
        default: Self.song
        }
    }

    var artist: String {
        switch self {
        case .artistlessAmbiguousTitle, .artistlessUniqueTitle, .artistlessContextTie,
             .artistlessWeakContext, .artistlessDuplicateResult: "Adele"
        case .artistlessContextSecondResult: "Lionel Richie"
        case .remasteredCandidatePlainTag: "Eagles"
        case .commaContinuationSearchCredit, .commaContinuationPageCredit, .structuredTheArtistArray:
            "Taylor Swift, The National"
        case .ampersandToCommaCredit: "Taylor Swift & The National"
        case .slashContinuationSearchCredit, .slashContinuationPageCredit, .structuredAArtistArray:
            "Lil Nas X / A Boogie wit da Hoodie"
        case .ampersandToSlashCredit: "Lil Nas X & A Boogie wit da Hoodie"
        case .apostropheSong: "Dua Lipa"
        case .apostropheArtist: "D'Angelo"
        case .doubleQuoteInSingleQuotedAttribute: "Test Artist"
        case .multipleArtists, .structuredArtistArray: "Taylor Swift & Lana Del Rey"
        case .artistWithHyphen: "Band - Name"
        case .lilNasX, .fullLilNasXCredit: "Lil Nas X & Jack Harlow"
        case .florenceAndTheMachine, .fullFlorenceCredit: "Florence and the Machine & Test Artist"
        case .htmlCommaSeparatedArtists, .shazamCommaSeparatedArtists, .fullCommaSeparatedCredit: "Taylor Swift, Lana Del Rey"
        case .shazamLowercaseCommaSeparatedArtists: "taylor swift, lana del rey"
        case .shazamBareSlashSeparatedArtists: "Taylor Swift/Lana Del Rey"
        case .htmlSlashSeparatedArtists, .shazamSlashSeparatedArtists, .fullSlashSeparatedCredit: "Taylor Swift / Lana Del Rey"
        case .htmlReversedArtistOrder, .shazamReversedArtistOrder: "Lana Del Rey & Taylor Swift"
        case .artistWithLiteralSlash, .partialSlashArtist: "AC/DC"
        case .artistWithLiteralComma, .partialCommaArtist: "Tyler, the Creator"
        case .uppercaseArtistWithLiteralComma, .uppercasePartialCommaArtist: "TYLER, THE CREATOR"
        case .andCreditToAmpersand: "Simon and Garfunkel"
        case .ampersandCreditToAnd: "Simon & Garfunkel"
        case .florencePartialArtist: "Florence and the Machine"
        case .literalFTArtist: "FT Island"
        case .commaBareFeature: "Taylor Swift, feat Lana Del Rey"
        case .bandSoloPage, .bandSoloSearchArtist, .matchingBandCredit: "Nick Cave & The Bad Seeds"
        case .duoSoloSearchArtist, .duoSoloPage, .fullDuoReorderedSearch, .fullDuoReorderedPage:
            "Simon & Garfunkel"
        default: "Taylor Swift"
        }
    }

    var shouldMatch: Bool {
        if sourceName != "shazam" { return self != .songLyricsWrongSong }
        // Legacy pages stay unchanged: heading-only, incomplete, and unanchored
        // evidence now rejects. Accepted-path identity coverage lives in the
        // independent ShazamEvidenceTests table, with explicit page recordings.
        return [
            .minifiedCanonicalAnchor, .bareApostropheLinkMatching,
            .trailingLyricsAnchored, .trailingLyricsWrongSong,
            .leadOnlyDuetStructuredCanonical, .leadOnlyDuetReversedStructuredCanonical,
            .requestedIDAcrossLocale, .artistFirstFrenchHeading, .artistFirstFrenchWrongSong,
            .unquotedCanonicalAnchor, .unquotedDataHrefIgnored,
            .relativeCanonicalAnchor, .redirectedRelativeCanonicalAnchor,
            .frenchHeadingCanonical, .frenchHeadingNoSpaceColon,
            .duplicateCanonicalRecordings, .localizedCanonicalURL, .trailingSlashCanonicalURL,
            .trackCanonicalURL, .scriptLocaleCanonicalURL, .numericLocaleCanonicalURL,
            .primaryCanonicalURL
        ].contains(self)
    }

    var html: String {
        let metadata: String
        switch self {
        case .ambiguousUnanchoredRootRecordings, .ambiguousUnanchoredNestedRecordings:
            let recording: [String: Any] = [
                "@type": "MusicRecording", "name": title, "byArtist": artist,
                "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            var other = recording
            other["recordingOf"] = ["lyrics": ["text": "A different singer takes the stage\nThe curtains shimmer in the light\nA painted doorway swings around\nThe quiet crowd begins to sway\nThe evening lantern casts a glow\nA story ends another way"]]
            let root: [String: Any] = self == .ambiguousUnanchoredRootRecordings
                ? ["@graph": [recording, other]] : ["@type": "MusicAlbum", "track": [recording, other]]
            let json = String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
            metadata = "<title>\(Self.heading)</title><script type='application/ld+json'>\(json)</script>"
        case .artistlessAmbiguousTitle, .artistlessUniqueTitle, .artistlessContextSecondResult,
             .artistlessContextTie, .artistlessWeakContext, .artistlessDuplicateResult:
            metadata = "<title>Hello - \(artist): Song Lyrics</title>"
        case .pipeHeadingSoleRoot, .unknownHeadingSoleRoot, .unknownHeadingWrongSoleRoot,
             .unrelatedDashHeadingSoleRoot, .unrelatedPipeHeadingSoleRoot:
            let recording: [String: Any] = [
                "@type": "MusicRecording", "name": self == .unknownHeadingWrongSoleRoot ? "Other Song" : title,
                "byArtist": artist, "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            let json = String(data: try! JSONSerialization.data(withJSONObject: recording), encoding: .utf8)!
            let heading = self == .pipeHeadingSoleRoot ? "\(title) | \(artist)" :
                self == .unrelatedDashHeadingSoleRoot ? "Other Song - Other Artist" :
                self == .unrelatedPipeHeadingSoleRoot ? "Other Song | Other Artist" : "Discover this recording"
            metadata = "<title>\(heading)</title><script type='application/ld+json'>\(json)</script>"
        case .minifiedOpenGraphTitle:
            metadata = "<meta property=\"og:title\"content=\"\(Self.heading)\">"
        case .minifiedOpenGraphWrongTitle:
            metadata = "<title>\(Self.heading)</title><meta property='og:title'content='Other Song - Taylor Swift'>"
        case .minifiedCanonicalAnchor:
            let canonical = "https://www.shazam.com/song/1650859889/requested-song"
            let recording: [String: Any] = [
                "@type": "MusicRecording", "name": title, "byArtist": artist, "url": canonical,
                "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            let unrelated: [String: Any] = ["@type": "MusicRecording", "name": "Other Song", "byArtist": "Other Artist"]
            let json = String(data: try! JSONSerialization.data(withJSONObject: ["@graph": [unrelated, recording]]), encoding: .utf8)!
            metadata = "<title>歌曲資訊</title><link rel=\"canonical\"href=\"\(canonical)\"><script type='application/ld+json'>\(json)</script>"
        case .minifiedCanonicalWrongID:
            metadata = "<title>\(Self.heading)</title><link rel='canonical'href='https://www.shazam.com/song/999999/wrong-song'>"
        case .minifiedOpenGraphWrongID:
            metadata = "<title>\(Self.heading)</title><meta property=\"og:url\"content=\"https://www.shazam.com/song/999999/wrong-song\">"
        case .bareInlineFeat, .bareInlineFT:
            metadata = "<title>\(Self.heading)</title>"
        case .remoteBareInlineFeat:
            metadata = "<title>Snow On The Beach feat Lana Del Rey - Taylor Swift: Song Lyrics</title>"
        case .remasteredCandidatePlainTag:
            metadata = "<title>Hotel California (2013 Remaster) - Eagles: Song Lyrics</title>"
        case .redirectedWrongSongID, .redirectedWrongTrackID, .redirectedWrongIDMatchingCanonical,
             .redirectedMatchingSongID:
            let recording: [String: Any] = [
                "@type": "MusicRecording", "name": title, "byArtist": artist,
                "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            let json = String(data: try! JSONSerialization.data(withJSONObject: recording), encoding: .utf8)!
            let canonical = self == .redirectedWrongIDMatchingCanonical
                ? "<link rel='canonical' href='https://www.shazam.com/song/1650859889/requested-song'>" : ""
            metadata = "<title>歌曲資訊</title>\(canonical)<script type='application/ld+json'>\(json)</script>"
        case .bareApostropheMetaMatching, .bareApostropheMetaWrongTitle:
            let heading = self == .bareApostropheMetaWrongTitle ? "Other Song - Taylor Swift: Song Lyrics" : Self.heading
            let recording: [String: Any] = [
                "@type": "MusicRecording", "name": title, "byArtist": artist,
                "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            let root: [String: Any] = ["@type": "WebPage", "mainEntity": recording]
            let json = String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
            let schema = self == .bareApostropheMetaWrongTitle ? "<script type='application/ld+json'>\(json)</script>" : ""
            metadata = """
            <meta name=description content=Taylor's new single>
            <meta property="og:title" content="\(heading)">
            <meta name=note content=artist's>
            \(schema)
            """
        case .bareApostropheLinkMatching, .bareApostropheLinkWrongCanonical:
            let canonicalURL = "https://www.shazam.com/song/1650859889/requested-song"
            let href = self == .bareApostropheLinkWrongCanonical
                ? "https://www.shazam.com/song/999999/other-song" : canonicalURL
            let recording: [String: Any] = [
                "@type": "MusicRecording", "name": title, "byArtist": artist, "url": canonicalURL,
                "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            let unrelated: [String: Any] = ["@type": "MusicRecording", "name": "Other Song", "byArtist": "Other Artist"]
            let root: [String: Any] = self == .bareApostropheLinkMatching ? ["@graph": [unrelated, recording]] : recording
            let json = String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
            let heading = self == .bareApostropheLinkMatching ? "歌曲資訊" : Self.heading
            metadata = """
            <title>\(heading)</title>
            <link rel=stylesheet title=Taylor's>
            <link rel="canonical" href="\(href)">
            <link rel=stylesheet title=artist's>
            <script type='application/ld+json'>\(json)</script>
            """
        case .canonicalMissingArtistWithUnknownHeading, .mainMissingArtistWithUnknownHeading,
             .multipleCanonicalMissingArtist, .multipleMainMissingArtist,
             .multipleMissingArtistWrongTitle, .multipleMissingArtistWrongArtist,
             .anchoredMissingArtistUnknownHeading, .multipleMissingArtistNeutralHeading:
            let canonicalURL = "https://www.shazam.com/song/1650859889/requested-song"
            let recording: [String: Any] = [
                "@type": "MusicRecording", "name": title, "url": canonicalURL,
                "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            var other = recording
            if self == .multipleMissingArtistWrongTitle { other["name"] = "Other Song" }
            if self == .multipleMissingArtistWrongArtist { other["byArtist"] = "Other Artist" }
            let isSingle = [.canonicalMissingArtistWithUnknownHeading, .mainMissingArtistWithUnknownHeading,
                            .anchoredMissingArtistUnknownHeading].contains(self)
            let recordings = isSingle ? [recording] : [recording, other]
            let isMain = [.mainMissingArtistWithUnknownHeading, .multipleMainMissingArtist].contains(self)
            let root: [String: Any] = isMain ? ["@type": "WebPage", "mainEntity": recordings] : ["@graph": recordings]
            let json = String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
            let heading = self == .anchoredMissingArtistUnknownHeading ? "Explore this recording" :
                self == .multipleMissingArtistNeutralHeading ? "歌曲資訊" : Self.heading
            let unknownHeading = [.canonicalMissingArtistWithUnknownHeading, .mainMissingArtistWithUnknownHeading].contains(self)
                ? "<meta property='og:title' content='Explore this recording'>" : ""
            let canonical = isMain ? "" : "<link rel='canonical' href='\(canonicalURL)'>"
            metadata = "<title>\(heading)</title>\(unknownHeading)\(canonical)<script type='application/ld+json'>\(json)</script>"
        case .unidentifiedNestedRecommendation:
            let unrelatedLyrics = "A different road winds through the town\nThe clock has stopped beside the square\nWe turn away before the dawn\nA passing stranger calls our names\nThe winter clouds conceal the moon\nNo lantern marks the journey home"
            let recommendation: [String: Any] = [
                "@type": "MusicRecording", "recordingOf": ["lyrics": ["text": unrelatedLyrics]]
            ]
            let root: [String: Any] = ["@type": "MusicAlbum", "hasPart": [recommendation]]
            let json = String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
            metadata = "<title>\(Self.heading)</title><script type='application/ld+json'>\(json)</script>"
        case .radioEditLocalPlain, .singleVersionLocalPlain, .acousticLocalPlain, .demoLocalPlain,
             .bonusTrackLocalPlain, .soundtrackLocalPlain:
            metadata = "<title>Snow On The Beach - Taylor Swift: Song Lyrics</title>"
        case .radioEditLocalMatching, .radioEditRemoteSearch, .radioEditRemotePage:
            metadata = "<title>Snow On The Beach (Radio Edit) - Taylor Swift: Song Lyrics</title>"
        case .singleVersionLocalMatching, .singleVersionRemoteSearch, .singleVersionRemotePage:
            metadata = "<title>Snow On The Beach - Single Version - Taylor Swift: Song Lyrics</title>"
        case .acousticRemoteSearch:
            metadata = "<title>Snow On The Beach (Acoustic) - Taylor Swift: Song Lyrics</title>"
        case .demoRemotePage:
            metadata = "<title>Snow On The Beach - Demo - Taylor Swift: Song Lyrics</title>"
        case .bonusTrackRemoteSearch:
            metadata = "<title>Snow On The Beach [Bonus Track] - Taylor Swift: Song Lyrics</title>"
        case .soundtrackRemotePage:
            metadata = "<title>Snow On The Beach (From &quot;Example Film&quot;) - Taylor Swift: Song Lyrics</title>"
        case .literalFromTitle:
            metadata = "<title>From Here to Eternity - Taylor Swift: Song Lyrics</title>"
        case .trailingLyricsAnchored, .trailingLyricsWrongSong, .trailingLyricsWithoutSchema:
            let recording: [String: Any] = [
                "@type": "MusicRecording", "name": title, "byArtist": artist,
                "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            let root: [String: Any] = ["@type": "WebPage", "mainEntity": recording]
            let json = String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
            let schema = self == .trailingLyricsWithoutSchema ? "" : "<script type='application/ld+json'>\(json)</script>"
            let headingTitle = self == .trailingLyricsWrongSong ? "Other Song" : title
            metadata = "<title>\(headingTitle) Lyrics - Taylor Swift</title><link rel='canonical' href='https://www.shazam.com/song/1650859889/requested-song'>\(schema)"
        case .featureBeforeDashLiveLabel:
            metadata = "<title>Snow On The Beach (Live) - Taylor Swift &amp; Lana Del Rey: Song Lyrics</title>"
        case .studioTrackFeatureBeforeDashLivePage:
            metadata = "<title>Snow On The Beach feat. Lana Del Rey - Live - Taylor Swift: Song Lyrics</title>"
        case .filenameTitle, .filenameWithoutTags, .leadOnlyDuetSearchSoloPageWithoutID:
            metadata = "<title>Snow On The Beach - Taylor Swift: Song Lyrics</title>"
        case .filenameWrongSearchTitle, .filenameWrongPageTitle:
            metadata = "<title>Anti-Hero - Taylor Swift: Song Lyrics</title>"
        case .leadOnlyDuetSearchSoloPageCanonical:
            metadata = "<title>\(title) - Taylor Swift: Song Lyrics</title><link rel='canonical' href='https://www.shazam.com/song/1650859889/duet'>"
        case .commaContinuationSearchCredit, .commaContinuationPageCredit:
            metadata = "<title>\(title) - Taylor Swift &amp; The National: Song Lyrics</title>"
        case .ampersandToCommaCredit:
            metadata = "<title>\(title) - Taylor Swift, The National: Song Lyrics</title>"
        case .slashContinuationSearchCredit, .slashContinuationPageCredit:
            metadata = "<title>\(title) - Lil Nas X &amp; A Boogie wit da Hoodie: Song Lyrics</title>"
        case .ampersandToSlashCredit:
            metadata = "<title>\(title) - Lil Nas X / A Boogie wit da Hoodie: Song Lyrics</title>"
        case .structuredTheArtistArray, .structuredAArtistArray, .leadOnlyDuetMainEntityWithoutID,
             .leadOnlyDuetStructuredCanonical, .leadOnlyDuetReversedStructuredCanonical:
            let names = self == .structuredTheArtistArray ? ["Taylor Swift", "The National"]
                : self == .structuredAArtistArray ? ["Lil Nas X", "A Boogie wit da Hoodie"]
                : self == .leadOnlyDuetReversedStructuredCanonical ? ["Lana Del Rey", "Taylor Swift"]
                : ["Taylor Swift", "Lana Del Rey"]
            let recording: [String: Any] = [
                "@type": "MusicRecording", "name": title,
                "byArtist": names.map { ["@type": "MusicGroup", "name": $0] },
                "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            let root: [String: Any] = ["@type": "WebPage", "mainEntity": recording]
            let json = String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
            let canonical = [.leadOnlyDuetStructuredCanonical, .leadOnlyDuetReversedStructuredCanonical].contains(self)
                ? "<link rel='canonical' href='https://www.shazam.com/song/1650859889/duet'>" : ""
            metadata = "<title>歌曲資訊</title>\(canonical)<script type='application/ld+json'>\(json)</script>"
        case .leadOnlyDuetCanonical, .leadOnlyDuetOpenGraph, .leadOnlyDuetWithoutID,
             .leadOnlyDuetWrongID, .leadOnlyDuetPageCanonical,
             .leadOnlyDuetCoverSearchCredit, .leadOnlyDuetCoverPageCredit:
            let credit = [.leadOnlyDuetCoverSearchCredit, .leadOnlyDuetCoverPageCredit].contains(self)
                ? "Cover Band &amp; Taylor Swift" : "Taylor Swift &amp; Lana Del Rey"
            let pageID = self == .leadOnlyDuetWrongID ? "999999" : "1650859889"
            let identityURL = "https://www.shazam.com/song/\(pageID)/duet"
            let anchor = self == .leadOnlyDuetWithoutID ? ""
                : self == .leadOnlyDuetOpenGraph ? "<meta property='og:url' content='\(identityURL)'>"
                : "<link rel='canonical' href='\(identityURL)'>"
            metadata = "<title>\(title) - \(credit): Song Lyrics</title>\(anchor)"
        case .wrongSong:
            metadata = "<title>FREAKED OUT - Fat Papi &amp; prodshushy: Song Lyrics, Music Videos &amp; Concerts</title>"
        case .wrongSongSameArtist:
            metadata = "<title>Anti-Hero - Taylor Swift: Song Lyrics, Music Videos &amp; Concerts</title>"
        case .wrongArtist:
            metadata = "<title>\(Self.song) - Someone Else: Song Lyrics, Music Videos &amp; Concerts</title>"
        case .sharedArtistToken:
            metadata = "<title>\(Self.song) - Taylor Someone: Song Lyrics, Music Videos &amp; Concerts</title>"
        case .similarSongTitle:
            metadata = "<title>Snow On The Mountain - Taylor Swift: Song Lyrics</title>"
        case .artistNameWithUnrelatedSuffix:
            metadata = "<title>\(Self.song) - Taylor Swift Tribute Orchestra: Song Lyrics</title>"
        case .coverFeaturingOriginalArtist:
            metadata = "<title>\(Self.song) - Cover Band feat. Taylor Swift: Song Lyrics</title>"
        case .artistMentionInTitle:
            metadata = "<title>\(Self.song) (Originally Performed by Taylor Swift) - Cover Band: Song Lyrics</title>"
        case .missingMetadata, .bodyOnlyMatch:
            metadata = ""
        case .conflictingMetadata:
            metadata = """
            <meta property="og:title" content="\(Self.heading)">
            <title>Anti-Hero - Taylor Swift: Song Lyrics</title>
            """
        case .matchingTitle, .shazamReversedArtistOrder, .shazamCommaSeparatedArtists,
             .shazamSlashSeparatedArtists, .shazamLowercaseCommaSeparatedArtists,
             .shazamBareSlashSeparatedArtists, .shazamSearchCoverCredit, .shazamMissingArtist,
             .bracketedBareFeature, .commaBareFeature, .exactSecondSearchResult:
            metadata = "<title>\(Self.heading)</title>"
        case .wrongOpenGraphIDWithMatchingIdentity:
            metadata = "<title>\(Self.heading)</title><meta property='og:url' content='https://www.shazam.com/song/999999/same-song'>"
        case .unquotedWrongCanonicalID, .unquotedDataHrefCannotValidate, .relativeWrongCanonicalID:
            let wrongURL = self == .relativeWrongCanonicalID
                ? "../999999/wrong-song" : "https://www.shazam.com/song/999999/wrong-song"
            let extra = self == .unquotedDataHrefCannotValidate
                ? "data-href=https://www.shazam.com/song/1650859889/requested-song " : ""
            metadata = "<title>\(Self.heading)</title><link rel=canonical \(extra)href=\(wrongURL)>"
        case .unquotedWrongOpenGraphID:
            metadata = "<title>\(Self.heading)</title><meta property=og:url content=https://www.shazam.com/song/999999/wrong-song>"
        case .studioTrackLivePage:
            metadata = "<title>Snow On The Beach (Live) - Taylor Swift: Song Lyrics</title>"
        case .studioTrackCleanPage:
            metadata = "<title>Snow On The Beach (Clean) - Taylor Swift: Song Lyrics</title>"
        case .localLivePlainPage:
            metadata = "<title>Snow On The Beach - Taylor Swift: Song Lyrics</title>"
        case .localLiveMatchingPage:
            metadata = "<title>Snow On The Beach (Live) - Taylor Swift: Song Lyrics</title>"
        case .differentVersionLabels:
            metadata = "<title>Snow On The Beach (Remastered) - Taylor Swift: Song Lyrics</title>"
        case .featureBeforeLiveLabel:
            metadata = "<title>Snow On The Beach (Live) - Taylor Swift &amp; Lana Del Rey: Song Lyrics</title>"
        case .bandSoloPage, .bandSoloSearchArtist:
            metadata = "<title>\(title) - Nick Cave: Song Lyrics</title>"
        case .matchingBandCredit:
            metadata = "<title>\(title) - Nick Cave &amp; The Bad Seeds: Song Lyrics</title>"
        case .duoSoloSearchArtist, .duoSoloPage:
            metadata = "<title>\(title) - Simon: Song Lyrics</title>"
        case .fullDuoReorderedSearch:
            metadata = "<title>\(title) - Simon &amp; Garfunkel: Song Lyrics</title>"
        case .fullDuoReorderedPage:
            metadata = "<title>\(title) - Garfunkel &amp; Simon: Song Lyrics</title>"
        case .fullLilNasXCredit, .fullFlorenceCredit:
            metadata = "<title>\(title) - \(artist): Song Lyrics</title>"
        case .fullCommaSeparatedCredit, .fullSlashSeparatedCredit:
            metadata = "<title>\(title) - Lana Del Rey &amp; Taylor Swift: Song Lyrics</title>"
        case .byHeadingMainEntity, .dotHeadingMainEntity, .byHeadingWrongSong:
            let recording: [String: Any] = [
                "@type": "MusicRecording", "name": title, "byArtist": artist,
                "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            let root: [String: Any] = ["@type": "WebPage", "mainEntity": recording]
            let json = String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
            let heading = self == .dotHeadingMainEntity ? "\(title) · \(artist) · Shazam" :
                self == .byHeadingWrongSong ? "Other Song by \(artist)" : "\(title) by \(artist)"
            metadata = "<title>\(heading)</title><script type='application/ld+json'>\(json)</script>"
        case .wrongCanonicalIDWithMatchingIdentity, .requestedIDAcrossLocale:
            let canonicalURL = self == .wrongCanonicalIDWithMatchingIdentity
                ? "https://www.shazam.com/song/999999/same-song"
                : "https://www.shazam.com/zh-Hant/song/1650859889/same-song/"
            let recording: [String: Any] = [
                "@type": "MusicRecording", "name": title, "byArtist": artist, "url": canonicalURL,
                "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            let json = String(data: try! JSONSerialization.data(withJSONObject: recording), encoding: .utf8)!
            metadata = "<title>\(Self.heading)</title><link rel='canonical' href='\(canonicalURL)'><script type='application/ld+json'>\(json)</script>"
        case .shazamMissingArtistWrongPage:
            metadata = "<title>\(title) - Other Artist: Song Lyrics</title>"
        case .andCreditToAmpersand, .ampersandCreditToAnd, .florencePartialArtist:
            metadata = "<title>\(title) - \(searchArtist): Song Lyrics</title>"
        case .literalFeatTitle, .literalFTArtist:
            metadata = "<title>\(title) - \(artist): Song Lyrics</title>"
        case .literalFeatWrongSearchTitle:
            metadata = "<title>A - \(artist): Song Lyrics</title>"
        case .shazamDashRemaster, .shazamSearchTaylorVersion, .shazamSearchLiveVersion:
            metadata = "<title>Snow On The Beach - Taylor Swift: Song Lyrics</title>"
        case .shazamPageDashRemaster:
            metadata = "<title>Snow On The Beach - 2023 Remaster - Taylor Swift: Song Lyrics</title>"
        case .shazamExtraFeaturedCredit:
            metadata = "<title>Snow On The Beach - Taylor Swift feat. Lana Del Rey: Song Lyrics</title>"
        case .artistWithLiteralSlash, .artistWithLiteralComma, .partialSlashArtist, .partialCommaArtist,
             .uppercaseArtistWithLiteralComma, .uppercasePartialCommaArtist:
            metadata = "<title>\(title) - \(artist): Song Lyrics</title>"
        case .titleOnlyOpenGraphWithoutSchema:
            metadata = "<meta property='og:title' content='Snow On The Beach'>"
        case .matchingOpenGraph:
            metadata = "<meta content='\(Self.heading)' property='og:title'>"
        case .emptyOpenGraph, .htmlEmptyOpenGraph:
            metadata = """
            <meta property='og:title' content=''>
            <meta property='og:title' content='\(Self.heading)'>
            """
        case .matchingTwitter:
            metadata = "<meta name='twitter:title' content='\(Self.heading)'>"
        case .matchingPunctuation:
            metadata = "<title>SNOW ON THE BEACH (feat. Lana Del Rey) - Taylor&#32;Swift: Song Lyrics</title>"
        case .apostropheSong, .apostropheArtist:
            metadata = "<meta property=\"og:title\" content=\"\(title) - \(artist): Song Lyrics\">"
        case .doubleQuoteInSingleQuotedAttribute:
            metadata = "<meta content='\(title) - \(artist): Song Lyrics' property='og:title'>"
        case .featuredCreditMoved:
            metadata = "<title>Snow On The Beach - Taylor Swift Feat. Lana Del Rey: Song Lyrics</title>"
        case .remasteredSuffix, .explicitSuffix:
            metadata = "<title>Snow On The Beach - Taylor Swift: Song Lyrics</title>"
        case .multipleArtists:
            metadata = "<title>\(title) - Lana Del Rey &amp; Taylor Swift | Letras y vídeos</title>"
        case .artistWithHyphen:
            metadata = "<title>\(title) - Band - Name: Song Lyrics</title>"
        case .localizedSuffix:
            metadata = "<title>\(title) - \(artist)：歌詞、音樂影片和演唱會</title>"
        case .localizedStructuredMetadata, .structuredArtistArray, .wrongStructuredSong, .wrongStructuredArtist:
            let songName = self == .wrongStructuredSong ? "Anti-Hero" : "Snow On The Beach"
            let artists: Any = self == .wrongStructuredArtist ? "Someone Else" :
                self == .structuredArtistArray ? [["name": "Lana Del Rey"], ["name": "Taylor Swift"]] : artist
            let recording: [String: Any] = [
                "@type": "MusicRecording", "name": songName, "byArtist": artists,
                "recordingOf": ["lyrics": ["@type": "CreativeWork", "text": Self.lyrics]]
            ]
            let json = String(data: try! JSONSerialization.data(withJSONObject: ["@graph": [recording]]), encoding: .utf8)!
            metadata = "<title>歌曲資訊</title><script type='application/ld+json'>\(json)</script>"
        case .aliasedMetadata:
            metadata = "<title>Winter Shore - Artist Alias: Song Lyrics</title>"
        case .aliasedMetadataWithDifferentSearchTitle:
            metadata = "<title>Winter Shore (feat. Lana Del Rey) - Artist Alias: Song Lyrics</title>"
        case .aliasedWhitespace, .trackAliasOverridesWhitespace:
            metadata = "<title>Winter Shore - Artist Alias: Song Lyrics</title>"
        case .staleAliasAfterWhitespaceOverride:
            metadata = "<title>Old Shore - Artist Alias: Song Lyrics</title>"
        case .sharedFeatureDifferentSong:
            metadata = "<title>Song B (feat. Lil Wayne) - \(artist): Song Lyrics</title>"
        case .wrongSearchSelection:
            metadata = "<title>Song B - \(artist): Song Lyrics</title>"
        case .substringTitle:
            metadata = "<title>Anti-Hero - \(artist): Song Lyrics</title>"
        case .coverJointCredit:
            metadata = "<title>\(title) - Cover Band &amp; Taylor Swift: Song Lyrics</title>"
        case .colonDifferentPart:
            metadata = "<title>\(artist) - Rewrite: Part 2: Song Lyrics</title>"
        case .colonSamePart:
            metadata = "<title>\(artist) - Rewrite: Part 1: Song Lyrics</title>"
        case .lilNasX:
            metadata = "<title>\(title) - Lil Nas X: Song Lyrics</title>"
        case .florenceAndTheMachine:
            metadata = "<title>\(title) - Florence and the Machine: Song Lyrics</title>"
        case .dataContentIgnored:
            metadata = "<meta property='og:title' data-content='Wrong Song - Wrong Artist' content='\(Self.heading)'>"
        case .dataContentCannotValidate:
            metadata = "<meta property='og:title' data-content='\(Self.heading)' content='Wrong Song - Wrong Artist'>"
        case .songLyricsHeading:
            metadata = "<title>\(artist) - \(title) LYRICS</title>"
        case .songLyricsWrongSong:
            metadata = "<title>\(artist) - Anti-Hero LYRICS</title>"
        case .artistFirstCoverCredit:
            metadata = "<title>Cover Band &amp; Taylor Swift - \(title): Song Lyrics</title>"
        case .lyricsifyHeading:
            metadata = "<title>\(artist) - \(title) Lyrics | Lyricsify</title>"
        case .letrasHeading:
            metadata = "<title>\(title) - \(artist) - LETRAS.COM</title>"
        case .matchingOpenGraphWithUnknownSuffix:
            metadata = """
            <meta property='og:title' content='\(Self.heading)'>
            <title>\(artist) - \(title) Lyrics | A New Provider Suffix</title>
            """
        case .htmlFeaturedArtistNotTagged:
            metadata = "<title>Taylor Swift feat. Lana Del Rey - Snow On The Beach LYRICS</title>"
        case .htmlCommaSeparatedArtists, .htmlSlashSeparatedArtists, .htmlReversedArtistOrder:
            metadata = "<title>Taylor Swift - \(title) LYRICS</title>"
        case .htmlLiveVersion, .htmlAlbumVersion, .htmlDeluxeEdition:
            metadata = "<title>Taylor Swift - Snow On The Beach LYRICS</title>"
        case .matchingTitleOnlyOpenGraphWithSchema, .wrongNonHyphenatedOpenGraph:
            let excerpt = Self.lyrics.components(separatedBy: "\n").prefix(4).joined(separator: "\n")
            let recording: [String: Any] = [
                "@type": "MusicRecording", "name": title, "byArtist": artist,
                "recordingOf": ["lyrics": ["text": self == .wrongNonHyphenatedOpenGraph ? excerpt : Self.lyrics]]
            ]
            let json = String(data: try! JSONSerialization.data(withJSONObject: recording), encoding: .utf8)!
            let pageTitle = self == .wrongNonHyphenatedOpenGraph ? "Other Song by Other Artist" : "Snow On The Beach"
            metadata = "<meta property='og:title' content='\(pageTitle)'><script type='application/ld+json'>\(json)</script>"
        case .artistFirstUnknownSubtitle:
            let recording: [String: Any] = [
                "@type": "MusicRecording", "name": title, "byArtist": artist,
                "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            let root: [String: Any] = ["@type": "WebPage", "mainEntity": recording]
            let json = String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
            metadata = "<title>Taylor Swift - Rewrite : Part 2</title><script type='application/ld+json'>\(json)</script>"
        case .featuredHeadingWithShazamSuffix, .headingWithShazamSuffix,
             .artistFirstFrenchHeading, .artistFirstFrenchWrongSong, .artistFirstFrenchMainEntityOnly,
             .standByMeLocalizedHeading, .standByMeWithoutAnchor:
            let recording: [String: Any] = [
                "@type": "MusicRecording", "name": title, "byArtist": artist,
                "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            let root = self == .standByMeWithoutAnchor
                ? recording : ["@type": "WebPage", "mainEntity": recording]
            let json = String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
            let heading: String
            switch self {
            case .featuredHeadingWithShazamSuffix:
                heading = "Snow On The Beach - Taylor Swift feat. Lana Del Rey - Shazam"
            case .headingWithShazamSuffix:
                heading = "\(title) - \(artist) - Shazam"
            case .artistFirstFrenchHeading, .artistFirstFrenchMainEntityOnly:
                heading = "\(artist) - \(title) : Paroles de chansons et clips"
            case .artistFirstFrenchWrongSong:
                heading = "\(artist) - Other Song : Paroles de chansons et clips"
            default:
                heading = "Stand By Me : Paroles et clips"
            }
            let canonical = [.artistFirstFrenchHeading, .artistFirstFrenchWrongSong].contains(self)
                ? "<link rel='canonical' href='https://www.shazam.com/song/1650859889/canonical-song'>" : ""
            metadata = "<title>\(heading)</title>\(canonical)<script type='application/ld+json'>\(json)</script>"
        case .unquotedCanonicalAnchor, .unquotedDataHrefIgnored,
             .arrayRecordingURLs, .arrayRecordingURLsWrongID, .arrayMainEntityOfPage,
             .arrayMainEntityWrongArtist, .relativeCanonicalAnchor, .redirectedRelativeCanonicalAnchor:
            let canonicalURL = "https://www.shazam.com/song/1650859889/canonical-song"
            let wrongURL = "https://www.shazam.com/song/999999/unrelated-song"
            var recording: [String: Any] = [
                "@type": "MusicRecording", "name": title, "byArtist": artist,
                "url": canonicalURL, "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            switch self {
            case .arrayRecordingURLs:
                recording["url"] = [wrongURL, ["@id": canonicalURL]] as [Any]
            case .arrayRecordingURLsWrongID:
                recording["url"] = [wrongURL, ["@id": wrongURL]] as [Any]
            case .arrayMainEntityOfPage, .arrayMainEntityWrongArtist:
                recording.removeValue(forKey: "url")
                recording["mainEntityOfPage"] = [wrongURL, ["@id": canonicalURL]] as [Any]
                if self == .arrayMainEntityWrongArtist { recording["byArtist"] = "Other Artist" }
            default:
                break
            }
            let unrelated: [String: Any] = ["@type": "MusicRecording", "name": "Other Song", "byArtist": "Other Artist"]
            let root: [String: Any] = ["@graph": [unrelated, recording]]
            let json = String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
            let link: String
            switch self {
            case .unquotedCanonicalAnchor:
                link = "<link rel=canonical href=\(canonicalURL)>"
            case .unquotedDataHrefIgnored:
                link = "<link rel=canonical data-href=\(wrongURL) href=\(canonicalURL)>"
            case .relativeCanonicalAnchor:
                // Resolve against /song/1650859889/requested-slug, not the site root.
                link = "<link rel='canonical' href='./canonical-song'>"
            case .redirectedRelativeCanonicalAnchor:
                // Only the final response URL's trailing directory resolves this to a song ID.
                link = "<link rel='canonical' href='../canonical-song'>"
            default:
                link = "<link rel='canonical' href='\(canonicalURL)'>"
            }
            metadata = "<title>歌曲資訊</title>\(link)<script type='application/ld+json'>\(json)</script>"
        case .frenchHeadingCanonical, .frenchHeadingMainEntity, .frenchHeadingWithoutPrimary,
             .frenchHeadingWrongSong, .frenchHeadingWrongArtist,
             .frenchHeadingRootWithoutAnchor, .frenchHeadingNoSpaceColon:
            let canonicalURL = "https://www.shazam.com/song/1650859889/snow-on-the-beach-feat-lana-del-rey"
            let recording: [String: Any] = [
                "@type": "MusicRecording", "name": title, "byArtist": artist,
                "url": canonicalURL, "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            let root: [String: Any]
            if self == .frenchHeadingRootWithoutAnchor {
                root = recording.filter { $0.key != "url" }
            } else if [.frenchHeadingMainEntity, .frenchHeadingWrongSong, .frenchHeadingWrongArtist].contains(self) {
                root = ["@type": "WebPage", "mainEntity": recording]
            } else {
                root = ["@graph": [recording]]
            }
            let json = String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
            let heading = self == .frenchHeadingWrongSong ? "Other Song - Taylor Swift" :
                self == .frenchHeadingWrongArtist ? "\(title) - Other Artist" : "\(title) - \(artist)"
            let canonical = [.frenchHeadingCanonical, .frenchHeadingNoSpaceColon].contains(self)
                ? "<link rel='canonical' href='\(canonicalURL)'>" : ""
            let schema = self == .frenchHeadingWithoutPrimary ? "" : "<script type='application/ld+json'>\(json)</script>"
            let colon = self == .frenchHeadingNoSpaceColon ? ": " : " : "
            metadata = "<title>\(heading)\(colon)Paroles de chansons, clips et concerts</title>\(canonical)\(schema)"
        case .duplicateCanonicalRecordings, .conflictingCanonicalRecordings,
             .localizedCanonicalURL, .trailingSlashCanonicalURL, .differentCanonicalSongID,
             .trackCanonicalURL, .scriptLocaleCanonicalURL, .numericLocaleCanonicalURL:
            let canonicalURL = "https://www.shazam.com/song/1650859889/snow-on-the-beach-feat-lana-del-rey"
            var recording: [String: Any] = [
                "@type": "MusicRecording", "name": title, "byArtist": artist,
                "url": canonicalURL, "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            var sibling: [String: Any] = [
                "@type": "MusicRecording", "name": "Other Song", "byArtist": "Other Artist"
            ]
            switch self {
            case .duplicateCanonicalRecordings:
                sibling = recording
                sibling["recordingOf"] = ["lyrics": ["text": Self.lyrics.components(separatedBy: "\n").prefix(4).joined(separator: "\n")]]
            case .conflictingCanonicalRecordings:
                sibling["url"] = canonicalURL
            case .localizedCanonicalURL:
                recording["url"] = "https://www.shazam.com/zh-TW/song/1650859889/snow-on-the-beach-feat-lana-del-rey"
            case .trailingSlashCanonicalURL:
                recording["url"] = canonicalURL + "/"
            case .differentCanonicalSongID:
                recording["url"] = "https://www.shazam.com/song/999999/snow-on-the-beach-feat-lana-del-rey"
            case .trackCanonicalURL:
                recording["url"] = "https://www.shazam.com/track/1650859889/snow-on-the-beach-feat-lana-del-rey"
            case .scriptLocaleCanonicalURL:
                recording["url"] = "https://www.shazam.com/zh-Hant/song/1650859889/snow-on-the-beach-feat-lana-del-rey"
            case .numericLocaleCanonicalURL:
                recording["url"] = "https://www.shazam.com/es-419/song/1650859889/snow-on-the-beach-feat-lana-del-rey"
            default:
                break
            }
            let json = String(data: try! JSONSerialization.data(withJSONObject: ["@graph": [sibling, recording]]), encoding: .utf8)!
            metadata = "<title>歌曲資訊</title><link rel='canonical' href='\(canonicalURL)'><script type='application/ld+json'>\(json)</script>"
        case .structuredSiblings, .structuredMissingArtist, .nestedMainEntity, .nestedTrack,
             .nestedItemList, .structuredExcerpt, .matchingRecommendationOnWrongPage,
             .mainEntityReference, .primaryCanonicalURL, .incompleteWrongPrimary,
             .wrongPrimaryDespiteMatchingHeading, .unanchoredRecommendation,
             .fragmentRecommendation, .fragmentRecommendationOnWrongPage,
             .ambiguousGraphWithFragmentRecommendation, .rootArrayRecommendation,
             .nestedAbout, .nestedHasPart, .nestedSubjectOf, .structuredOverRomanisedBody,
             .structuredPlaceholderFallback:
            var recording: [String: Any] = [
                "@type": "MusicRecording", "name": title, "byArtist": artist,
                "recordingOf": ["lyrics": ["text": Self.lyrics]]
            ]
            let unrelated: [String: Any] = [
                "@type": "MusicRecording", "name": "Other Song", "byArtist": "Other Artist"
            ]
            let root: Any
            switch self {
            case .structuredSiblings:
                root = ["@graph": [unrelated, recording]]
            case .structuredMissingArtist:
                recording.removeValue(forKey: "byArtist")
                root = recording
            case .nestedMainEntity:
                root = ["@type": "WebPage", "mainEntity": recording]
            case .nestedTrack:
                root = ["@type": "MusicAlbum", "track": [recording]]
            case .nestedItemList:
                root = ["@type": "ItemList", "itemListElement": [["@type": "ListItem", "item": recording]]]
            case .nestedAbout:
                root = ["@type": "WebPage", "about": recording]
            case .nestedHasPart:
                root = ["@type": "MusicAlbum", "hasPart": [recording]]
            case .nestedSubjectOf:
                root = ["@type": "WebPage", "subjectOf": recording]
            case .rootArrayRecommendation:
                root = [recording]
            case .structuredPlaceholderFallback:
                recording["recordingOf"] = ["lyrics": ["text": "Lyrics not available"]]
                root = recording
            case .structuredExcerpt:
                recording["recordingOf"] = ["lyrics": ["text": Self.lyrics.components(separatedBy: "\n").prefix(4).joined(separator: "\n")]]
                root = recording
            case .matchingRecommendationOnWrongPage:
                root = ["@type": "WebPage", "mainEntity": unrelated, "itemListElement": [recording]]
            case .wrongPrimaryDespiteMatchingHeading:
                root = ["@type": "WebPage", "mainEntity": unrelated, "itemListElement": [recording]]
            case .mainEntityReference:
                recording["@id"] = "#main-song"
                root = ["@graph": [["@type": "WebPage", "mainEntity": ["@id": "#main-song"]], unrelated, recording]]
            case .primaryCanonicalURL:
                recording["url"] = "https://www.shazam.com/song/1650859889/snow-on-the-beach-feat-lana-del-rey"
                root = ["@graph": [unrelated, recording]]
            case .incompleteWrongPrimary:
                recording["name"] = "Other Song"
                recording.removeValue(forKey: "byArtist")
                root = recording
            case .unanchoredRecommendation:
                root = ["@type": "ItemList", "itemListElement": [recording]]
            case .fragmentRecommendation:
                var recommendation = unrelated
                recommendation["@id"] = "#rec-1"
                root = ["@graph": [recommendation]]
            case .fragmentRecommendationOnWrongPage:
                recording["@id"] = "#rec-1"
                root = ["@graph": [recording]]
            case .ambiguousGraphWithFragmentRecommendation:
                var recommendation = unrelated
                recommendation["@id"] = "#rec-1"
                root = ["@graph": [recording, recommendation]]
            default:
                root = recording
            }
            let json = String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
            let heading = [.matchingRecommendationOnWrongPage, .fragmentRecommendationOnWrongPage].contains(self) ? "Other Song - Other Artist: Song Lyrics" :
                [.mainEntityReference, .primaryCanonicalURL, .unanchoredRecommendation,
                 .ambiguousGraphWithFragmentRecommendation, .rootArrayRecommendation].contains(self) ? "歌曲資訊" : Self.heading
            let canonical = [.primaryCanonicalURL, .fragmentRecommendation, .fragmentRecommendationOnWrongPage].contains(self)
                ? "<link rel='canonical' href='https://www.shazam.com/song/1650859889/snow-on-the-beach-feat-lana-del-rey'>" : ""
            metadata = "<title>\(heading)</title>\(canonical)<script type='application/ld+json'>\(json)</script>"
        }
        let recommendation = self == .bodyOnlyMatch ? "<div>\(Self.heading)</div>" : ""
        let schemaOnly = [.nestedMainEntity, .nestedTrack, .nestedItemList, .mainEntityReference,
                          .primaryCanonicalURL, .duplicateCanonicalRecordings, .conflictingCanonicalRecordings,
                          .localizedCanonicalURL, .trailingSlashCanonicalURL, .differentCanonicalSongID,
                          .trackCanonicalURL, .scriptLocaleCanonicalURL, .numericLocaleCanonicalURL,
                          .nestedAbout, .nestedHasPart, .nestedSubjectOf,
                          .unquotedCanonicalAnchor, .unquotedDataHrefIgnored,
                          .arrayRecordingURLs, .arrayRecordingURLsWrongID, .arrayMainEntityOfPage,
                          .arrayMainEntityWrongArtist, .relativeCanonicalAnchor,
                          .redirectedRelativeCanonicalAnchor,
                          .redirectedWrongSongID, .redirectedWrongTrackID, .redirectedWrongIDMatchingCanonical,
                          .redirectedMatchingSongID, .bareApostropheLinkMatching,
                          .canonicalMissingArtistWithUnknownHeading, .mainMissingArtistWithUnknownHeading,
                          .multipleCanonicalMissingArtist, .multipleMainMissingArtist].contains(self)
        let visibleLyrics = self == .wrongNonHyphenatedOpenGraph
            ? "Another singer tells a tale\nThe market closes in the rain\nThe empty station waits alone\nA distant bell begins to ring\nThe painted doorway fades away\nThe morning train is running late\nAnd nothing here recalls the song"
            : self == .structuredOverRomanisedBody
                ? Self.lyrics + "\nSilver lantern romanised\nQuiet river romanised\nDistant morning romanised\nPaper boat romanised\nGarden gate romanised\nEvery star romanised"
                : Self.lyrics
        let lines = schemaOnly ? "" : visibleLyrics.components(separatedBy: "\n").map { "<div>\($0)</div>" }.joined()
        let verses = Self.lyrics.components(separatedBy: "\n").joined(separator: "<br>")
        if sourceName == "songlyrics" {
            return "<html><head>\(metadata)</head><body><p id='songLyricsDiv'>\(verses)</p></body></html>"
        }
        if sourceName == "lyricsify" {
            return "<html><head>\(metadata)</head><body><div id='lyrics_song_details'>\(verses)</div></body></html>"
        }
        if sourceName == "letras" {
            return "<html><head>\(metadata)</head><body><div class='lyric-original'>\(verses)</div></body></html>"
        }
        let lyricsHeading = self == .localizedStructuredMetadata ? "歌詞" : "Lyrics"
        return """
        <html><head>\(metadata)</head><body>
        <div>Overview</div>\(recommendation)<h2>\(lyricsHeading)</h2>
        \(lines)<div>Written by: Test Writer</div></body></html>
        """
    }
}

private final class ShazamFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let fixtureName = request.value(forHTTPHeaderField: "X-Lyrics-Fixture"),
              let fixture = ShazamPageFixture(rawValue: fixtureName)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let body: Data
        if url.host == "itunes.apple.com", url.path == "/search" {
            body = try! JSONSerialization.data(withJSONObject: ["results": fixture.searchResults])
        } else if url.host == "www.shazam.com",
                  url.path.hasPrefix("/song/1650859889/") {
            // Even the wrong-page fixtures have the requested song in their URL.
            body = Data(fixture.html.utf8)
        } else if ["songlyrics.com", "www.songlyrics.com"].contains(url.host ?? ""), fixture.sourceName == "songlyrics" {
            body = Data(fixture.html.utf8)
        } else if url.host == "www.lyricsify.com", fixture.sourceName == "lyricsify" {
            body = Data(fixture.html.utf8)
        } else if url.host == "www.letras.com", fixture.sourceName == "letras" {
            body = Data(fixture.html.utf8)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        // Model a canonical redirect whose numeric path cannot validate metadata
        // on its own, so the generic provider cases exercise the page headings.
        let responseURL: URL
        if [.redirectedWrongSongID, .redirectedWrongIDMatchingCanonical].contains(fixture), url.host == "www.shazam.com" {
            responseURL = URL(string: "https://www.shazam.com/song/999999/other-recording")!
        } else if fixture == .redirectedWrongTrackID, url.host == "www.shazam.com" {
            responseURL = URL(string: "https://www.shazam.com/zh-Hant/track/999999/other-recording/")!
        } else if fixture == .redirectedMatchingSongID, url.host == "www.shazam.com" {
            responseURL = URL(string: "https://www.shazam.com/es-419/song/1650859889/returned-song/")!
        } else if fixture == .redirectedRelativeCanonicalAnchor, url.host == "www.shazam.com" {
            responseURL = URL(string: "https://www.shazam.com/zh-Hant/song/1650859889/redirected/")!
        } else {
            responseURL = fixture.sourceName == "shazam"
                ? url
                : URL(string: "https://\(url.host!)/recording/123")!
        }
        let response = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
