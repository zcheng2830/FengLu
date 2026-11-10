import Foundation

enum LyricsAliasConfiguration {
    static func aliasGroups(for track: AudioTrack) -> [[String]] {
        let configURL = aliasConfigURL(for: track)
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            DebugLog.log("Lyrics semantic alias config not found beside media: \(configURL.path)")
            return []
        }

        let groups = aliasGroups(
            from: configURL,
            trackNumber: track.trackNumber,
            trackTitle: track.title,
            description: "media config \(configURL.path)"
        )
        DebugLog.log(
            "Lyrics semantic alias config loaded \(groups.count) group(s) for " +
            "track='\(track.title)' number=\(display(track.trackNumber))"
        )
        return groups
    }

    private static func aliasConfigURL(for track: AudioTrack) -> URL {
        let baseName = track.playlistName?.nonEmpty
            ?? track.url.deletingPathExtension().lastPathComponent

        return track.url
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(sanitizedFileBaseName(baseName)).\(LyricsConfiguration.aliasConfigFileSuffix)"
            )
    }

    private static func sanitizedFileBaseName(_ baseName: String) -> String {
        let illegalCharacters = CharacterSet(charactersIn: "/:")
        let sanitizedName = baseName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: illegalCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitizedName.nonEmpty ?? "playlist"
    }

    private static func aliasGroups(
        from url: URL,
        trackNumber: Int?,
        trackTitle: String,
        description: String
    ) -> [[String]] {
        do {
            let data = try Data(contentsOf: url)
            let file = try decodeAliasFile(from: data)
            let folderGroups = normalizedAliasGroups(file.folderGroups)
            let trackGroups = trackNumber.flatMap { file.trackGroupsByNumber[$0] } ?? []
            let normalizedTrackGroups = normalizedAliasGroups(trackGroups)
            let bridgedTrackGroups = bridgedTrackTitleGroups(
                trackTitle: trackTitle,
                trackGroups: normalizedTrackGroups
            )
            let groups = mergeAliasGroups(
                folderGroups,
                overridingWith: normalizedTrackGroups + bridgedTrackGroups
            )
            DebugLog.log(
                "Lyrics semantic alias config loaded from \(description): " +
                "folderGroups=\(folderGroups.count) trackGroups=\(normalizedTrackGroups.count) " +
                "bridgedTrackGroups=\(bridgedTrackGroups.count)"
            )
            return groups
        } catch {
            DebugLog.log("Lyrics semantic alias config read failed from \(description): \(error.localizedDescription)")
            return []
        }
    }

    private static func decodeAliasFile(from data: Data) throws -> DecodedLyricsAliasFile {
        let decoder = JSONDecoder()

        if let file = try? decoder.decode(LyricsAliasFile.self, from: data) {
            let decoded = file.decoded
            if !decoded.folderGroups.isEmpty || !decoded.trackGroupsByNumber.isEmpty {
                return decoded
            }
        }

        if let groups = try? decoder.decode([[String]].self, from: data) {
            return DecodedLyricsAliasFile(folderGroups: groups)
        }

        let aliases = try decoder.decode([String: [String]].self, from: data)
        return DecodedLyricsAliasFile(folderGroups: groups(from: aliases))
    }

    private static func normalizedAliasGroups(_ groups: [[String]]) -> [[String]] {
        groups
            .map { group in
                LyricsTextNormalization.uniqueNonEmptyStrings(group.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            }
            .filter { $0.count >= 2 }
    }

    private static func bridgedTrackTitleGroups(
        trackTitle: String,
        trackGroups: [[String]]
    ) -> [[String]] {
        guard let title = trackTitle.nonEmpty,
              !trackGroups.isEmpty
        else {
            return []
        }

        let bridgedValues = LyricsTextNormalization.uniqueNonEmptyStrings([title] + trackGroups.flatMap { $0 })
        return bridgedValues.count >= 2 ? [bridgedValues] : []
    }

    private static func mergeAliasGroups(
        _ folderGroups: [[String]],
        overridingWith trackGroups: [[String]]
    ) -> [[String]] {
        var orderedKeys: [String] = []
        var groupsByKey: [String: [String]] = [:]

        func store(_ group: [String]) {
            guard let firstValue = group.first?.nonEmpty else {
                return
            }

            let key = LyricsTextNormalization.key(firstValue)
            guard !key.isEmpty else {
                return
            }

            if groupsByKey[key] == nil {
                orderedKeys.append(key)
            }
            groupsByKey[key] = group
        }

        folderGroups.forEach(store)
        trackGroups.forEach(store)

        return orderedKeys.compactMap { groupsByKey[$0] }
    }

    private static func groups(from aliases: [String: [String]]) -> [[String]] {
        aliases
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { [$0.key] + $0.value }
    }

    private static func display(_ value: Int?) -> String {
        value.map(String.init) ?? "<none>"
    }
}

private struct DecodedLyricsAliasFile {
    var folderGroups: [[String]]
    var trackGroupsByNumber: [Int: [[String]]]

    init(folderGroups: [[String]], trackGroupsByNumber: [Int: [[String]]] = [:]) {
        self.folderGroups = folderGroups
        self.trackGroupsByNumber = trackGroupsByNumber
    }
}

private struct LyricsAliasFile: Decodable {
    var aliasGroups: [[String]]?
    var aliases: LyricsAliasCollection?
    var tracks: [String: LyricsAliasTrackFile]?
    var trackAliases: [String: LyricsAliasCollection]?

    var decoded: DecodedLyricsAliasFile {
        var folderGroups = aliasGroups ?? []
        if let aliases {
            folderGroups.append(contentsOf: aliases.groups)
        }

        var trackGroupsByNumber: [Int: [[String]]] = [:]
        for (rawNumber, trackFile) in tracks ?? [:] {
            guard let number = Int(rawNumber.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                continue
            }

            trackGroupsByNumber[number, default: []].append(contentsOf: trackFile.groups)
        }

        for (rawNumber, aliases) in trackAliases ?? [:] {
            guard let number = Int(rawNumber.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                continue
            }

            trackGroupsByNumber[number, default: []].append(contentsOf: aliases.groups)
        }

        return DecodedLyricsAliasFile(
            folderGroups: folderGroups,
            trackGroupsByNumber: trackGroupsByNumber
        )
    }
}

private struct LyricsAliasTrackFile: Decodable {
    var aliasGroups: [[String]]?
    var aliases: LyricsAliasCollection?

    var groups: [[String]] {
        var groups = aliasGroups ?? []
        if let aliases {
            groups.append(contentsOf: aliases.groups)
        }
        return groups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let aliases = try? container.decode(LyricsAliasCollection.self) {
            self.aliasGroups = nil
            self.aliases = aliases
            return
        }

        let object = try LyricsAliasTrackObject(from: decoder)
        self.aliasGroups = object.aliasGroups
        self.aliases = object.aliases
    }
}

private struct LyricsAliasTrackObject: Decodable {
    var aliasGroups: [[String]]?
    var aliases: LyricsAliasCollection?
}

private enum LyricsAliasCollection: Decodable {
    case groups([[String]])
    case map([String: [String]])

    var groups: [[String]] {
        switch self {
        case .groups(let groups):
            return groups
        case .map(let map):
            return LyricsAliasConfigurationGroups.groups(from: map)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let groups = try? container.decode([[String]].self) {
            self = .groups(groups)
            return
        }

        self = .map(try container.decode([String: [String]].self))
    }
}

private enum LyricsAliasConfigurationGroups {
    static func groups(from aliases: [String: [String]]) -> [[String]] {
        aliases
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { [$0.key] + $0.value }
    }
}
