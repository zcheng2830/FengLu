import Foundation

struct FilenameMetadata: Equatable {
    var title: String?
    var artist: String?
    var trackNumber: Int?
}

enum FilenameMetadataParser {
    static func parse(_ url: URL) -> FilenameMetadata {
        let originalTitle = url.deletingPathExtension().lastPathComponent
        let numberedName = stripLeadingTrackNumber(from: originalTitle)
        let name = numberedName.name.nonEmpty ?? originalTitle
        let parts = name.components(separatedBy: " - ")
            .compactMap(\.nonEmpty)

        // "Title - Live" is a title with a version suffix, not "Artist - Title".
        let isTitleWithVersionSuffix = parts.count == 2 && looksLikeVersionSuffix(parts[1])

        if parts.count >= 2, !isTitleWithVersionSuffix {
            return FilenameMetadata(
                title: parts.dropFirst().joined(separator: " - "),
                artist: parts.first,
                trackNumber: numberedName.trackNumber
            )
        }

        return FilenameMetadata(
            title: name,
            artist: nil,
            trackNumber: numberedName.trackNumber
        )
    }

    /// A leading number is a track number only when the name says so: either an
    /// explicit separator follows it ("3 - Title", "3. Title", "03_Title") or it
    /// is zero-padded ("03 Title"). A bare "99 Luftballons" keeps its number.
    private static let trackNumberPatterns: [NSRegularExpression] = [
        #"^\s*(\d{1,3})(?:\s*[-_]\s*(?!\d)|\.(?!\d)\s*|\s+-\s+)(.+)$"#,
        #"^\s*(0\d{1,2})\s+(.+)$"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static func stripLeadingTrackNumber(from value: String) -> (trackNumber: Int?, name: String) {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)

        for expression in trackNumberPatterns {
            guard let match = expression.firstMatch(in: value, range: range),
                  match.numberOfRanges >= 3,
                  let numberRange = Range(match.range(at: 1), in: value),
                  let nameRange = Range(match.range(at: 2), in: value),
                  let trackNumber = Int(value[numberRange]),
                  (1...199).contains(trackNumber)
            else {
                continue
            }

            return (trackNumber, String(value[nameRange]))
        }

        return (nil, value)
    }

    /// A version label must be the whole part, not just its first word, so real
    /// titles such as "Live Forever" or "Stereo Love" are left alone. Accepted:
    /// a label alone ("Live", "Remastered"), a label with a fixed qualifier
    /// and/or year ("Acoustic Version", "Remastered 2011", "2011 Remaster",
    /// "Radio Edit"), and "Live at/from <place>", optionally in brackets.
    private static let versionSuffixExpression = try? NSRegularExpression(
        pattern: #"""
        ^[(\[]?(?:
            (?:live|acoustic|unplugged|demo|instrumental|karaoke|remix|remaster(?:ed)?|mono|stereo|extended|reprise)
                (?:\ (?:version|mix|edit|take|cut|recording|session))?(?:\ (?:19|20)\d{2})?
          | (?:single|album|radio|extended|bonus)\ (?:version|mix|edit|track)
          | live\ (?:at|from)\ .+
          | (?:19|20)\d{2}\ (?:digital\ )?remaster(?:ed)?(?:\ version)?
        )[)\]]?$
        """#,
        options: [.caseInsensitive, .allowCommentsAndWhitespace]
    )

    private static func looksLikeVersionSuffix(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespaces)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return versionSuffixExpression?.firstMatch(in: value, range: range) != nil
    }
}
