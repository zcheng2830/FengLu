import Foundation

struct LyricsResolver: Sendable {
    private struct ConfiguredSourceList {
        let value: String
        let originDescription: String
        let isBuiltInDefault: Bool
    }

    private struct LyricsConfigFileCandidate {
        let url: URL
        let isExplicit: Bool
    }

    private let session: URLSession?
    private let cacheRootDirectory: URL?

    /// `session` and `cacheRootDirectory` exist for tests; the app uses the
    /// lyrics lookup session and `~/Library/Caches`.
    init(session: URLSession? = nil, cacheRootDirectory: URL? = nil) {
        self.session = session
        self.cacheRootDirectory = cacheRootDirectory
    }

    func lyrics(for track: AudioTrack) async -> LyricsDocument {
        await lyrics(for: track, sourceNames: configuredSourceNames(), onlineEnabled: onlineLookupEnabled)
    }

    func lyrics(for track: AudioTrack, sourceNames: [String], onlineEnabled: Bool) async -> LyricsDocument {
        DebugLog.log(
            "Lyrics resolving title='\(track.title)' artist='\(track.artist ?? "")' album='\(track.album ?? "")' " +
            "file='\(track.url.path)' online=\(onlineEnabled) sources=\(sourceNames.joined(separator: ","))"
        )

        if sourceNames.contains("embedded"), let embeddedDocument = embeddedLyrics(for: track) {
            return embeddedDocument
        }

        if sourceNames.contains("local"), let localDocument = localLyrics(for: track) {
            DebugLog.log("Lyrics resolved from local sidecar: \(localDocument.sourceDescription)")
            return localDocument
        }

        if sourceNames.contains("cache"), let cachedDocument = cachedLyrics(for: track) {
            DebugLog.log("Lyrics resolved from cache: \(cachedDocument.sourceDescription)")
            return cachedDocument
        }

        let onlineSourceNames = sourceNames.filter { Self.isOnlineSource($0) }
        if onlineEnabled, !onlineSourceNames.isEmpty {
            DebugLog.log("Lyrics starting VLC-style online lookup for \(onlineSourceNames.count) source(s)")
            let onlineResolver = session.map { LyricsOnlineResolver(track: track, session: $0) }
                ?? LyricsOnlineResolver(track: track)
            let onlineResolution = await onlineResolver.lyrics(for: track, sourceNames: onlineSourceNames)
            // A superseded lookup may hold only the providers that answered
            // before cancellation. Nothing from it may reach the disk.
            if Task.isCancelled {
                DebugLog.log("Lyrics lookup cancelled; discarding online result without cache or sidecar writes")
                return metadataFallback(for: track)
            }

            if let onlineResolution {
                cache(onlineResolution, for: track)
                saveSidecar(onlineResolution, for: track)
                DebugLog.log(
                    "Lyrics resolved from online source='\(onlineResolution.sourceName)' " +
                    "score=\(onlineResolution.score) description='\(onlineResolution.document.sourceDescription)'"
                )
                return onlineResolution.document
            }

            DebugLog.log("Lyrics online lookup completed with no usable lyrics")
        } else if onlineSourceNames.isEmpty {
            DebugLog.log("Lyrics online lookup skipped because source list has no online providers")
        } else {
            DebugLog.log("Lyrics online lookup skipped because the lyrics window Online toggle is off")
        }

        DebugLog.log("Lyrics falling back to playing item metadata")
        return metadataFallback(for: track)
    }

    private var onlineLookupEnabled: Bool {
        UserDefaults.standard.object(forKey: LyricsConfiguration.onlineLookupEnabledKey) as? Bool
            ?? LyricsConfiguration.defaultOnlineLookupEnabled
    }

    func configuredSourceNames(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        savedSourceList: String? = UserDefaults.standard.string(forKey: LyricsConfiguration.sourceListKey)
    ) -> [String] {
        let configured = configuredSourceList(environment: environment, savedSourceList: savedSourceList)
        let configuredSourceList = configured.value
        let originDescription = configured.originDescription

        let separators = CharacterSet(charactersIn: ",;\n\t ")
        let rawSourceNames = configuredSourceList.components(separatedBy: separators)
        var sourceNames: [String] = []
        var seenSourceNames = Set<String>()
        var expandsCurrentDefaults = false

        for rawSourceName in rawSourceNames {
            let sourceName = canonicalSourceName(rawSourceName)
            guard !sourceName.isEmpty else {
                continue
            }

            if sourceName == "default" {
                expandsCurrentDefaults = true
                for defaultSource in sourceNamesFromDefaultSourceList()
                    where seenSourceNames.insert(defaultSource).inserted {
                    sourceNames.append(defaultSource)
                }
                continue
            }

            if sourceName == "lrclib" {
                for lrclibSourceName in ["lrclib-exact", "lrclib-search"]
                    where seenSourceNames.insert(lrclibSourceName).inserted {
                    sourceNames.append(lrclibSourceName)
                }
                continue
            }

            if seenSourceNames.insert(sourceName).inserted {
                sourceNames.append(sourceName)
            }
        }

        if sourceNames.isEmpty {
            DebugLog.log(
                "Lyrics configured source list from \(originDescription) '\(configuredSourceList)' " +
                "produced no valid sources; using VLC defaults"
            )
            return sourceNamesFromDefaultSourceList()
        }

        let policyDescription: String
        if expandsCurrentDefaults {
            policyDescription = "expanding the explicit default selection using the current built-in providers"
        } else if configured.isBuiltInDefault {
            policyDescription = "using the current built-in provider order"
        } else {
            policyDescription = "preserving this list without adding providers from the built-in default"
        }
        DebugLog.log("Lyrics configured source list from \(originDescription): \(sourceNames.joined(separator: ",")); \(policyDescription)")
        if sourceNames.contains("shazam") {
            DebugLog.log("Lyrics Shazam remains enabled by the explicit source list from \(originDescription)")
        }
        if !sourceNames.contains(where: Self.isOnlineSource) {
            DebugLog.log("Lyrics source list from \(originDescription) has no online providers")
        }
        return sourceNames
    }

    private func configuredSourceList(environment: [String: String], savedSourceList: String?) -> ConfiguredSourceList {
        if let environmentSourceList = environment[LyricsConfiguration.sourceListEnvironmentKey]?.nonEmpty {
            return ConfiguredSourceList(
                value: environmentSourceList,
                originDescription: "environment \(LyricsConfiguration.sourceListEnvironmentKey)",
                isBuiltInDefault: false
            )
        }

        if let configSourceList = configuredSourceListFromConfigFile(environment: environment) {
            return configSourceList
        }

        if let defaultsSourceList = savedSourceList?.nonEmpty {
            return ConfiguredSourceList(
                value: defaultsSourceList,
                originDescription: "UserDefaults \(LyricsConfiguration.sourceListKey)",
                isBuiltInDefault: false
            )
        }

        return ConfiguredSourceList(
            value: LyricsConfiguration.defaultSourceList,
            originDescription: "built-in VLC default",
            isBuiltInDefault: true
        )
    }

    private func configuredSourceListFromConfigFile(environment: [String: String]) -> ConfiguredSourceList? {
        for candidate in lyricsConfigFileCandidates(environment: environment) {
            guard fileExists(candidate.url) else {
                if candidate.isExplicit {
                    DebugLog.log(
                        "Lyrics config file from \(LyricsConfiguration.configPathEnvironmentKey) not found: " +
                        candidate.url.path
                    )
                }
                continue
            }

            do {
                let configText = try TextFileLoader.load(candidate.url)
                guard let sourceList = sourceList(fromConfigText: configText) else {
                    DebugLog.log("Lyrics config file has no source list entry: \(candidate.url.path)")
                    continue
                }

                return ConfiguredSourceList(
                    value: sourceList,
                    originDescription: "config file \(candidate.url.path)",
                    isBuiltInDefault: false
                )
            } catch {
                DebugLog.log(
                    "Lyrics config file read failed at \(candidate.url.path): \(error.localizedDescription)"
                )
            }
        }

        return nil
    }

    private func lyricsConfigFileCandidates(environment: [String: String]) -> [LyricsConfigFileCandidate] {
        if let explicitPath = environment[LyricsConfiguration.configPathEnvironmentKey]?.nonEmpty {
            return [
                LyricsConfigFileCandidate(
                    url: expandedFileURL(for: explicitPath),
                    isExplicit: true
                )
            ]
        }

        var candidates: [LyricsConfigFileCandidate] = []

        if let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            candidates.append(
                LyricsConfigFileCandidate(
                    url: applicationSupportDirectory
                        .appendingPathComponent(LyricsConfiguration.configDirectoryName, isDirectory: true)
                        .appendingPathComponent(LyricsConfiguration.configFileName),
                    isExplicit: false
                )
            )
        }

        candidates.append(
            LyricsConfigFileCandidate(
                url: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".config", isDirectory: true)
                    .appendingPathComponent("fenglu", isDirectory: true)
                    .appendingPathComponent(LyricsConfiguration.configFileName),
                isExplicit: false
            )
        )

        return candidates
    }

    private func expandedFileURL(for path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private func sourceList(fromConfigText configText: String) -> String? {
        var keyedSourceLists: [String] = []
        var plainSourceLists: [String] = []

        for rawLine in configText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else {
                continue
            }

            if let separatorIndex = line.firstIndex(of: "=") {
                let key = String(line[..<separatorIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[line.index(after: separatorIndex)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if isLyricsSourceListConfigKey(key), let sourceList = value.nonEmpty {
                    keyedSourceLists.append(sourceList)
                } else if !isLyricsSourceListConfigKey(key) {
                    DebugLog.log("Lyrics config ignoring unsupported key '\(key)'")
                }
                continue
            }

            if let sourceList = line.nonEmpty {
                plainSourceLists.append(sourceList)
            }
        }

        let selectedSourceLists = keyedSourceLists.isEmpty ? plainSourceLists : keyedSourceLists
        return selectedSourceLists.joined(separator: ",").nonEmpty
    }

    private func isLyricsSourceListConfigKey(_ key: String) -> Bool {
        switch compactSourceName(key) {
        case "source", "sources", "sourcelist", "lyricssource", "lyricssources", "lyricssourcelist":
            return true
        default:
            return false
        }
    }

    private func sourceNamesFromDefaultSourceList() -> [String] {
        LyricsConfiguration.defaultSourceList
            .components(separatedBy: ",")
            .map { canonicalSourceName($0) }
            .filter { !$0.isEmpty }
    }

    private func canonicalSourceName(_ rawSourceName: String) -> String {
        let compactSourceName = compactSourceName(rawSourceName)
        switch compactSourceName {
        case "":
            return ""
        case "default", "defaults":
            return "default"
        case "embedded", "metadata", "tag", "tags":
            return "embedded"
        case "local", "localfile", "localfiles", "file", "files", "sidecar":
            return "local"
        case "cache", "cached", "saved":
            return "cache"
        case "lrclib":
            return "lrclib"
        case "lrclibexact":
            return "lrclib-exact"
        case "lrclibsearch", "lrclibfallback":
            return "lrclib-search"
        case "netease", "neteasecloudmusic", "music163", "163":
            return "netease"
        case "qqmusic", "qq":
            return "qqmusic"
        case "lrcapi", "lrccx":
            return "lrcapi"
        case "kuwo":
            return "kuwo"
        case "kugou":
            return "kugou"
        case "musixmatch":
            return "musixmatch"
        case "shazam":
            return "shazam"
        case "letrasboom":
            return "letrasboom"
        case "azlyrics", "azlyricscom":
            return "azlyrics"
        case "songlyrics", "songlyricscom":
            return "songlyrics"
        case "lyricsify":
            return "lyricsify"
        case "letras", "letrascom":
            return "letras"
        case "lyricfind":
            return "lyricfind"
        case "bandcamp":
            return "bandcamp"
        case "darklyrics":
            return "darklyrics"
        case "metalarchives", "metalarchive":
            return "metalarchives"
        case "genius", "geniuscom":
            return "genius"
        default:
            DebugLog.log("Lyrics ignoring unknown configured source '\(rawSourceName)'")
            return ""
        }
    }

    private func compactSourceName(_ rawSourceName: String) -> String {
        LyricsTextNormalization.key(rawSourceName).replacingOccurrences(of: " ", with: "")
    }

    private static func isOnlineSource(_ sourceName: String) -> Bool {
        sourceName != "embedded" && sourceName != "local" && sourceName != "cache"
    }

    private func embeddedLyrics(for track: AudioTrack) -> LyricsDocument? {
        DebugLog.log(
            "Lyrics embedded source requested for '\(track.fileName)', " +
            "but Fenglu's current AudioTrack metadata has no embedded lyric tag storage yet"
        )
        return nil
    }

    private func localLyrics(for track: AudioTrack) -> LyricsDocument? {
        let candidateURLs = localCandidateURLs(for: track)
        DebugLog.log("Lyrics checking \(candidateURLs.count) local sidecar candidate(s)")

        for lyricsURL in candidateURLs {
            DebugLog.log("Lyrics local candidate: \(lyricsURL.path)")
            guard fileExists(lyricsURL) else {
                DebugLog.log("Lyrics local candidate missing: \(lyricsURL.lastPathComponent)")
                continue
            }

            guard let contents = readTextFile(at: lyricsURL) else {
                DebugLog.log("Lyrics local candidate read failed: \(lyricsURL.path)")
                continue
            }

            guard let document = LyricsParser.parse(
                contents,
                sourceURL: lyricsURL,
                sourceDescription: "Local lyrics: \(lyricsURL.lastPathComponent)"
            ) else {
                DebugLog.log("Lyrics local candidate parse failed: \(lyricsURL.path)")
                continue
            }

            guard LyricsParser.looksUsable(document.plainText) else {
                DebugLog.log("Lyrics local candidate rejected as non-lyric text: \(lyricsURL.path)")
                continue
            }

            return document
        }

        DebugLog.log("Lyrics no local sidecar matched")
        return nil
    }

    func localCandidateURLs(for track: AudioTrack) -> [URL] {
        let directory = track.url.deletingLastPathComponent()
        let baseNames = localBaseNames(for: track)

        var seenBaseNames = Set<String>()
        let uniqueBaseNames = baseNames.filter { baseName in
            seenBaseNames.insert(baseName).inserted
        }

        return uniqueBaseNames.flatMap { baseName in
            [
                directory.appendingPathComponent("\(baseName).lrc"),
                directory.appendingPathComponent("\(baseName).txt")
            ]
        }
    }

    /// Every track of a CUE image shares one media file, so the bare media
    /// base name can never identify one of them. CUE tracks only use
    /// per-track names, for both lookup and save.
    private func localBaseNames(for track: AudioTrack) -> [String] {
        // Composed names are sanitized the same way for lookup and save, so a
        // "/" in a tag (AC/DC) cannot point into another directory.
        let artistTitleName = track.artist?.nonEmpty.flatMap { artist in
            track.title.nonEmpty.map { sanitizedSidecarBaseName("\(artist) - \($0)") }
        }

        if track.source == .cue {
            return [artistTitleName, cueTrackBaseName(for: track)].compactMap(\.self)
        }

        let mediaBaseName = track.url.deletingPathExtension().lastPathComponent
        return [mediaBaseName, sanitizedSidecarBaseName(mediaBaseName), artistTitleName].compactMap(\.self)
    }

    private func cueTrackBaseName(for track: AudioTrack) -> String {
        let mediaBaseName = track.url.deletingPathExtension().lastPathComponent
        let number = track.trackNumber.map { String(format: "%02d", $0) }
        let suffix = [number, track.title.nonEmpty].compactMap(\.self).joined(separator: " ")
        return sanitizedSidecarBaseName(
            suffix.isEmpty ? "\(mediaBaseName) - track" : "\(mediaBaseName) - \(suffix)"
        )
    }

    private func cachedLyrics(for track: AudioTrack) -> LyricsDocument? {
        guard let cacheURL = cacheURL(for: track, createDirectory: false) else {
            DebugLog.log("Lyrics cache path unavailable for '\(track.title)'")
            return nil
        }

        DebugLog.log("Lyrics checking cache: \(cacheURL.path)")
        guard fileExists(cacheURL) else {
            DebugLog.log("Lyrics cache miss: \(cacheURL.lastPathComponent)")
            return nil
        }

        guard let contents = readTextFile(at: cacheURL),
              let document = LyricsParser.parse(
                  contents,
                  sourceURL: cacheURL,
                  sourceDescription: "Cached lyrics"
              ) else {
            DebugLog.log("Lyrics cache read or parse failed: \(cacheURL.path)")
            return nil
        }

        guard LyricsParser.looksUsable(document.plainText) else {
            DebugLog.log("Lyrics cache rejected as non-lyric text: \(cacheURL.path)")
            try? FileManager.default.removeItem(at: cacheURL)
            return nil
        }

        if document.isSynchronized, document.lines.count <= 1 {
            DebugLog.log("Lyrics cache rejected thin synchronized result: \(cacheURL.path)")
            try? FileManager.default.removeItem(at: cacheURL)
            return nil
        }

        guard document.isSynchronized else {
            DebugLog.log("Lyrics cache rejected plain online result: \(cacheURL.path)")
            try? FileManager.default.removeItem(at: cacheURL)
            return nil
        }

        saveSidecar(contents, document: document, for: track, originDescription: "cache")
        return document
    }

    private func cache(_ resolution: LyricsOnlineResolution, for track: AudioTrack) {
        guard resolution.document.isSynchronized else {
            DebugLog.log("Lyrics cache write skipped because selected online result is not synchronized")
            return
        }

        let lyrics = resolution.rawLyrics
        guard LyricsParser.looksUsable(lyrics) else {
            DebugLog.log("Lyrics cache write skipped because selected text is not usable")
            return
        }

        guard let cacheURL = cacheURL(for: track, createDirectory: true) else {
            DebugLog.log("Lyrics cache write skipped because cache URL is unavailable")
            return
        }

        do {
            try lyrics.write(to: cacheURL, atomically: true, encoding: .utf8)
            DebugLog.log("Lyrics cached online result at \(cacheURL.path)")
        } catch {
            DebugLog.log("Lyrics cache write failed at \(cacheURL.path): \(error.localizedDescription)")
        }
    }

    private func saveSidecar(_ resolution: LyricsOnlineResolution, for track: AudioTrack) {
        saveSidecar(
            resolution.rawLyrics,
            document: resolution.document,
            for: track,
            originDescription: "online"
        )
    }

    private func saveSidecar(
        _ lyrics: String,
        document: LyricsDocument,
        for track: AudioTrack,
        originDescription: String
    ) {
        // Same policy as the cache: only synchronized lyrics are kept. A plain
        // sidecar would win over every later synchronized result.
        guard document.isSynchronized else {
            DebugLog.log("Lyrics sidecar write skipped because selected \(originDescription) result is not synchronized")
            return
        }

        guard LyricsParser.looksUsable(lyrics) else {
            DebugLog.log("Lyrics sidecar write skipped because selected text is not usable")
            return
        }

        guard !Task.isCancelled else {
            DebugLog.log("Lyrics sidecar write skipped because the lookup was cancelled")
            return
        }

        let sidecarURL = sidecarSaveURL(for: track)
        do {
            // Never replace a file that is already there: it may be the user's.
            try Data(lyrics.utf8).write(to: sidecarURL, options: [.withoutOverwriting])
            DebugLog.log(
                "Lyrics saved \(originDescription) synchronized LRC sidecar at \(sidecarURL.path)"
            )
        } catch CocoaError.fileWriteFileExists {
            DebugLog.log("Lyrics sidecar write skipped because a file already exists at \(sidecarURL.path)")
        } catch {
            DebugLog.log("Lyrics sidecar write failed at \(sidecarURL.path): \(error.localizedDescription)")
        }
    }

    func sidecarSaveURL(for track: AudioTrack) -> URL {
        let directory = track.url.deletingLastPathComponent()
        let baseName: String

        if track.source == .cue {
            baseName = localBaseNames(for: track)[0]
        } else {
            baseName = track.url.deletingPathExtension().lastPathComponent
        }

        return directory.appendingPathComponent("\(sanitizedSidecarBaseName(baseName)).lrc")
    }

    private func sanitizedSidecarBaseName(_ baseName: String) -> String {
        let trimmedName = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegalCharacters = CharacterSet(charactersIn: "/:")
        let sanitizedName = trimmedName
            .components(separatedBy: illegalCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitizedName.nonEmpty ?? "lyrics"
    }

    private func cacheURL(for track: AudioTrack, createDirectory: Bool) -> URL? {
        guard let cacheKey = cacheKey(for: track) else {
            return nil
        }

        guard let cachesDirectory = cacheRootDirectory ?? FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let lyricsDirectory = cachesDirectory
            .appendingPathComponent(LyricsConfiguration.cacheDirectoryName, isDirectory: true)
        if createDirectory {
            do {
                try FileManager.default.createDirectory(
                    at: lyricsDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                DebugLog.log("Lyrics cache directory create failed: \(error.localizedDescription)")
                return nil
            }
        }

        return lyricsDirectory.appendingPathComponent(cacheKey)
    }

    func cacheKey(for track: AudioTrack) -> String? {
        let rawKey = [
            track.artist,
            track.album,
            track.title.nonEmpty ?? track.fileName
        ]
        .compactMap(\.self)
        .joined(separator: "-")
        .lowercased()

        let normalizedKey = rawKey
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        guard !normalizedKey.isEmpty else {
            return nil
        }

        // Tags alone collide for sparsely tagged files (two untagged "Intro"
        // tracks). The length separates recordings; without an artist the key
        // is tied to the file (and CUE track) itself.
        var discriminators: [String] = []
        let playableDuration: TimeInterval?
        if let cueStart = track.cueStart, let cueEnd = track.cueEnd, cueEnd > cueStart {
            playableDuration = cueEnd - cueStart
        } else {
            playableDuration = track.duration
        }
        if let playableDuration, playableDuration.isFinite, playableDuration > 0, playableDuration < 1_000_000 {
            discriminators.append("\(Int(playableDuration.rounded()))s")
        }
        if track.artist?.nonEmpty == nil {
            let identity = track.url.standardizedFileURL.path + "#\(track.trackNumber ?? 0)"
            discriminators.append(Self.stableHash(identity))
        }

        return ([normalizedKey] + discriminators).joined(separator: "-") + ".lrc"
    }

    /// FNV-1a; `Hasher` is seeded per process and cannot name files.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private func metadataFallback(for track: AudioTrack) -> LyricsDocument {
        var sections = [track.title]

        let metadataLines = [
            ("Artist", track.artist),
            ("Album", track.album),
            ("Track", track.trackNumber.map(String.init)),
            ("Path", track.url.path.nonEmpty)
        ]
        .compactMap { metadata -> String? in
            let (label, value) = metadata
            guard let value = value?.nonEmpty else {
                return nil
            }

            return "\(label): \(value)"
        }

        if !metadataLines.isEmpty {
            sections.append(metadataLines.joined(separator: "\n"))
        }

        let text = sections.joined(separator: "\n\n")
        let lines = text.components(separatedBy: .newlines)
            .enumerated()
            .map { index, text in
                LyricsLine(id: index, time: nil, text: text)
            }

        return LyricsDocument(
            sourceURL: nil,
            sourceDescription: "Playing item description",
            lines: lines,
            plainText: text,
            isSynchronized: false
        )
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func readTextFile(at url: URL) -> String? {
        do {
            return try TextFileLoader.load(url)
        } catch {
            DebugLog.log("Lyrics text load failed for \(url.path): \(error.localizedDescription)")
            return nil
        }
    }
}
