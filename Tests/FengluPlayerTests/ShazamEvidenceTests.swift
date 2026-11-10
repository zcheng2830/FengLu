import Foundation
import Testing
@testable import FengluPlayer

struct ShazamEvidenceTests {
    @Test(arguments: ShazamEvidenceFixture.cases)
    func requiresIndependentRecordingEvidence(_ fixture: ShazamEvidenceFixture) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShazamEvidenceProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Evidence-Fixture": fixture.name]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if let aliases = fixture.aliases {
            try JSONEncoder().encode(aliases).write(to: directory.appendingPathComponent("song.lyrics-aliases.json"))
        }
        let track = AudioTrack(
            url: directory.appendingPathComponent(fixture.fileName), title: fixture.localTitle,
            artist: fixture.localArtist, album: fixture.localAlbum,
            trackNumber: fixture.localTrackNumber, duration: fixture.localDuration
        )
        let result = await LyricsOnlineResolver(track: track, session: session)
            .lyrics(for: track, sourceNames: ["shazam"])
        if fixture.shouldMatch {
            let resolution = try #require(result)
            #expect(resolution.rawLyrics == fixture.expectedLyrics)
        } else {
            #expect(result == nil)
        }
    }
}

struct ShazamEvidenceFixture: Sendable, CustomStringConvertible {
    let name: String
    var localTitle = "Snow On The Beach"
    var localArtist: String? = "Taylor Swift"
    var localAlbum: String? = "Midnights"
    var localTrackNumber: Int? = 4
    var localDuration: TimeInterval? = 256.13
    var fileName = "song.flac"
    var hits: [ShazamEvidenceHit]? = nil
    var pageTitle: String? = nil
    var pageArtists: [String]? = nil
    var omitPageTitle = false
    var omitPageArtist = false
    var declaration = Declaration.canonical
    var anchor = Anchor.mainEntity
    var conflictingRecordURL = false
    var conflictingMainPageURL = false
    var heading = "A completely unfamiliar heading • nouvelle locale"
    var schemaLyrics: String? = Self.lyrics
    var visibleLyrics = Self.wrongLyrics
    var extraRecording = ExtraRecording.none
    var redirectedID: String? = nil
    var aliases: [[String]]? = nil
    var malformedTag = MalformedTag.none
    var nestedField = NestedField.none
    var nestingDepth = 0
    var scriptAttributes = "type='application/ld+json'"
    var scriptEnvelope = ScriptEnvelope.none
    var inertScriptPrefix = InertScriptPrefix.none
    var lyricsShape = LyricsShape.textObject
    var recordingOfArray = false
    var lyricsNestingDepth = 0
    var compositionNestingDepth = 0
    var canonicalRel = "canonical"
    var canonicalHost = "www.shazam.com"
    var additionalDeclaredURL: String? = nil
    var additionalRecordURL: String? = nil
    var redirectedHost = "www.shazam.com"
    var scriptOpeningSeparator = " "
    var scriptClosingTag = "</script>"
    var scriptAtEOF = false
    var shouldMatch = true

    var description: String { name }
    var lookupTitle: String { localTitle.isEmpty ? URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent : localTitle }
    var expectedLyrics: String { schemaLyrics ?? Self.lyrics }
    var searchHits: [ShazamEvidenceHit] {
        hits ?? [ShazamEvidenceHit(title: lookupTitle, artist: localArtist ?? "Taylor Swift")]
    }
    var selectedHit: ShazamEvidenceHit {
        searchHits.first(where: { $0.id == "1650859889" }) ?? searchHits[0]
    }

    enum Declaration: Sendable { case canonical, openGraph, duplicateOpenGraph, conflictingOpenGraph, none, wrong, conflicting, unquoted, minified, relative, locale, quotedAngleMeta, quotedAngleLink }
    enum Anchor: Sendable { case mainEntity, canonicalURL, mainEntityOfPage, none, fragmentOnly, referencedMainEntity, rootArray }
    enum ExtraRecording: Sendable { case none, wrongSibling, conflictingPrimary, conflictingCanonicalSibling, duplicatePrimary, incompletePrimary }
    enum MalformedTag: Sendable { case none, metaDoubleQuote, metaSingleQuote, linkDoubleQuote, linkSingleQuote }
    enum NestedField: Sendable { case none, recordURL, mainEntityOfPage, byArtist, identifierObjects, recordURLWithDeepConflict }
    enum LyricsShape: Sendable { case textObject, string, objectArray, stringArray, mixedArray, paddedAlternative, invalid }
    enum ScriptEnvelope: Sendable { case none, unclosedUntyped, unclosedJavaScript, template, comment, malformedDiv }
    enum InertScriptPrefix: Sendable { case none, template, javaScriptString, comment, emptyComment, emptyDashComment, doubleEscaped, textarea, title, style, xmp }

    static let lyrics = "A silver lantern lights the road\nThe quiet river carries on\nWe watch the distant morning glow\nA paper boat floats into view\nThe garden gate is open wide\nAnd every star returns to blue"
    static let wrongLyrics = "A stranger walks along the coast\nThe empty city waits for rain\nA distant clock begins to sound\nThe shutters close upon the square\nAnother story starts tonight\nThe last train leaves without a light"

    static let cases: [Self] = [
        .init(name: "declared-main-entity"),
        .init(name: "declared-canonical-recording", anchor: .canonicalURL),
        .init(name: "declared-main-entity-of-page", anchor: .mainEntityOfPage),
        .init(name: "declared-referenced-main-entity", anchor: .referencedMainEntity),
        .init(name: "open-graph-id", declaration: .openGraph),
        .init(name: "duplicate-open-graph-id", declaration: .duplicateOpenGraph),
        .init(name: "conflicting-open-graph-ids", declaration: .conflictingOpenGraph, shouldMatch: false),
        .init(name: "unquoted-id", declaration: .unquoted),
        .init(name: "minified-id", declaration: .minified),
        .init(name: "relative-id", declaration: .relative, anchor: .canonicalURL),
        .init(name: "locale-track-id", declaration: .locale, anchor: .canonicalURL),
        // A real HTML parser keeps apparent later tags inside an unterminated
        // attribute. These declarations cannot independently identify the page.
        .init(name: "unterminated-double-quoted-meta-hides-declaration", declaration: .openGraph, malformedTag: .metaDoubleQuote, shouldMatch: false),
        .init(name: "unterminated-single-quoted-meta-hides-declaration", declaration: .openGraph, malformedTag: .metaSingleQuote, shouldMatch: false),
        .init(name: "unterminated-double-quoted-link-hides-declaration", malformedTag: .linkDoubleQuote, shouldMatch: false),
        .init(name: "unterminated-single-quoted-link-hides-declaration", malformedTag: .linkSingleQuote, shouldMatch: false),
        .init(name: "quoted-angle-in-meta-attribute", declaration: .quotedAngleMeta),
        .init(name: "quoted-angle-in-link-attribute", declaration: .quotedAngleLink),
        .init(name: "shallow-url-arrays", anchor: .canonicalURL, nestedField: .recordURL, nestingDepth: 6),
        .init(name: "deep-url-arrays-rejected", anchor: .canonicalURL, nestedField: .recordURL, nestingDepth: 64, shouldMatch: false),
        .init(name: "shallow-main-page-arrays", anchor: .mainEntityOfPage, nestedField: .mainEntityOfPage, nestingDepth: 6),
        .init(name: "deep-main-page-arrays-rejected", anchor: .mainEntityOfPage, nestedField: .mainEntityOfPage, nestingDepth: 64, shouldMatch: false),
        .init(name: "shallow-artist-arrays", nestedField: .byArtist, nestingDepth: 6),
        .init(name: "deep-artist-arrays-rejected", nestedField: .byArtist, nestingDepth: 64, shouldMatch: false),
        .init(name: "shallow-identifier-objects", anchor: .canonicalURL, nestedField: .identifierObjects, nestingDepth: 6),
        .init(name: "deep-identifier-objects-rejected", anchor: .canonicalURL, nestedField: .identifierObjects, nestingDepth: 64, shouldMatch: false),
        .init(name: "deep-conflict-cannot-hide-behind-valid-anchor", nestedField: .recordURLWithDeepConflict, nestingDepth: 64, shouldMatch: false),
        .init(name: "unquoted-jsonld-type", scriptAttributes: "type=application/ld+json"),
        .init(name: "unquoted-jsonld-type-after-minified-attribute", scriptAttributes: "id=\"recording\"type=application/ld+json"),
        .init(name: "quoted-jsonld-type-after-minified-attribute", scriptAttributes: "data-source='page'type=\"application/ld+json\""),
        .init(name: "unclosed-untyped-script-hides-nested-jsonld", scriptEnvelope: .unclosedUntyped, shouldMatch: false),
        .init(name: "unclosed-javascript-hides-nested-jsonld", scriptEnvelope: .unclosedJavaScript, shouldMatch: false),
        .init(name: "template-wrapper-keeps-nested-jsonld-inert", scriptEnvelope: .template, shouldMatch: false),
        .init(name: "template-related-recording-is-inert", inertScriptPrefix: .template),
        .init(name: "javascript-string-recording-is-inert", inertScriptPrefix: .javaScriptString),
        .init(name: "commented-recording-is-inert", inertScriptPrefix: .comment),
        .init(name: "abrupt-empty-comment-before-jsonld", inertScriptPrefix: .emptyComment),
        .init(name: "abrupt-dash-comment-before-jsonld", inertScriptPrefix: .emptyDashComment),
        .init(name: "double-escaped-related-recording-is-inert", inertScriptPrefix: .doubleEscaped),
        .init(name: "textarea-related-recording-is-inert", inertScriptPrefix: .textarea),
        .init(name: "title-related-recording-is-inert", inertScriptPrefix: .title),
        .init(name: "style-related-recording-is-inert", inertScriptPrefix: .style),
        .init(name: "xmp-related-recording-is-inert", inertScriptPrefix: .xmp),
        .init(name: "unterminated-div-attribute-hides-jsonld", scriptAttributes: "type=\"application/ld+json\"", scriptEnvelope: .malformedDiv, shouldMatch: false),
        .init(name: "slash-introduced-jsonld-type", scriptOpeningSeparator: "/"),
        .init(name: "script-closing-attributes", scriptClosingTag: "</script foo=1>"),
        .init(name: "script-closing-solidus", scriptClosingTag: "</script/>"),
        .init(name: "jsonld-body-at-end-of-input", scriptClosingTag: "", scriptAtEOF: true),
        .init(name: "comment-only-jsonld-is-not-evidence", scriptEnvelope: .comment, shouldMatch: false),
        .init(name: "jsonld-type-leading-space", scriptAttributes: "type=\" application/ld+json\""),
        .init(name: "jsonld-type-trailing-space", scriptAttributes: "type='application/ld+json '"),
        .init(name: "jsonld-type-padded-whitespace-case", scriptAttributes: "type=\"\t APPLICATION/LD+JSON\n \""),
        .init(name: "jsonld-type-all-ascii-whitespace", scriptAttributes: "type=\" \t\n\r\u{000C}application/ld+json \t\n\r\u{000C}\""),
        .init(name: "jsonld-type-nbsp-is-not-ascii-whitespace", scriptAttributes: "type='application/ld+json&#160;'", shouldMatch: false),
        .init(name: "jsonld-type-leading-nbsp-is-not-ascii-whitespace", scriptAttributes: "type='&#160;application/ld+json'", shouldMatch: false),
        .init(name: "jsonld-type-literal-nbsp-is-not-ascii-whitespace", scriptAttributes: "type='application/ld+json\u{00A0}'", shouldMatch: false),
        .init(name: "jsonld-type-named-nbsp-is-not-ascii-whitespace", scriptAttributes: "type='application/ld+json&nbsp;'", shouldMatch: false),
        .init(name: "jsonld-type-unquoted-literal-nbsp-is-not-ascii-whitespace", scriptAttributes: "type=application/ld+json\u{00A0}", shouldMatch: false),
        .init(name: "jsonld-type-unquoted-numeric-nbsp-is-not-ascii-whitespace", scriptAttributes: "type=application/ld+json&#160;", shouldMatch: false),
        .init(name: "jsonld-type-unquoted-named-nbsp-is-not-ascii-whitespace", scriptAttributes: "type=application/ld+json&nbsp;", shouldMatch: false),
        .init(name: "jsonld-type-vertical-tab-is-not-ascii-whitespace", scriptAttributes: "type='application/ld+json\u{000B}'", shouldMatch: false),
        .init(name: "jsonld-type-unquoted-vertical-tab-is-not-ascii-whitespace", scriptAttributes: "type=application/ld+json\u{000B}", shouldMatch: false),
        .init(name: "jsonld-type-internal-whitespace-is-not-mime", scriptAttributes: "type='application/ ld+json'", shouldMatch: false),
        .init(name: "template-cannot-promote-data-type", scriptAttributes: "data-type='application/ld+json'", scriptEnvelope: .template, shouldMatch: false),
        .init(name: "data-type-cannot-supply-jsonld-type", scriptAttributes: "data-type='application/ld+json'", shouldMatch: false),
        .init(name: "type-inside-quoted-attribute-is-not-jsonld-type", scriptAttributes: "data-note='a > type=\"application/ld+json\"'", shouldMatch: false),
        .init(name: "unrelated-script-type-cannot-supply-recordings", scriptAttributes: "type=application/json", shouldMatch: false),
        .init(name: "recording-of-array", recordingOfArray: true),
        .init(name: "lyrics-plain-string", lyricsShape: .string),
        .init(name: "lyrics-text-object-array", lyricsShape: .objectArray),
        .init(name: "lyrics-string-array", lyricsShape: .stringArray),
        .init(name: "lyrics-mixed-array", lyricsShape: .mixedArray),
        .init(name: "lyrics-length-ignores-whitespace-padding", lyricsShape: .paddedAlternative),
        .init(name: "composition-and-lyrics-arrays", lyricsShape: .mixedArray, recordingOfArray: true),
        .init(name: "invalid-lyrics-shape-does-not-scrape", lyricsShape: .invalid, shouldMatch: false),
        .init(name: "shallow-lyrics-arrays", lyricsShape: .string, lyricsNestingDepth: 6),
        .init(name: "deep-lyrics-arrays-rejected", lyricsShape: .string, lyricsNestingDepth: 64, shouldMatch: false),
        .init(name: "shallow-composition-arrays", compositionNestingDepth: 6),
        .init(name: "deep-composition-arrays-rejected", compositionNestingDepth: 64, shouldMatch: false),
        .init(name: "canonical-rel-token-list", canonicalRel: "canonical alternate"),
        .init(name: "canonical-rel-trailing-space", canonicalRel: "canonical "),
        .init(name: "canonical-rel-whitespace-case", canonicalRel: "alternate\tCaNoNiCaL\n"),
        .init(name: "canonical-rel-substring-is-not-token", canonicalRel: "notcanonical", shouldMatch: false),
        .init(name: "mobile-canonical-host", anchor: .canonicalURL, canonicalHost: "m.shazam.com"),
        .init(name: "future-subdomain-canonical-host", anchor: .canonicalURL, canonicalHost: "catalog.eu.shazam.com"),
        .init(name: "shazam-suffix-spoof-rejected", canonicalHost: "shazam.com.evil.example", shouldMatch: false),
        .init(name: "shazam-prefix-spoof-rejected", canonicalHost: "evilshazam.com", shouldMatch: false),
        .init(name: "mobile-declared-id-conflict", additionalDeclaredURL: "https://m.shazam.com/song/999999/other", shouldMatch: false),
        .init(name: "future-subdomain-record-id-conflict", additionalRecordURL: "https://catalog.eu.shazam.com/track/999999/other", shouldMatch: false),
        .init(name: "additional-record-url-preserves-existing-conflict", conflictingRecordURL: true, additionalRecordURL: "https://m.shazam.com/song/1650859889/recording", shouldMatch: false),
        .init(name: "additional-record-url-cannot-invent-anchor", anchor: .none, additionalRecordURL: "https://example.com/recording", shouldMatch: false),
        .init(name: "mobile-response-id-conflict", redirectedID: "999999", redirectedHost: "m.shazam.com", shouldMatch: false),
        .init(name: "missing-declared-id", declaration: .none, shouldMatch: false),
        .init(name: "wrong-declared-id", declaration: .wrong, shouldMatch: false),
        .init(name: "conflicting-declared-ids", declaration: .conflicting, shouldMatch: false),
        .init(name: "redirect-id-conflict", redirectedID: "999999", shouldMatch: false),
        .init(name: "same-id-redirect", redirectedID: "1650859889"),
        .init(name: "root-is-not-an-anchor", anchor: .none, shouldMatch: false),
        .init(name: "fragment-is-not-an-anchor", anchor: .fragmentOnly, shouldMatch: false),
        .init(name: "array-is-not-an-anchor", anchor: .rootArray, shouldMatch: false),
        .init(name: "matching-heading-cannot-anchor", anchor: .none, heading: "Snow On The Beach - Taylor Swift", shouldMatch: false),
        .init(name: "missing-artist-cannot-borrow-heading", omitPageArtist: true, heading: "Snow On The Beach - Taylor Swift", shouldMatch: false),
        .init(name: "missing-title-cannot-borrow-heading", omitPageTitle: true, heading: "Snow On The Beach - Taylor Swift", shouldMatch: false),
        .init(name: "wrong-schema-title", pageTitle: "Anti-Hero", shouldMatch: false),
        .init(name: "wrong-schema-artist", pageArtists: ["Someone Else"], shouldMatch: false),
        .init(name: "shared-title-tokens", pageTitle: "Snow On The Mountain", shouldMatch: false),
        .init(name: "title-substring", localTitle: "Hero", pageTitle: "Anti-Hero", shouldMatch: false),
        .init(name: "unknown-bullet-heading"),
        .init(name: "localized-heading", heading: "Песня • текст и музыка"),
        .init(name: "conflicting-heading", heading: "Other Song - Other Artist"),
        .init(name: "literal-by-heading", heading: "Stand By Me : Paroles et clips"),
        .init(name: "missing-heading", heading: ""),
        .init(name: "wrong-sibling-does-not-win", extraRecording: .wrongSibling),
        .init(name: "conflicting-primary-rejects", extraRecording: .conflictingPrimary, shouldMatch: false),
        .init(name: "main-and-canonical-conflict", extraRecording: .conflictingCanonicalSibling, shouldMatch: false),
        .init(name: "selected-record-url-conflict", conflictingRecordURL: true, shouldMatch: false),
        .init(name: "selected-main-page-url-conflict", conflictingMainPageURL: true, shouldMatch: false),
        .init(name: "incomplete-primary-rejects", extraRecording: .incompletePrimary, shouldMatch: false),
        .init(name: "duplicate-matching-primary", extraRecording: .duplicatePrimary),
        .init(name: "no-schema-lyrics-does-not-scrape", schemaLyrics: nil, shouldMatch: false),
        .init(name: "placeholder-schema-does-not-scrape", schemaLyrics: "Lyrics not available", visibleLyrics: Self.lyrics, shouldMatch: false),
        .init(name: "structured-text-beats-wrong-visible"),
        .init(name: "apostrophe-title", localTitle: "Don't Start Now", localArtist: "Dua Lipa"),
        .init(name: "apostrophe-artist", localArtist: "D'Angelo"),
        .init(name: "punctuation-normalization", pageTitle: "SNOW  ON\tTHE BEACH", pageArtists: ["TAYLOR SWIFT"]),
        .init(name: "local-alias", pageTitle: "Winter Shore", aliases: [["Snow On The Beach", "Winter Shore"]]),
        .init(name: "unconfigured-alias", pageTitle: "Winter Shore", shouldMatch: false),
        .init(name: "full-duo-reordered", localArtist: "Simon & Garfunkel", pageArtists: ["Garfunkel", "Simon"]),
        .init(name: "solo-cannot-replace-duo", localArtist: "Simon & Garfunkel", pageArtists: ["Simon"], shouldMatch: false),
        .init(name: "complete-band-name", localArtist: "Nick Cave & The Bad Seeds"),
        .init(name: "solo-cannot-replace-band", localArtist: "Nick Cave & The Bad Seeds", pageArtists: ["Nick Cave"], shouldMatch: false),
        .init(name: "literal-slash-artist", localArtist: "AC/DC"),
        .init(name: "literal-comma-artist", localArtist: "Tyler, the Creator", pageArtists: ["Tyler, the Creator"]),
        .init(name: "partial-comma-artist-rejected", localArtist: "Tyler, the Creator", pageArtists: ["Tyler"], shouldMatch: false),
        .init(name: "literal-ft-artist", localArtist: "FT Island"),
        .init(name: "shared-feature-cannot-merge-songs", localTitle: "Song A (feat. Guest)", pageTitle: "Song B (feat. Guest)", shouldMatch: false),
        .init(name: "same-prefix-subtitles-distinct", localTitle: "Rewrite: Part 1", pageTitle: "Rewrite: Part 2", shouldMatch: false),
        .init(name: "comma-the-credit", localArtist: "Taylor Swift, The National", pageArtists: ["The National", "Taylor Swift"]),
        .init(name: "slash-a-credit", localArtist: "Lil Nas X / A Boogie wit da Hoodie", pageArtists: ["A Boogie wit da Hoodie", "Lil Nas X"]),
        .init(name: "cover-cannot-lead", pageArtists: ["Cover Band", "Taylor Swift"], shouldMatch: false),
        .init(name: "cover-cannot-follow", pageArtists: ["Taylor Swift", "Cover Band"], shouldMatch: false),
        .init(name: "page-only-duet-needs-corroboration", pageArtists: ["Taylor Swift", "Lana Del Rey"], shouldMatch: false),
        .init(name: "page-only-reversed-duet-needs-corroboration", pageArtists: ["Lana Del Rey", "Taylor Swift"], shouldMatch: false),
        .init(name: "search-corroborated-duet", hits: [.init(title: "Snow On The Beach", artist: "Taylor Swift & Lana Del Rey")], pageArtists: ["Taylor Swift", "Lana Del Rey"]),
        .init(name: "search-corroborated-duet-reordered", hits: [.init(title: "Snow On The Beach", artist: "Taylor Swift & Lana Del Rey")], pageArtists: ["Lana Del Rey", "Taylor Swift"]),
        .init(name: "search-corroborated-duet-cannot-drop-performer", hits: [.init(title: "Snow On The Beach", artist: "Taylor Swift & Lana Del Rey")], pageArtists: ["Taylor Swift"], shouldMatch: false),
        .init(name: "search-feature-corroborated-duet", hits: [.init(title: "Snow On The Beach (feat. Lana Del Rey)", artist: "Taylor Swift")], pageTitle: "Snow On The Beach", pageArtists: ["Taylor Swift", "Lana Del Rey"]),
        .init(name: "search-feature-corroborated-duet-reordered", hits: [.init(title: "Snow On The Beach (feat. Lana Del Rey)", artist: "Taylor Swift")], pageTitle: "Snow On The Beach", pageArtists: ["Lana Del Rey", "Taylor Swift"]),
        .init(name: "search-artist-feature-corroborated-duet", hits: [.init(title: "Snow On The Beach", artist: "Taylor Swift feat. Lana Del Rey")], pageArtists: ["Taylor Swift", "Lana Del Rey"]),
        .init(name: "search-artist-feature-corroborated-duet-reordered", hits: [.init(title: "Snow On The Beach", artist: "Taylor Swift feat. Lana Del Rey")], pageArtists: ["Lana Del Rey", "Taylor Swift"]),
        .init(name: "search-feature-cannot-corroborate-unexpected-third-performer", hits: [.init(title: "Snow On The Beach (feat. Lana Del Rey)", artist: "Taylor Swift")], pageTitle: "Snow On The Beach", pageArtists: ["Taylor Swift", "Lana Del Rey", "Cover Band"], shouldMatch: false),
        .init(name: "local-feature-corroborated-duet", localTitle: "Snow On The Beach (feat. Lana Del Rey)", pageTitle: "Snow On The Beach", pageArtists: ["Taylor Swift", "Lana Del Rey"]),
        .init(name: "local-feature-corroborated-duet-reordered", localTitle: "Snow On The Beach (feat. Lana Del Rey)", pageTitle: "Snow On The Beach", pageArtists: ["Lana Del Rey", "Taylor Swift"]),
        .init(name: "featured-title", localTitle: "Snow On The Beach (feat. Lana Del Rey)", pageTitle: "Snow On The Beach"),
        .init(name: "bare-feature-confirmed", localTitle: "Snow On The Beach feat Lana Del Rey", hits: [.init(title: "Snow On The Beach (feat. Lana Del Rey)", artist: "Taylor Swift")], pageTitle: "Snow On The Beach"),
        .init(name: "bare-ft-confirmed", localTitle: "Snow On The Beach ft Lana Del Rey", hits: [.init(title: "Snow On The Beach (feat. Lana Del Rey)", artist: "Taylor Swift")], pageTitle: "Snow On The Beach"),
        .init(name: "featured-live-at-cannot-be-studio", localTitle: "Snow On The Beach feat. Guest - Live at Wembley", hits: [.init(title: "Snow On The Beach", artist: "Taylor Swift")], shouldMatch: false),
        .init(name: "remote-featured-live-at-cannot-replace-studio", hits: [.init(title: "Snow On The Beach feat. Guest - Live at Wembley", artist: "Taylor Swift")], shouldMatch: false),
        .init(name: "featured-live-at-matching", localTitle: "Snow On The Beach feat. Guest - Live at Wembley", hits: [.init(title: "Snow On The Beach (Live at Wembley)", artist: "Taylor Swift & Guest")], pageTitle: "Snow On The Beach - Live at Wembley", pageArtists: ["Taylor Swift", "Guest"]),
        .init(name: "featured-unknown-dash-qualifier-preserved", localTitle: "Snow On The Beach feat. Guest - Unreleased Session", hits: [.init(title: "Snow On The Beach", artist: "Taylor Swift")], shouldMatch: false),
        .init(name: "bracketed-guest-internal-dash", localTitle: "Snow On The Beach (feat. Guest - Name)", pageTitle: "Snow On The Beach"),
        .init(name: "literal-feat-preserved", localTitle: "A Feat of Strength"),
        .init(name: "literal-feat-not-truncated", localTitle: "A Feat of Strength", hits: [.init(title: "A", artist: "Taylor Swift")], pageTitle: "A", shouldMatch: false),
        .init(name: "remaster-remote", hits: [.init(title: "Snow On The Beach (2013 Remaster)", artist: "Taylor Swift")]),
        .init(name: "remaster-local", localTitle: "Snow On The Beach (Remastered)", hits: [.init(title: "Snow On The Beach", artist: "Taylor Swift")]),
        .init(name: "remaster-cannot-replace-live", localTitle: "Snow On The Beach (Live)", hits: [.init(title: "Snow On The Beach (Remastered)", artist: "Taylor Swift")], shouldMatch: false),
        .init(name: "deluxe-local", localTitle: "Snow On The Beach [Deluxe Edition]", hits: [.init(title: "Snow On The Beach", artist: "Taylor Swift")]),
        .init(name: "filename-with-artist", localTitle: "", fileName: "Snow On The Beach.flac"),
        .init(name: "artistless-lone-no-context", localTitle: "", localArtist: nil, localAlbum: nil, localTrackNumber: nil, localDuration: nil, fileName: "Hello.mp3", hits: [.init(title: "Hello", artist: "Lionel Richie")], shouldMatch: false),
        .init(name: "artistless-lone-weak-context", localArtist: nil, localAlbum: nil, localTrackNumber: nil, shouldMatch: false),
        .init(name: "artistless-lone-corroborated", localArtist: nil),
        .init(name: "artistless-duplicate-no-context", localArtist: nil, localAlbum: nil, localTrackNumber: nil, localDuration: nil, hits: [.init(title: "Snow On The Beach", artist: "Taylor Swift"), .init(title: "Snow On The Beach", artist: "Taylor Swift")], shouldMatch: false),
        .init(name: "artistless-duplicate-corroborated", localArtist: nil, hits: [.init(title: "Snow On The Beach", artist: "Taylor Swift"), .init(title: "Snow On The Beach", artist: "Taylor Swift")]),
        .init(name: "artistless-context-tie", localArtist: nil, hits: [.init(title: "Snow On The Beach", artist: "Taylor Swift"), .init(title: "Snow On The Beach", artist: "Other Artist", id: "111111")], shouldMatch: false),
        .init(name: "artistless-context-second-wins", localArtist: nil, hits: [.init(title: "Snow On The Beach", artist: "Other Artist", id: "111111", album: "Wrong Album", trackNumber: 9, duration: 300), .init(title: "Snow On The Beach", artist: "Taylor Swift")]),
        .init(name: "search-near-miss-cannot-hide-exact", hits: [.init(title: "Snow On The Beach (Acoustic)", artist: "Taylor Swift", id: "111111"), .init(title: "Snow On The Beach", artist: "Taylor Swift")])
    ] + ["Live", "Live at Example Hall", "Demo", "Acoustic", "Clean", "Explicit", "Radio Edit", "Single Version", "Album Version", "Taylor's Version", "Bonus Track", "From Example Film"].flatMap { label in
        [
            Self(name: "local-\(label)-cannot-be-studio", localTitle: "Snow On The Beach (\(label))", hits: [.init(title: "Snow On The Beach", artist: "Taylor Swift")], shouldMatch: false),
            Self(name: "page-\(label)-cannot-be-studio", localTitle: "Snow On The Beach (\(label))", pageTitle: "Snow On The Beach", shouldMatch: false),
            Self(name: "remote-\(label)-cannot-replace-studio", hits: [.init(title: "Snow On The Beach (\(label))", artist: "Taylor Swift")], shouldMatch: false),
            Self(name: "same-\(label)-matches", localTitle: "Snow On The Beach (\(label))")
        ]
    }

    var html: String {
        let canonical = "https://\(canonicalHost)/song/1650859889/recording"
        let wrong = "https://\(canonicalHost)/song/999999/other"
        let declarationHTML: String
        switch declaration {
        case .canonical: declarationHTML = "<link rel='\(canonicalRel)' href='\(canonical)'>"
        case .openGraph: declarationHTML = "<meta property='og:url' content='\(canonical)'>"
        case .duplicateOpenGraph: declarationHTML = "<meta property='og:url' content='\(canonical)'><meta property='og:url' content='\(canonical)'>"
        case .conflictingOpenGraph: declarationHTML = "<meta property='og:url' content='\(canonical)'><meta property='og:url' content='\(wrong)'>"
        case .none: declarationHTML = ""
        case .wrong: declarationHTML = "<link rel='canonical' href='\(wrong)'>"
        case .conflicting: declarationHTML = "<link rel='canonical' href='\(canonical)'><meta property='og:url' content='\(wrong)'>"
        case .unquoted: declarationHTML = "<link rel=canonical href=\(canonical)>"
        case .minified: declarationHTML = "<meta property=\"og:url\"content=\"\(canonical)\">"
        case .relative: declarationHTML = "<link rel='canonical' href='./recording'>"
        case .locale: declarationHTML = "<link rel='canonical' href='https://www.shazam.com/zh-Hant/track/1650859889/recording/'>"
        case .quotedAngleMeta: declarationHTML = "<meta data-note='A > B' property='og:url' content='\(canonical)'>"
        case .quotedAngleLink: declarationHTML = "<link title='A > B' rel='canonical' href='\(canonical)'>"
        }
        // The later matching quote ends a malformed attribute only after the
        // apparent declaration. DOM parsing must not recover that declaration.
        let malformedPrefix: String
        let closingTag: String
        switch malformedTag {
        case .none:
            malformedPrefix = ""
            closingTag = ""
        case .metaDoubleQuote:
            malformedPrefix = "<meta name='description' content=\"unfinished>"
            closingTag = "<meta name=\"tail\">"
        case .metaSingleQuote:
            malformedPrefix = "<meta name=\"description\" content='unfinished>"
            closingTag = "<meta name='tail'>"
        case .linkDoubleQuote:
            malformedPrefix = "<link rel='stylesheet' title=\"unfinished>"
            closingTag = "<link rel=\"stylesheet\">"
        case .linkSingleQuote:
            malformedPrefix = "<link rel=\"stylesheet\" title='unfinished>"
            closingTag = "<link rel='stylesheet'>"
        }
        var recording: [String: Any] = ["@type": "MusicRecording"]
        if !omitPageTitle { recording["name"] = pageTitle ?? selectedHit.title }
        if !omitPageArtist {
            if let pageArtists { recording["byArtist"] = pageArtists.map { ["@type": "MusicGroup", "name": $0] } }
            else { recording["byArtist"] = selectedHit.artist }
        }
        if let schemaLyrics {
            var lyricsValue: Any
            switch lyricsShape {
            case .textObject: lyricsValue = ["text": schemaLyrics]
            case .string: lyricsValue = schemaLyrics
            case .objectArray: lyricsValue = [["text": "Lyrics not available"], ["text": schemaLyrics]]
            case .stringArray: lyricsValue = ["Lyrics not available", schemaLyrics]
            case .mixedArray: lyricsValue = ["Lyrics not available", ["text": schemaLyrics]] as [Any]
            case .paddedAlternative:
                let paddedExcerpt = schemaLyrics.components(separatedBy: "\n")
                    .map { String($0.prefix(12)) + String(repeating: " ", count: 80) }
                    .joined(separator: "\r\n\r\n") + "\r\n\r\n"
                lyricsValue = [schemaLyrics, paddedExcerpt]
            case .invalid: lyricsValue = ["unrelated": schemaLyrics]
            }
            for _ in 0..<lyricsNestingDepth { lyricsValue = [lyricsValue] }
            var composition: Any = ["lyrics": lyricsValue]
            if recordingOfArray { composition = [["lyrics": "Lyrics not available"], composition] as [Any] }
            for _ in 0..<compositionNestingDepth { composition = [composition] }
            recording["recordingOf"] = composition
        }
        switch anchor {
        case .canonicalURL: recording["url"] = canonical
        case .mainEntityOfPage: recording["mainEntityOfPage"] = ["@id": canonical]
        case .fragmentOnly, .referencedMainEntity: recording["@id"] = "#recording"
        default: break
        }
        if conflictingRecordURL { recording["url"] = [canonical, wrong] }
        if conflictingMainPageURL { recording["mainEntityOfPage"] = [["@id": canonical], ["@id": wrong]] }
        if let additionalRecordURL {
            if let existingURLs = recording["url"] as? [Any] {
                recording["url"] = existingURLs + [additionalRecordURL]
            } else if let existingURL = recording["url"] {
                recording["url"] = [existingURL, additionalRecordURL] as [Any]
            } else {
                recording["url"] = additionalRecordURL
            }
        }
        if nestedField != .none {
            let key: String
            switch nestedField {
            case .recordURL, .identifierObjects, .recordURLWithDeepConflict: key = "url"
            case .mainEntityOfPage: key = "mainEntityOfPage"
            case .byArtist: key = "byArtist"
            case .none: preconditionFailure("Handled above")
            }
            var value: Any = nestedField == .recordURLWithDeepConflict ? wrong : recording[key]!
            for _ in 0..<nestingDepth {
                if nestedField == .identifierObjects { value = ["@id": value] }
                else { value = [value] }
            }
            recording[key] = nestedField == .recordURLWithDeepConflict ? [canonical, value] : value
        }
        let wrongRecording: [String: Any] = ["@type": "MusicRecording", "name": "Wrong Song", "byArtist": "Wrong Artist", "recordingOf": ["lyrics": ["text": Self.wrongLyrics]]]
        var primaries = [recording]
        if extraRecording == .conflictingPrimary { primaries.append(wrongRecording) }
        if extraRecording == .duplicatePrimary { primaries.append(recording) }
        if extraRecording == .incompletePrimary { primaries.append(["@type": "MusicRecording", "name": pageTitle ?? selectedHit.title]) }
        let root: Any
        switch anchor {
        case .mainEntity:
            var page: [String: Any] = ["@type": "WebPage", "mainEntity": primaries]
            if extraRecording == .wrongSibling { page["itemListElement"] = [wrongRecording] }
            if extraRecording == .conflictingCanonicalSibling {
                var anchoredSibling = wrongRecording
                anchoredSibling["url"] = canonical
                page["itemListElement"] = [anchoredSibling]
            }
            root = page
        case .referencedMainEntity:
            root = ["@graph": [["@type": "WebPage", "mainEntity": ["@id": "#recording"]], recording, wrongRecording]]
        case .rootArray: root = [recording]
        default: root = recording
        }
        let schema = String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
        let visible = visibleLyrics.components(separatedBy: "\n").map { "<div>\($0)</div>" }.joined()
        let extraDeclaration = additionalDeclaredURL.map { "<meta property='og:url' content='\($0)'>" } ?? ""
        let scriptPrefix: String
        let scriptSuffix: String
        switch scriptEnvelope {
        case .none: scriptPrefix = ""; scriptSuffix = ""
        case .unclosedUntyped: scriptPrefix = "<script>window.boot = true;"; scriptSuffix = ""
        case .unclosedJavaScript: scriptPrefix = "<script type='text/javascript'>window.boot = true;"; scriptSuffix = ""
        case .template: scriptPrefix = "<script type='text/template'><section>"; scriptSuffix = "</section></script>"
        case .comment: scriptPrefix = "<!-- "; scriptSuffix = " -->"
        case .malformedDiv: scriptPrefix = "<div class=\"x>"; scriptSuffix = ""
        }
        var conflictingRecording = wrongRecording
        conflictingRecording["url"] = wrong
        let inertRoot: [String: Any] = ["@type": "WebPage", "mainEntity": conflictingRecording]
        let inertJSON = String(data: try! JSONSerialization.data(withJSONObject: inertRoot), encoding: .utf8)!
        let inertJSONLD = "<script type='application/ld+json'>\(inertJSON)</script>"
        let inertPrefix: String
        switch inertScriptPrefix {
        case .none: inertPrefix = ""
        case .template: inertPrefix = "<script type='text/template'>\(inertJSONLD)</script>"
        case .javaScriptString: inertPrefix = "<script>const template = `\(inertJSONLD)`;</script>"
        case .comment: inertPrefix = "<!-- \(inertJSONLD) -->"
        case .emptyComment: inertPrefix = "<!-->"
        case .emptyDashComment: inertPrefix = "<!--->"
        case .doubleEscaped:
            // In the escaped script state, each nested opening enters the
            // double-escaped state; its closing tag does not close the outer script.
            inertPrefix = "<script><!-- <script>inner</script>\(inertJSONLD) //--></script>"
        case .textarea: inertPrefix = "<textarea>\(inertJSONLD)</textarea>"
        case .title: inertPrefix = "<title>\(inertJSONLD)</title>"
        case .style: inertPrefix = "<style>\(inertJSONLD)</style>"
        case .xmp: inertPrefix = "<xmp>\(inertJSONLD)</xmp>"
        }
        let page = "<html><head><title>\(heading)</title>\(malformedPrefix)\(declarationHTML)\(extraDeclaration)\(closingTag)\(inertPrefix)\(scriptPrefix)<script\(scriptOpeningSeparator)\(scriptAttributes)>\(schema)\(scriptClosingTag)"
        if scriptAtEOF { return page }
        return page + "\(scriptSuffix)</head><body><h2>Lyrics</h2>\(visible)<div>Written by: Test Writer</div></body></html>"
    }
}

struct ShazamEvidenceHit: Sendable {
    var title: String
    var artist: String
    var id = "1650859889"
    var album: String? = "Midnights"
    var trackNumber: Int? = 4
    var duration: TimeInterval? = 256.13

    var json: [String: Any] {
        var result: [String: Any] = ["trackId": id, "trackName": title, "artistName": artist]
        if let album { result["collectionName"] = album }
        if let trackNumber { result["trackNumber"] = trackNumber }
        if let duration { result["trackTimeMillis"] = duration * 1000 }
        return result
    }
}

private final class ShazamEvidenceProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let name = request.value(forHTTPHeaderField: "X-Evidence-Fixture"),
              let fixture = ShazamEvidenceFixture.cases.first(where: { $0.name == name }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body: Data
        if url.host == "itunes.apple.com" {
            body = try! JSONSerialization.data(withJSONObject: ["results": fixture.searchHits.map(\.json)])
        } else if url.host == "www.shazam.com" {
            body = Data(fixture.html.utf8)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let responseURL = url.host == "www.shazam.com" && fixture.redirectedID != nil
            ? URL(string: "https://\(fixture.redirectedHost)/es-419/track/\(fixture.redirectedID!)/redirected/")! : url
        let response = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
