import Foundation

struct LyricsOnlineResolution: Sendable {
    var document: LyricsDocument
    var rawLyrics: String
    var sourceName: String
    var score: Int
}

struct LyricsOnlineResolver: Sendable {
    private static let userAgent = "FengluPlayer lyrics lookup"
    // Bracketed credits may contain spaced dashes in performer names. Outside
    // brackets a dash ends the credit, preserving any recording/version suffix
    // without maintaining a language-specific list of version labels.
    private static let featuredCreditExpression = try! NSRegularExpression(
        pattern: #"\s*[\(\[]\s*(?:feat(?:uring)?\.?|ft\.?)\s+([^\[\]\(\)]+)[\]\)]|(?:\s*,\s*(?:feat(?:uring)?\.?|ft\.?)|\s+(?:feat\.|ft\.|featuring))\s+([^\[\]\(\)]+?)(?=\s+[-–—]\s+|[\[\]\(\)]|$)"#,
        options: [.caseInsensitive]
    )
    private static let titleEditionExpression = try! NSRegularExpression(
        pattern: #"\s*[\(\[]\s*deluxe(?:\s+edition)?\s*[\)\]]|\s+[-–—]\s+deluxe(?:\s+edition)?\s*$"#,
        options: [.caseInsensitive]
    )
    private static let titleRemasterExpression = try! NSRegularExpression(
        pattern: #"\s*[\(\[]\s*(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?\s*[\)\]]|\s+[-–—]\s+(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?\s*$"#,
        options: [.caseInsensitive]
    )
    private static let bareFeatureExpression = try! NSRegularExpression(pattern: #"\s+(feat|ft)(?=\s)"#, options: [.caseInsensitive])
    private static let shazamLocaleExpression = try! NSRegularExpression(
        pattern: #"^[a-z]{2,3}(?:-[a-z0-9]{2,8})*$"#, options: [.caseInsensitive]
    )
    /// One response may not exceed this; lyric pages and API replies are far smaller.
    static let maximumResponseBytes = 4 * 1024 * 1024
    /// The whole lookup, across every provider and chained request.
    static let defaultLookupDeadline: TimeInterval = 25

    /// `URLSession.shared` has no usable resource timeout (seven days), so a
    /// slow-dripping host could hold a lookup open indefinitely.
    static let lookupSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    private let semanticSearchAliasMap: [String: [String]]
    private let session: URLSession
    private let lookupDeadline: TimeInterval

    init(
        track: AudioTrack,
        session: URLSession = LyricsOnlineResolver.lookupSession,
        lookupDeadline: TimeInterval = LyricsOnlineResolver.defaultLookupDeadline
    ) {
        self.semanticSearchAliasMap = Self.aliasMap(from: LyricsAliasConfiguration.aliasGroups(for: track))
        self.session = session
        self.lookupDeadline = lookupDeadline
    }

    private static func aliasMap(from aliasGroups: [[String]]) -> [String: [String]] {
        var aliases: [String: Set<String>] = [:]
        for group in aliasGroups {
            for value in group {
                let key = LyricsTextNormalization.key(value)
                guard !key.isEmpty else {
                    continue
                }

                for alias in group where alias != value {
                    aliases[key, default: []].insert(alias)
                }
            }
        }

        return aliases.mapValues { $0.sorted() }
    }

    func lyrics(for track: AudioTrack, sourceNames: [String]) async -> LyricsOnlineResolution? {
        let requests = onlineLookupRequests(for: track, sourceNames: sourceNames)
        guard !requests.isEmpty else {
            DebugLog.log("Lyrics online lookup has no usable request URLs")
            return nil
        }

        DebugLog.log(
            "Lyrics querying \(requests.count) online URL(s) in parallel from sources: " +
            sourceNames.joined(separator: ",")
        )

        let deadline = lookupDeadline
        return await withTaskGroup(of: OnlineLookupEvent.self) { group in
            for request in requests {
                group.addTask {
                    .candidate(await fetchOnlineCandidate(request, track: track))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(deadline, 0) * 1_000_000_000))
                return .deadlineReached
            }

            var candidates: [OnlineLyricsCandidate] = []
            var remainingRequests = requests.count
            collect: for await event in group {
                switch event {
                case .deadlineReached:
                    if !Task.isCancelled {
                        DebugLog.log(
                            "Lyrics online lookup reached its \(display(deadline))s deadline with " +
                            "\(remainingRequests) request(s) outstanding; using \(candidates.count) candidate(s)"
                        )
                    }
                    break collect
                case .candidate(let candidate):
                    remainingRequests -= 1
                    if let candidate {
                        candidates.append(candidate)
                        DebugLog.log(
                            "Lyrics online candidate source='\(candidate.sourceName)' provider='\(candidate.providerName)' " +
                            "score=\(candidate.score) synchronized=\(candidate.document.isSynchronized) " +
                            "strongTitle=\(candidate.match.isStrongTitle)"
                        )
                        if candidate.isHighConfidence {
                            DebugLog.log(
                                "Lyrics online lookup stopping early on high-confidence synchronized match from " +
                                "\(candidate.providerName); \(remainingRequests) request(s) cancelled"
                            )
                            break collect
                        }
                    }
                    if remainingRequests == 0 {
                        break collect
                    }
                }
            }
            group.cancelAll()

            // A cancelled lookup only holds the providers that happened to
            // answer first. Returning their best would save a partial result.
            guard !Task.isCancelled else {
                DebugLog.log("Lyrics online lookup cancelled; discarding \(candidates.count) partial candidate(s)")
                return nil
            }

            guard let bestCandidate = candidates.sorted(by: bestCandidateSort).first else {
                return nil
            }

            DebugLog.log(
                "Lyrics selected online source='\(bestCandidate.sourceName)' " +
                "provider='\(bestCandidate.providerName)' score=\(bestCandidate.score) " +
                "strongTitle=\(bestCandidate.match.isStrongTitle)"
            )
            return LyricsOnlineResolution(
                document: bestCandidate.document,
                rawLyrics: bestCandidate.rawLyrics,
                sourceName: bestCandidate.sourceName,
                score: bestCandidate.score
            )
        }
    }

    private func onlineLookupRequests(
        for track: AudioTrack,
        sourceNames: [String]
    ) -> [OnlineLyricsRequest] {
        let metadataVariants = lookupMetadataVariants(for: track)
        let primaryMetadata = metadataVariants[0]
        var requests: [OnlineLyricsRequest] = []
        var seenURLs = Set<String>()

        for sourceName in sourceNames {
            var variants = allowsAliasLookup(for: sourceName) ? metadataVariants : [primaryMetadata]
            if sourceName.hasPrefix("lrclib") {
                // LRCLIB filters on album_name, so a differing album tag (a
                // deluxe edition, a compilation) hides the song. Ask again
                // without it; the reply is validated like any other.
                variants += variants.filter { !$0.album.isEmpty }.map { metadata in
                    var withoutAlbum = metadata
                    withoutAlbum.album = ""
                    return withoutAlbum
                }
            }
            for metadata in variants {
                guard let request = onlineLookupRequest(for: sourceName, metadata: metadata) else {
                    continue
                }

                guard seenURLs.insert(request.url.absoluteString).inserted else {
                    DebugLog.log("Lyrics skipping duplicate \(request.providerName) URL: \(logURL(request.url))")
                    continue
                }

                DebugLog.log("Lyrics prepared \(request.providerName) URL: \(logURL(request.url))")
                requests.append(request)
            }
        }

        return requests
    }

    private func onlineLookupRequest(
        for sourceName: String,
        metadata: LyricsLookupMetadata
    ) -> OnlineLyricsRequest? {
        let providerName = providerName(for: sourceName)
        let url: URL?

        switch sourceName {
        case "lrclib-exact":
            url = lrclibURL(for: metadata, exactMatch: true)
        case "lrclib-search":
            url = lrclibURL(for: metadata, exactMatch: false)
        case "netease":
            url = netEaseSearchURL(for: metadata)
        case "qqmusic":
            url = qqMusicSearchURL(for: metadata)
        case "lrcapi":
            url = lrcAPISearchURL(for: metadata)
        case "kuwo":
            url = kuwoSearchURL(for: metadata)
        case "kugou":
            url = kuGouSearchURL(for: metadata)
        case "musixmatch":
            url = musixmatchSearchURL(for: metadata)
        case "shazam":
            url = shazamSearchURL(for: metadata)
        case "letrasboom":
            url = letrasBoomArtistURL(for: metadata)
        case "azlyrics":
            url = azLyricsURL(for: metadata)
        case "songlyrics":
            url = songLyricsURL(for: metadata)
        case "lyricsify":
            url = lyricsifyURL(for: metadata)
        case "letras":
            url = letrasURL(for: metadata)
        case "lyricfind":
            url = lyricFindURL(for: metadata)
        case "bandcamp":
            url = bandcampURL(for: metadata, pageIndex: 1)
        case "darklyrics":
            url = darkLyricsURL(for: metadata)
        case "metalarchives":
            url = metalArchivesSearchURL(for: metadata)
        case "genius":
            url = geniusLookupURL(for: metadata)
        default:
            DebugLog.log("Lyrics has no online URL builder for source '\(sourceName)'")
            url = nil
        }

        guard let url else {
            DebugLog.log("Lyrics skipped \(providerName) because required metadata or token is missing")
            return nil
        }

        return OnlineLyricsRequest(sourceName: sourceName, providerName: providerName, url: url)
    }

    private func fetchOnlineCandidate(
        _ lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) async -> OnlineLyricsCandidate? {
        do {
            DebugLog.log("Lyrics requesting \(lookupRequest.providerName): \(logURL(lookupRequest.url))")
            let (data, response) = try await responseData(for: urlRequest(for: lookupRequest))
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? 0
            let responseURL = httpResponse?.url ?? lookupRequest.url
            DebugLog.log(
                "Lyrics response \(lookupRequest.providerName) status=\(status) " +
                "bytes=\(data.count) url=\(logURL(responseURL))"
            )

            guard status == 0 || 200..<400 ~= status else {
                DebugLog.log(
                    "Lyrics \(lookupRequest.providerName) HTTP failure body='\(responseBodySnippet(from: data))'"
                )
                if lookupRequest.sourceName == "genius",
                   lookupRequest.url.host == "api.genius.com" {
                    return await geniusWebsiteSearchFallback(
                        lookupRequest: lookupRequest,
                        track: track,
                        reason: "Genius API HTTP \(status)"
                    )
                }

                return nil
            }

            guard let candidate = await onlineCandidate(
                from: data,
                responseURL: responseURL,
                lookupRequest: lookupRequest,
                track: track
            ) else {
                DebugLog.log("Lyrics \(lookupRequest.providerName) returned no usable lyric text")
                return nil
            }

            return candidate
        } catch is CancellationError {
            DebugLog.log("Lyrics request cancelled: \(lookupRequest.providerName)")
            return nil
        } catch {
            DebugLog.log(
                "Lyrics request failed \(lookupRequest.providerName): \(error.localizedDescription) " +
                "url=\(logURL(lookupRequest.url))"
            )
            return nil
        }
    }

    private func onlineCandidate(
        from data: Data,
        responseURL: URL,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) async -> OnlineLyricsCandidate? {
        DebugLog.log(
            "Lyrics dispatching query result source='\(lookupRequest.sourceName)' " +
            "host='\(responseURL.host ?? "")' path='\(responseURL.path)'"
        )

        switch lookupRequest.sourceName {
        case "lrclib-exact", "lrclib-search":
            return lrclibCandidate(from: data, lookupRequest: lookupRequest, track: track)
        case "netease":
            return await netEaseCandidate(from: data, lookupRequest: lookupRequest, track: track)
        case "qqmusic":
            return await qqMusicCandidate(from: data, lookupRequest: lookupRequest, track: track)
        case "lrcapi":
            return lrcAPICandidate(from: data, lookupRequest: lookupRequest, track: track)
        case "kuwo":
            return await kuwoCandidate(from: data, lookupRequest: lookupRequest, track: track)
        case "kugou":
            return await kuGouCandidate(from: data, lookupRequest: lookupRequest, track: track)
        case "musixmatch":
            return await musixmatchCandidate(from: data, lookupRequest: lookupRequest, track: track)
        case "shazam":
            return await shazamCandidate(from: data, lookupRequest: lookupRequest, track: track)
        case "letrasboom":
            return await letrasBoomCandidate(
                from: data,
                responseURL: responseURL,
                lookupRequest: lookupRequest,
                track: track
            )
        case "lyricfind":
            return lyricFindCandidate(from: data, lookupRequest: lookupRequest, track: track)
        case "bandcamp":
            return await bandcampCandidate(from: data, lookupRequest: lookupRequest, track: track)
        case "metalarchives":
            return await metalArchivesCandidate(from: data, lookupRequest: lookupRequest, track: track)
        case "genius":
            return await geniusCandidate(
                from: data,
                responseURL: responseURL,
                lookupRequest: lookupRequest,
                track: track
            )
        case "azlyrics", "songlyrics", "lyricsify", "letras", "darklyrics":
            guard let page = LyricsHTMLPage.parse(
                htmlString(from: data), context: "\(lookupRequest.providerName) \(responseURL.absoluteString)"
            ) else { return nil }
            return simpleHTMLCandidate(
                page: page,
                responseURL: responseURL,
                lookupRequest: lookupRequest,
                track: track
            )
        default:
            return genericCandidate(from: data, lookupRequest: lookupRequest, track: track)
        }
    }

    private func urlRequest(for lookupRequest: OnlineLyricsRequest) -> URLRequest {
        var request = URLRequest(url: lookupRequest.url, timeoutInterval: 12.0)
        let host = lookupRequest.url.host?.lowercased() ?? ""

        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if jsonHosts.contains(host) {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        switch host {
        case "music.163.com":
            request.httpMethod = "POST"
            request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
            request.setValue("appver=2.0.2", forHTTPHeaderField: "Cookie")
            request.setValue("202.96.0.0", forHTTPHeaderField: "X-Real-IP")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        case "c.y.qq.com":
            request.setValue("http://y.qq.com/portal/player.html", forHTTPHeaderField: "Referer")
        case "apic-desktop.musixmatch.com":
            request.setValue("AWSELBCORS=0; AWSELB=0", forHTTPHeaderField: "Cookie")
        case "search.kuwo.cn", "m.kuwo.cn":
            request.setValue("https://www.kuwo.cn/", forHTTPHeaderField: "Referer")
        case "krcs.kugou.com", "lyrics.kugou.com", "lyrics2.kugou.com":
            request.setValue("https://www.kugou.com/", forHTTPHeaderField: "Referer")
        case "www.azlyrics.com", "lyrics.lyricfind.com":
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:128.0) Gecko/20100101 Firefox/128.0",
                forHTTPHeaderField: "User-Agent"
            )
        case "api.genius.com":
            if let token = geniusAccessToken() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        default:
            break
        }

        return request
    }

    private var jsonHosts: Set<String> {
        [
            "lrclib.net",
            "itunes.apple.com",
            "music.163.com",
            "c.y.qq.com",
            "api.lrc.cx",
            "search.kuwo.cn",
            "m.kuwo.cn",
            "krcs.kugou.com",
            "lyrics.kugou.com",
            "lyrics2.kugou.com",
            "apic-desktop.musixmatch.com",
            "www.metal-archives.com"
        ]
    }

    /// The single network entry point: enforces the body size cap and turns a
    /// declared legacy charset (GBK, Shift-JIS, ...) into UTF-8 once, so every
    /// JSON and HTML consumer sees the same text.
    private func responseData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let limit = Self.maximumResponseBytes
        if response.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            throw URLError(.dataLengthExceedsMaximum)
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        var buffer: [UInt8] = []
        buffer.reserveCapacity(16 * 1024)
        var total = 0
        for try await byte in bytes {
            buffer.append(byte)
            total += 1
            if total > limit {
                bytes.task.cancel()
                throw URLError(.dataLengthExceedsMaximum)
            }
            if buffer.count == 16 * 1024 {
                data.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        data.append(contentsOf: buffer)

        if let charset = response.textEncodingName,
           let encoding = Self.stringEncoding(forCharset: charset),
           encoding != .utf8,
           String(data: data, encoding: .utf8) == nil,
           let text = String(data: data, encoding: encoding) {
            return (Data(text.utf8), response)
        }
        return (data, response)
    }

    private static func stringEncoding(forCharset charset: String) -> String.Encoding? {
        let name = charset.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")).lowercased()
        guard !name.isEmpty else {
            return nil
        }

        let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard encoding != kCFStringEncodingInvalidId else {
            return nil
        }

        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    /// Tokens travel in the query string for Musixmatch; keep them out of logs.
    private func logURL(_ url: URL) -> String {
        Self.redactedURLString(url)
    }

    static func redactedURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              queryItems.contains(where: { Self.secretQueryItemNames.contains($0.name.lowercased()) })
        else {
            return url.absoluteString
        }

        components.queryItems = queryItems.map { item in
            Self.secretQueryItemNames.contains(item.name.lowercased())
                ? URLQueryItem(name: item.name, value: "REDACTED")
                : item
        }
        return components.string ?? "\(url.scheme ?? "")://\(url.host ?? "")\(url.path)?REDACTED"
    }

    private static let secretQueryItemNames: Set<String> = [
        "usertoken", "access_token", "token", "apikey", "api_key"
    ]

    private func fetchSecondaryData(_ url: URL, providerName: String) async -> Data? {
        await fetchSecondaryResponse(url, providerName: providerName)?.data
    }

    private func fetchSecondaryResponse(_ url: URL, providerName: String) async -> (data: Data, url: URL)? {
        let request = OnlineLyricsRequest(
            sourceName: providerName.lowercased(),
            providerName: providerName,
            url: url
        )

        do {
            let (data, response) = try await responseData(for: urlRequest(for: request))
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? 0
            DebugLog.log(
                "Lyrics loaded \(providerName) secondary URL status=\(status) " +
                "bytes=\(data.count) url=\(logURL(url))"
            )
            guard status == 0 || 200..<400 ~= status else {
                DebugLog.log("Lyrics \(providerName) secondary HTTP failure body='\(responseBodySnippet(from: data))'")
                return nil
            }

            return (data, response.url ?? url)
        } catch {
            DebugLog.log(
                "Lyrics failed loading \(providerName) secondary URL: \(error.localizedDescription) " +
                "url=\(logURL(url))"
            )
            return nil
        }
    }

    private func lookupMetadata(for track: AudioTrack) -> LyricsLookupMetadata {
        LyricsLookupMetadata(
            title: track.title.nonEmpty ?? track.url.deletingPathExtension().lastPathComponent,
            artist: track.artist?.nonEmpty ?? "",
            album: track.album?.nonEmpty ?? "",
            duration: playableDuration(for: track) ?? track.duration
        )
    }

    private func lookupMetadataVariants(for track: AudioTrack) -> [LyricsLookupMetadata] {
        let metadata = lookupMetadata(for: track)
        let titleAliases = semanticSearchAliases(for: metadata.title)
        let artistAliases = semanticSearchAliases(for: metadata.artist)
        let albumAliases = semanticSearchAliases(for: metadata.album)

        var variants = [metadata]
        if artistAliases.first != nil || albumAliases.first != nil {
            variants.append(
                LyricsLookupMetadata(
                    title: metadata.title,
                    artist: artistAliases.first ?? metadata.artist,
                    album: albumAliases.first ?? metadata.album,
                    duration: metadata.duration
                )
            )
        }

        for titleAlias in titleAliases {
            variants.append(
                LyricsLookupMetadata(
                    title: titleAlias,
                    artist: artistAliases.first ?? metadata.artist,
                    album: albumAliases.first ?? metadata.album,
                    duration: metadata.duration
                )
            )
        }

        return uniqueMetadataVariants(variants)
    }

    private func allowsAliasLookup(for sourceName: String) -> Bool {
        [
            "lrclib-exact",
            "lrclib-search",
            "netease",
            "qqmusic",
            "lrcapi",
            "kuwo",
            "kugou",
            "shazam",
            "genius"
        ].contains(sourceName)
    }

    private func uniqueMetadataVariants(_ variants: [LyricsLookupMetadata]) -> [LyricsLookupMetadata] {
        var seen = Set<String>()
        return variants.filter { metadata in
            let key = [
                normalizedSearchText(metadata.title),
                normalizedSearchText(metadata.artist),
                normalizedSearchText(metadata.album)
            ].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }

    private func providerName(for sourceName: String) -> String {
        switch sourceName {
        case "lrclib-exact", "lrclib-search":
            return "LRCLIB"
        case "netease":
            return "NetEase Cloud Music"
        case "qqmusic":
            return "QQ Music"
        case "lrcapi":
            return "LrcAPI"
        case "kuwo":
            return "Kuwo Music"
        case "kugou":
            return "KuGou Music"
        case "musixmatch":
            return "Musixmatch"
        case "shazam":
            return "Shazam"
        case "letrasboom":
            return "LetrasBoom"
        case "azlyrics":
            return "AZLyrics"
        case "songlyrics":
            return "SongLyrics"
        case "lyricsify":
            return "Lyricsify"
        case "letras":
            return "letras.com"
        case "lyricfind":
            return "LyricFind"
        case "bandcamp":
            return "Bandcamp"
        case "darklyrics":
            return "DarkLyrics"
        case "metalarchives":
            return "Metal-Archives"
        case "genius":
            return "Genius"
        default:
            return sourceName
        }
    }

    private func lrclibURL(for metadata: LyricsLookupMetadata, exactMatch: Bool) -> URL? {
        var title = metadata.title
        if !exactMatch {
            title = simplifiedTitleForSearch(title)
        }

        guard !title.isEmpty else {
            return nil
        }

        if exactMatch && (metadata.artist.isEmpty || metadata.duration == nil) {
            return nil
        }

        var queryItems = [
            URLQueryItem(name: "track_name", value: title)
        ]
        if !metadata.artist.isEmpty {
            queryItems.append(URLQueryItem(name: "artist_name", value: metadata.artist))
        }
        if !metadata.album.isEmpty {
            queryItems.append(URLQueryItem(name: "album_name", value: metadata.album))
        }
        if exactMatch, let duration = metadata.duration {
            queryItems.append(URLQueryItem(name: "duration", value: "\(Int(duration.rounded()))"))
        }

        return url(
            exactMatch ? "https://lrclib.net/api/get" : "https://lrclib.net/api/search",
            queryItems: queryItems
        )
    }

    private func netEaseSearchURL(for metadata: LyricsLookupMetadata) -> URL? {
        guard !metadata.title.isEmpty else {
            return nil
        }

        return url(
            "https://music.163.com/api/search/get",
            queryItems: [
                URLQueryItem(name: "s", value: metadata.searchQuery),
                URLQueryItem(name: "type", value: "1"),
                URLQueryItem(name: "offset", value: "0"),
                URLQueryItem(name: "sub", value: "false"),
                URLQueryItem(name: "limit", value: "5")
            ]
        )
    }

    private func qqMusicSearchURL(for metadata: LyricsLookupMetadata) -> URL? {
        guard !metadata.title.isEmpty else {
            return nil
        }

        return url(
            "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg",
            queryItems: [
                URLQueryItem(name: "inCharset", value: "utf-8"),
                URLQueryItem(name: "outCharset", value: "utf-8"),
                URLQueryItem(name: "key", value: metadata.searchQuery)
            ]
        )
    }

    private func lrcAPISearchURL(for metadata: LyricsLookupMetadata) -> URL? {
        guard !metadata.title.isEmpty else {
            return nil
        }

        return url(
            "https://api.lrc.cx/api/v1/lyrics/advance",
            queryItems: [
                URLQueryItem(name: "title", value: metadata.title),
                URLQueryItem(name: "artist", value: metadata.artist),
                URLQueryItem(name: "album", value: metadata.album)
            ]
        )
    }

    private func kuwoSearchURL(for metadata: LyricsLookupMetadata) -> URL? {
        guard !metadata.title.isEmpty else {
            return nil
        }

        return url(
            "https://search.kuwo.cn/r.s",
            queryItems: [
                URLQueryItem(name: "all", value: metadata.searchQuery),
                URLQueryItem(name: "ft", value: "music"),
                URLQueryItem(name: "itemset", value: "web_2013"),
                URLQueryItem(name: "client", value: "kt"),
                URLQueryItem(name: "pn", value: "0"),
                URLQueryItem(name: "rn", value: "5"),
                URLQueryItem(name: "rformat", value: "json"),
                URLQueryItem(name: "encoding", value: "utf8")
            ]
        )
    }

    private func kuGouSearchURL(for metadata: LyricsLookupMetadata) -> URL? {
        guard !metadata.title.isEmpty else {
            return nil
        }

        let durationMilliseconds = metadata.duration.map { "\(Int(($0 * 1000).rounded()))" } ?? "0"
        return url(
            "https://krcs.kugou.com/search",
            queryItems: [
                URLQueryItem(name: "ver", value: "1"),
                URLQueryItem(name: "man", value: "no"),
                URLQueryItem(name: "client", value: "pc"),
                URLQueryItem(name: "keyword", value: metadata.searchQuery),
                URLQueryItem(name: "duration", value: durationMilliseconds),
                URLQueryItem(name: "hash", value: ""),
                URLQueryItem(name: "album_audio_id", value: ""),
                URLQueryItem(name: "lrctxt", value: "1")
            ]
        )
    }

    private func musixmatchSearchURL(for metadata: LyricsLookupMetadata) -> URL? {
        guard let token = musixmatchUserToken() else {
            DebugLog.log("Lyrics skipping Musixmatch because no user token is configured")
            return nil
        }
        guard !metadata.title.isEmpty else {
            return nil
        }

        return url(
            "https://apic-desktop.musixmatch.com/ws/1.1/track.search",
            queryItems: [
                URLQueryItem(name: "user_language", value: "en"),
                URLQueryItem(name: "app_id", value: "web-desktop-app-v1.0"),
                URLQueryItem(name: "subtitle_format", value: "lrc"),
                URLQueryItem(name: "q_artist", value: metadata.artist),
                URLQueryItem(name: "q_album", value: metadata.album),
                URLQueryItem(name: "q_track", value: metadata.title),
                URLQueryItem(name: "usertoken", value: token)
            ]
        )
    }

    private func shazamSearchURL(for metadata: LyricsLookupMetadata) -> URL? {
        guard !metadata.title.isEmpty else {
            return nil
        }

        return url(
            "https://itunes.apple.com/search",
            queryItems: [
                URLQueryItem(name: "term", value: metadata.searchQuery),
                URLQueryItem(name: "media", value: "music"),
                URLQueryItem(name: "entity", value: "song"),
                URLQueryItem(name: "limit", value: "10")
            ]
        )
    }

    private func letrasBoomArtistURL(for metadata: LyricsLookupMetadata) -> URL? {
        let artistSlug = simpleSlug(metadata.artist)
        guard !artistSlug.isEmpty else {
            return nil
        }

        return URL(string: "https://www.letrasboom.com/artista/\(artistSlug)")
    }

    private func azLyricsURL(for metadata: LyricsLookupMetadata) -> URL? {
        let artistSlug = compactSlug(metadata.artist)
        let titleSlug = compactSlug(metadata.title)
        guard !artistSlug.isEmpty, !titleSlug.isEmpty else {
            return nil
        }

        return URL(string: "https://www.azlyrics.com/lyrics/\(artistSlug)/\(titleSlug).html")
    }

    private func songLyricsURL(for metadata: LyricsLookupMetadata) -> URL? {
        let artistSlug = songLyricsSlug(metadata.artist)
        let titleSlug = songLyricsSlug(metadata.title)
        guard !artistSlug.isEmpty, !titleSlug.isEmpty else {
            return nil
        }

        return URL(string: "https://songlyrics.com/\(artistSlug)/\(titleSlug)-lyrics/")
    }

    private func lyricsifyURL(for metadata: LyricsLookupMetadata) -> URL? {
        let artistSlug = simpleSlug(metadata.artist)
        let titleSlug = simpleSlug(metadata.title)
        guard !artistSlug.isEmpty, !titleSlug.isEmpty else {
            return nil
        }

        return URL(string: "https://www.lyricsify.com/lyrics/\(artistSlug)/\(titleSlug)")
    }

    private func letrasURL(for metadata: LyricsLookupMetadata) -> URL? {
        var artist = metadata.artist
        if artist.lowercased().hasPrefix("the ") {
            artist = String(artist.dropFirst(4))
        }

        let artistSlug = simpleSlug(artist)
        let titleSlug = simpleSlug(metadata.title)
        guard !artistSlug.isEmpty, !titleSlug.isEmpty else {
            return nil
        }

        return URL(string: "https://www.letras.com/\(artistSlug)/\(titleSlug)")
    }

    private func lyricFindURL(for metadata: LyricsLookupMetadata) -> URL? {
        let artistSlug = simpleSlug(metadata.artist)
        let titleSlug = simpleSlug(metadata.title)
        guard !artistSlug.isEmpty, !titleSlug.isEmpty else {
            return nil
        }

        return URL(string: "https://lyrics.lyricfind.com/lyrics/\(artistSlug)-\(titleSlug)")
    }

    private func bandcampURL(for metadata: LyricsLookupMetadata, pageIndex: Int) -> URL? {
        let artistSlug = compactSlug(metadata.artist)
        let titleSlug = simpleSlug(metadata.title)
        guard !artistSlug.isEmpty, !titleSlug.isEmpty else {
            return nil
        }

        let pageSuffix = pageIndex > 1 ? "-\(pageIndex)" : ""
        return URL(string: "https://\(artistSlug).bandcamp.com/track/\(titleSlug)\(pageSuffix)")
    }

    private func darkLyricsURL(for metadata: LyricsLookupMetadata) -> URL? {
        let artistSlug = compactSlug(metadata.artist)
        let albumSlug = compactSlug(metadata.album)
        guard !artistSlug.isEmpty, !albumSlug.isEmpty else {
            return nil
        }

        return URL(string: "https://darklyrics.com/lyrics/\(artistSlug)/\(albumSlug).html")
    }

    private func metalArchivesSearchURL(for metadata: LyricsLookupMetadata) -> URL? {
        guard !metadata.title.isEmpty else {
            return nil
        }

        return url(
            "https://www.metal-archives.com/search/ajax-advanced/searching/songs",
            queryItems: [
                URLQueryItem(name: "bandName", value: metadata.artist),
                URLQueryItem(name: "releaseTitle", value: metadata.album),
                URLQueryItem(name: "songTitle", value: metadata.title)
            ]
        )
    }

    private func geniusLookupURL(for metadata: LyricsLookupMetadata) -> URL? {
        guard !metadata.title.isEmpty else {
            return nil
        }

        if geniusAccessToken() != nil {
            return url(
                "https://api.genius.com/search",
                queryItems: [URLQueryItem(name: "q", value: metadata.searchQuery)]
            )
        }

        DebugLog.log("Lyrics no Genius API token configured; using Genius website search")
        return url(
            "https://genius.com/search",
            queryItems: [URLQueryItem(name: "q", value: metadata.searchQuery)]
        )
    }

    private func url(_ string: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: string)
        components?.queryItems = queryItems
        // URLComponents leaves "+" alone, and servers read it as a space
        // ("1+1" would arrive as "1 1").
        let encodedQuery = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        return components?.url
    }

    private func lrclibCandidate(
        from data: Data,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) -> OnlineLyricsCandidate? {
        do {
            if lookupRequest.sourceName == "lrclib-exact" {
                let result = try JSONDecoder().decode(LRCLIBLyrics.self, from: data)
                return candidate(from: result, lookupRequest: lookupRequest, track: track)
            }

            let results = try JSONDecoder().decode([LRCLIBLyrics].self, from: data)
            DebugLog.log("Lyrics LRCLIB search returned \(results.count) result(s)")
            return results
                .compactMap { result -> (score: Int, candidate: OnlineLyricsCandidate)? in
                    guard let candidate = candidate(from: result, lookupRequest: lookupRequest, track: track) else {
                        return nil
                    }

                    return (lrclibMatchScore(result, track: track), candidate)
                }
                .sorted {
                    if $0.score == $1.score {
                        return $0.candidate.document.isSynchronized && !$1.candidate.document.isSynchronized
                    }

                    return $0.score > $1.score
                }
                .first?
                .candidate
        } catch {
            DebugLog.log("Lyrics LRCLIB parse failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func candidate(
        from result: LRCLIBLyrics,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) -> OnlineLyricsCandidate? {
        guard let rawLyrics = result.syncedLyrics?.nonEmpty ?? result.plainLyrics?.nonEmpty else {
            return nil
        }

        let providerName = result.syncedLyrics?.nonEmpty == nil ? "LRCLIB" : "LRCLIB synced"
        let title = result.trackName?.nonEmpty ?? track.title
        let metadata = CandidateMetadata(
            title: title,
            artist: result.artistName?.nonEmpty ?? track.artist ?? "",
            album: result.albumName ?? "",
            duration: result.duration
        )
        let titleScore = titleMatchScore(candidateTitle: metadata.title, track: track)
        guard let match = candidateMatch(metadata, titleScore: titleScore, track: track) else {
            DebugLog.log(
                "Lyrics \(providerName) rejected result because title/artist did not match current track: " +
                "candidate='\(title)' artist='\(metadata.artist)' track='\(track.title)' titleScore=\(titleScore)"
            )
            return nil
        }

        let sourceDescription = "\(providerName): \(metadata.artist) - \(metadata.title)"
        return candidate(
            from: rawLyrics,
            sourceDescription: sourceDescription,
            lookupRequest: lookupRequest,
            providerName: providerName,
            track: track,
            match: match
        )
    }

    private func netEaseCandidate(
        from data: Data,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) async -> OnlineLyricsCandidate? {
        guard let json = jsonObject(from: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            return nil
        }

        let songs = dictionaries(from: result["songs"])
        DebugLog.log("Lyrics NetEase search returned \(songs.count) song candidate(s)")
        guard let bestSong = bestDictionaryCandidate(
            from: songs,
            track: track,
            providerName: "NetEase",
            metadataBuilder: { song in
            let firstArtist = dictionaries(from: song["artists"]).first
            let album = song["album"] as? [String: Any]
            let durationMilliseconds = numberValue(song["duration"])
            return CandidateMetadata(
                title: stringValue(song["name"]),
                artist: stringValue(firstArtist?["name"]),
                album: stringValue(album?["name"]),
                duration: durationMilliseconds.map { $0 / 1000.0 },
                trackNumber: trackNumberValue(song)
            )
            }
        ) else {
            return nil
        }

        let songID = stringValue(bestSong.value["id"])
        guard !songID.isEmpty,
              let lyricsURL = url(
                  "https://music.163.com/api/song/lyric",
                  queryItems: [
                      URLQueryItem(name: "tv", value: "-1"),
                      URLQueryItem(name: "kv", value: "-1"),
                      URLQueryItem(name: "lv", value: "-1"),
                      URLQueryItem(name: "os", value: "pc"),
                      URLQueryItem(name: "id", value: songID)
                  ]
              ),
              let lyricsData = await fetchSecondaryData(lyricsURL, providerName: lookupRequest.providerName),
              let lyricsJSON = jsonObject(from: lyricsData) as? [String: Any],
              let lrc = lyricsJSON["lrc"] as? [String: Any]
        else {
            return nil
        }

        return candidate(
            from: stringValue(lrc["lyric"]),
            sourceDescription: lookupRequest.providerName,
            lookupRequest: lookupRequest,
            track: track,
            match: bestSong.match
        )
    }

    private func qqMusicCandidate(
        from data: Data,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) async -> OnlineLyricsCandidate? {
        guard let json = jsonObject(from: data) as? [String: Any],
              let dataDictionary = json["data"] as? [String: Any],
              let songDictionary = dataDictionary["song"] as? [String: Any] else {
            return nil
        }

        let songs = dictionaries(from: songDictionary["itemlist"])
        DebugLog.log("Lyrics QQ Music search returned \(songs.count) song candidate(s)")
        guard let bestSong = bestDictionaryCandidate(
            from: songs,
            track: track,
            providerName: "QQ Music",
            metadataBuilder: { song in
            CandidateMetadata(
                title: stringValue(song["name"]),
                artist: stringValue(song["singer"]),
                album: "",
                duration: nil
            )
            }
        ) else {
            return nil
        }

        let songMid = stringValue(bestSong.value["mid"])
        guard !songMid.isEmpty,
              let lyricsURL = url(
                  "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg",
                  queryItems: [
                      URLQueryItem(name: "g_tk", value: "5381"),
                      URLQueryItem(name: "format", value: "json"),
                      URLQueryItem(name: "inCharset", value: "utf-8"),
                      URLQueryItem(name: "outCharset", value: "utf-8"),
                      URLQueryItem(name: "songmid", value: songMid)
                  ]
              ),
              let lyricsData = await fetchSecondaryData(lyricsURL, providerName: lookupRequest.providerName),
              let lyricsJSON = jsonObject(from: lyricsData) as? [String: Any]
        else {
            return nil
        }

        let encodedLyrics = stringValue(lyricsJSON["lyric"])
        return candidate(
            from: base64DecodedString(encodedLyrics),
            sourceDescription: lookupRequest.providerName,
            lookupRequest: lookupRequest,
            track: track,
            match: bestSong.match
        )
    }

    private func lrcAPICandidate(
        from data: Data,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) -> OnlineLyricsCandidate? {
        guard let json = jsonObject(from: data) else {
            return nil
        }

        // Every element of a result list names its own song. Once the list is
        // rejected, scraping "any lyric-looking string" out of the same JSON
        // would return the lyrics of a song that was just refused.
        if let results = json as? [Any] {
            let dictionaries = results.compactMap { $0 as? [String: Any] }
            DebugLog.log("Lyrics LrcAPI returned \(dictionaries.count) result candidate(s)")
            guard let bestResult = bestDictionaryCandidate(
                from: dictionaries,
                track: track,
                providerName: "LrcAPI",
                metadataBuilder: lrcAPIMetadata
            ), let lyrics = likelyLyricsString(in: bestResult.value) else {
                return nil
            }

            return candidate(
                from: lyrics,
                sourceDescription: lookupRequest.providerName,
                lookupRequest: lookupRequest,
                track: track,
                match: bestResult.match
            )
        }

        if let result = json as? [String: Any], !lrcAPIMetadata(result).title.isEmpty {
            guard let bestResult = bestDictionaryCandidate(
                from: [result], track: track, providerName: "LrcAPI", metadataBuilder: lrcAPIMetadata
            ), let lyrics = likelyLyricsString(in: bestResult.value) else {
                return nil
            }

            return candidate(
                from: lyrics,
                sourceDescription: lookupRequest.providerName,
                lookupRequest: lookupRequest,
                track: track,
                match: bestResult.match
            )
        }

        return genericCandidate(from: data, lookupRequest: lookupRequest, track: track)
    }

    private func lrcAPIMetadata(_ result: [String: Any]) -> CandidateMetadata {
        CandidateMetadata(
            title: stringValue(result["title"]),
            artist: stringValue(result["artist"]),
            album: stringValue(result["album"]),
            duration: nil
        )
    }

    private func kuwoCandidate(
        from data: Data,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) async -> OnlineLyricsCandidate? {
        guard let json = jsonObject(from: data) as? [String: Any] else {
            return nil
        }

        let songs = dictionaries(from: json["abslist"])
        DebugLog.log("Lyrics Kuwo search returned \(songs.count) song candidate(s)")
        guard let bestSong = bestDictionaryCandidate(
            from: songs,
            track: track,
            providerName: "Kuwo",
            metadataBuilder: { song in
            CandidateMetadata(
                title: stringValue(song["SONGNAME"]),
                artist: stringValue(song["ARTIST"]),
                album: stringValue(song["ALBUM"]),
                duration: nil
            )
            }
        ) else {
            return nil
        }

        var musicID = stringValue(bestSong.value["MUSICRID"])
        if musicID.hasPrefix("MUSIC_") {
            musicID = String(musicID.dropFirst("MUSIC_".count))
        }

        guard !musicID.isEmpty,
              let lyricsURL = url(
                  "https://m.kuwo.cn/newh5/singles/songinfoandlrc",
                  queryItems: [
                      URLQueryItem(name: "musicId", value: musicID),
                      URLQueryItem(name: "httpsStatus", value: "1")
                  ]
              ),
              let lyricsData = await fetchSecondaryData(lyricsURL, providerName: lookupRequest.providerName)
        else {
            return nil
        }

        return candidate(
            from: kuwoLyricsString(from: lyricsData),
            sourceDescription: lookupRequest.providerName,
            lookupRequest: lookupRequest,
            track: track,
            match: bestSong.match
        )
    }

    private func kuGouCandidate(
        from data: Data,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) async -> OnlineLyricsCandidate? {
        guard let json = jsonObject(from: data) as? [String: Any] else {
            return nil
        }

        let candidates = dictionaries(from: json["candidates"])
        DebugLog.log("Lyrics KuGou search returned \(candidates.count) candidate(s)")
        guard let bestCandidate = bestDictionaryCandidate(
            from: candidates,
            track: track,
            providerName: "KuGou",
            metadataBuilder: { candidate in
            let filename = stringValue(candidate["filename"])
            var artist = stringValue(candidate["singer"])
            var title = stringValue(candidate["song"]).nonEmpty ?? stringValue(candidate["name"])
            if (artist.isEmpty || title.isEmpty), !filename.isEmpty {
                let parts = filename.components(separatedBy: " - ")
                if parts.count >= 2 {
                    if artist.isEmpty {
                        artist = parts[0]
                    }
                    if title.isEmpty {
                        title = parts.dropFirst().joined(separator: " - ")
                    }
                }
            }

            let duration = numberValue(candidate["duration"]).map { value in
                value > 10_000 ? value / 1000.0 : value
            }
            return CandidateMetadata(title: title, artist: artist, album: "", duration: duration)
            }
        ) else {
            return nil
        }

        let lyricID = stringValue(bestCandidate.value["id"])
        let accessKey = stringValue(bestCandidate.value["accesskey"])
        guard !lyricID.isEmpty,
              !accessKey.isEmpty,
              let lyricsURL = url(
                  "https://lyrics2.kugou.com/download",
                  queryItems: [
                      URLQueryItem(name: "ver", value: "1"),
                      URLQueryItem(name: "client", value: "pc"),
                      URLQueryItem(name: "id", value: lyricID),
                      URLQueryItem(name: "accesskey", value: accessKey),
                      URLQueryItem(name: "fmt", value: "lrc"),
                      URLQueryItem(name: "charset", value: "utf8")
                  ]
              ),
              let lyricsData = await fetchSecondaryData(lyricsURL, providerName: lookupRequest.providerName)
        else {
            return nil
        }

        return candidate(
            from: kuGouLyricsString(from: lyricsData),
            sourceDescription: lookupRequest.providerName,
            lookupRequest: lookupRequest,
            track: track,
            match: bestCandidate.match
        )
    }

    private func musixmatchCandidate(
        from data: Data,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) async -> OnlineLyricsCandidate? {
        guard let token = musixmatchUserToken(),
              let json = jsonObject(from: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let body = message["body"] as? [String: Any] else {
            return nil
        }

        let trackList = dictionaries(from: body["track_list"])
        DebugLog.log("Lyrics Musixmatch search returned \(trackList.count) track candidate(s)")
        guard let bestWrapper = bestDictionaryCandidate(
            from: trackList,
            track: track,
            providerName: "Musixmatch",
            metadataBuilder: { wrapper in
            let track = wrapper["track"] as? [String: Any]
            return CandidateMetadata(
                title: stringValue(track?["track_name"]),
                artist: stringValue(track?["artist_name"]),
                album: stringValue(track?["album_name"]),
                duration: numberValue(track?["track_length"])
            )
            }
        ), let bestTrack = bestWrapper.value["track"] as? [String: Any] else {
            return nil
        }

        let commonTrackID = stringValue(bestTrack["commontrack_id"])
        guard !commonTrackID.isEmpty else {
            return nil
        }

        let hasSubtitles = (numberValue(bestTrack["has_subtitles"]) ?? 0) != 0
        let method = hasSubtitles ? "track.subtitle.get" : "track.lyrics.get"
        let bodyKey = hasSubtitles ? "subtitle" : "lyrics"
        let textKey = hasSubtitles ? "subtitle_body" : "lyrics_body"

        guard let lyricsURL = url(
            "https://apic-desktop.musixmatch.com/ws/1.1/\(method)",
            queryItems: [
                URLQueryItem(name: "user_language", value: "en"),
                URLQueryItem(name: "app_id", value: "web-desktop-app-v1.0"),
                URLQueryItem(name: "commontrack_id", value: commonTrackID),
                URLQueryItem(name: "usertoken", value: token)
            ]
        ), let lyricsData = await fetchSecondaryData(lyricsURL, providerName: lookupRequest.providerName),
           let lyricsJSON = jsonObject(from: lyricsData) as? [String: Any],
           let lyricsMessage = lyricsJSON["message"] as? [String: Any],
           let lyricsBody = lyricsMessage["body"] as? [String: Any],
           let lyricsDictionary = lyricsBody[bodyKey] as? [String: Any]
        else {
            return nil
        }

        return candidate(
            from: stringValue(lyricsDictionary[textKey]),
            sourceDescription: lookupRequest.providerName,
            lookupRequest: lookupRequest,
            track: track,
            match: bestWrapper.match
        )
    }

    private func shazamCandidate(
        from data: Data,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) async -> OnlineLyricsCandidate? {
        guard let json = jsonObject(from: data) as? [String: Any] else {
            return nil
        }

        let results = dictionaries(from: json["results"])
        DebugLog.log("Lyrics Shazam/iTunes search returned \(results.count) result(s)")
        let lookup = lookupMetadata(for: track)
        let requestedMetadata = CandidateMetadata(
            title: lookup.title, artist: lookup.artist, album: "", duration: nil
        )
        let requested = pageIdentity(for: requestedMetadata, allowingUnlabeledEdition: true)
        let prepared = results.map { result -> ShazamSearchCandidate in
            let metadata = CandidateMetadata(
                title: stringValue(result["trackName"]),
                artist: stringValue(result["artistName"]),
                album: stringValue(result["collectionName"]),
                duration: numberValue(result["trackTimeMillis"]).map { $0 / 1000.0 },
                trackNumber: trackNumberValue(result)
            )
            let identity = pageIdentity(for: metadata)
            var expected = requested
            // A bare marker is ambiguous in isolation ("A Feat of Strength").
            // Only interpret it as a credit after the entire credited title
            // agrees with an explicitly marked credit in the search result.
            if !featuredCredit(in: metadata.title).guests.isEmpty,
               !creditedTitleIdentities(lookup.title).isDisjoint(with: creditedTitleIdentities(metadata.title)) {
                var confirmed = requestedMetadata
                confirmed.title = Self.bareFeatureExpression.stringByReplacingMatches(
                    in: lookup.title, range: NSRange(lookup.title.startIndex..<lookup.title.endIndex, in: lookup.title),
                    withTemplate: " $1."
                )
                if confirmed.title != lookup.title {
                    expected = pageIdentity(for: confirmed, allowingUnlabeledEdition: true)
                }
            }
            if track.artist?.nonEmpty == nil { expected.artists = identity.artists }
            let strictMatch = pageIdentityMatches(identity, expected: expected)
            let leadOnlyMatch = pageIdentityMatches(identity, expected: expected, allowingLeadOnlyCredit: true)
            // Once search expands a lead-only tag, require that complete credit
            // on the ID-verified page, without relying on schema array ordering.
            if !strictMatch && leadOnlyMatch {
                expected.artists = identity.artists
            } else if strictMatch {
                // Explicit iTunes featured credits also corroborate performers
                // in an unordered page array, without dropping tagged primaries.
                expected.artists.credits += identity.artists.credits
            }
            return ShazamSearchCandidate(
                dictionary: result, metadata: metadata, expected: expected,
                isAcceptable: strictMatch || leadOnlyMatch
            )
        }
        var eligible = prepared.filter { $0.isAcceptable && !stringValue($0.dictionary["trackId"]).isEmpty }
        if lookup.artist.isEmpty {
            let byTrackID = Dictionary(grouping: eligible) { stringValue($0.dictionary["trackId"]) }
            let contextScores = byTrackID.mapValues { candidates in
                candidates.map { candidateContextMatchScore($0.metadata, track: track) }.max() ?? 0
            }
            let bestContext = contextScores.values.max() ?? 0
            let winners = contextScores.filter { $0.value == bestContext }
            // A lone search hit can still be the wrong namesake. Every artist-less
            // lookup needs combined album/track/duration evidence for one ID.
            guard bestContext >= 7, winners.count == 1, let winner = winners.first else {
                DebugLog.log("Lyrics Shazam rejected uncorroborated artist-less search: \(byTrackID.count) matching track IDs, best context=\(bestContext)")
                return nil
            }
            eligible = byTrackID[winner.key] ?? []
        }
        guard let selected = bestMetadataCandidate(
            from: eligible, track: track, providerName: "Shazam",
            metadataBuilder: { $0.metadata }, candidatesArePrevalidated: true
        ) else { return nil }
        let bestResult = selected.value
        let expected = bestResult.expected
        if track.artist?.nonEmpty == nil {
            DebugLog.log("Lyrics Shazam using selected iTunes artist '\(bestResult.metadata.artist)' because the track has no artist tag")
        }
        let trackID = stringValue(bestResult.dictionary["trackId"])
        let slug = shazamSlug(bestResult.metadata.title)
        guard !trackID.isEmpty,
              !slug.isEmpty,
              let lyricsURL = URL(string: "https://www.shazam.com/song/\(trackID)/\(slug)"),
              let pageResponse = await fetchSecondaryResponse(lyricsURL, providerName: lookupRequest.providerName)
        else {
            return nil
        }

        guard let page = LyricsHTMLPage.parse(
            htmlString(from: pageResponse.data), context: "Shazam \(pageResponse.url.absoluteString)"
        ) else { return nil }
        guard let recordings = validatedShazamRecordings(
            page: page, pageURL: pageResponse.url, requestedTrackID: trackID, expected: expected
        ) else {
            DebugLog.log("Lyrics rejected Shazam page with missing or mismatched song metadata: \(lyricsURL.absoluteString)")
            return nil
        }
        let structuredTexts = recordings.flatMap(\.lyrics)
            .map(cleanupLyricsText).filter(LyricsParser.looksUsable)
        let structuredLyrics = structuredTexts.max(by: { lhs, rhs in
            let leftLines = LyricsParser.contentLineCount(lhs)
            let rightLines = LyricsParser.contentLineCount(rhs)
            return leftLines == rightLines ? lhs.count < rhs.count : leftLines < rightLines
        })
        guard let lyrics = structuredLyrics else {
            DebugLog.log("Lyrics Shazam page matched song metadata but has no usable anchored structured lyrics: \(lyricsURL.absoluteString)")
            return nil
        }
        return candidate(
            from: lyrics,
            sourceDescription: lookupRequest.providerName,
            lookupRequest: lookupRequest,
            track: track
        )
    }

    private func letrasBoomCandidate(
        from data: Data,
        responseURL: URL,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) async -> OnlineLyricsCandidate? {
        let lyricsData: Data
        let lyricsURL: URL
        if responseURL.path.hasPrefix("/artista/") {
            guard let selectedURL = letrasBoomLyricsURL(fromArtistPageData: data, baseURL: responseURL, track: track),
                  let pageData = await fetchSecondaryData(selectedURL, providerName: lookupRequest.providerName)
            else { return nil }
            lyricsData = pageData
            lyricsURL = selectedURL
        } else {
            lyricsData = data
            lyricsURL = responseURL
        }
        guard let page = LyricsHTMLPage.parse(
            htmlString(from: lyricsData), context: "LetrasBoom \(lyricsURL.absoluteString)"
        ), htmlLyricsPageMatches(
            page: page, pageURL: lyricsURL, track: track, providerName: lookupRequest.providerName
        ) else { return nil }

        return candidate(
            from: letrasBoomLyricsString(in: page, track: track),
            sourceDescription: lookupRequest.providerName,
            lookupRequest: lookupRequest,
            track: track
        )
    }

    private func lyricFindCandidate(
        from data: Data,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) -> OnlineLyricsCandidate? {
        guard let page = LyricsHTMLPage.parse(
            htmlString(from: data), context: "LyricFind \(lookupRequest.url.absoluteString)"
        ) else { return nil }
        let nextData = page.scriptContent(withID: "__NEXT_DATA__")
        if let nextDataObject = nextData.data(using: .utf8).flatMap({ jsonObject(from: $0) }) as? [String: Any],
           let props = nextDataObject["props"] as? [String: Any],
           let pageProps = props["pageProps"] as? [String: Any],
           let songData = pageProps["songData"] as? [String: Any],
           let trackDictionary = songData["track"] as? [String: Any] {
            return candidate(
                from: stringValue(trackDictionary["lyrics"]),
                sourceDescription: lookupRequest.providerName,
                lookupRequest: lookupRequest,
                track: track
            )
        }

        return simpleHTMLCandidate(
            page: page,
            responseURL: lookupRequest.url,
            lookupRequest: lookupRequest,
            track: track
        )
    }

    private func bandcampCandidate(
        from data: Data,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) async -> OnlineLyricsCandidate? {
        let metadata = lookupMetadata(for: track)
        var lyricsString = bandcampLyricsString(from: data, pageURL: lookupRequest.url)
        if !LyricsParser.looksUsable(lyricsString) {
            for pageIndex in 2..<8 {
                guard let pageURL = bandcampURL(for: metadata, pageIndex: pageIndex),
                      let pageData = await fetchSecondaryData(pageURL, providerName: lookupRequest.providerName)
                else {
                    break
                }

                lyricsString = bandcampLyricsString(from: pageData, pageURL: pageURL)
                if LyricsParser.looksUsable(lyricsString) {
                    break
                }
            }
        }

        return candidate(
            from: lyricsString,
            sourceDescription: lookupRequest.providerName,
            lookupRequest: lookupRequest,
            track: track
        )
    }

    private func metalArchivesCandidate(
        from data: Data,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) async -> OnlineLyricsCandidate? {
        guard let json = jsonObject(from: data) as? [String: Any],
              let rows = json["aaData"] as? [[Any]] else {
            return nil
        }

        // Rows are judged before looking for a lyrics link. If the requested
        // song is listed without lyrics, a longer namesake ("War" -> "Warlord")
        // must not be taken in its place.
        var bestLyricsID = ""
        var bestScore = 0
        var bestTitleScore = 0
        for (rowIndex, row) in rows.enumerated() where row.count >= 5 {
            let title = fragmentText(
                fromHTML: stringValue(row[3]),
                context: "Metal-Archives \(lookupRequest.url.absoluteString) row=\(rowIndex + 1) title cell"
            )
            let lyricsCell = stringValue(row[4])
            let lyricsID = firstRegexCapture(in: lyricsCell, pattern: #"lyricsLink_(\d+)"#)
            let artist = fragmentText(
                fromHTML: stringValue(row[0]),
                context: "Metal-Archives \(lookupRequest.url.absoluteString) row=\(rowIndex + 1) artist cell"
            )
            let album = fragmentText(
                fromHTML: stringValue(row[1]),
                context: "Metal-Archives \(lookupRequest.url.absoluteString) row=\(rowIndex + 1) album cell"
            )
            let titleScore = titleMatchScore(candidateTitle: title, track: track)
            let metadata = CandidateMetadata(title: title, artist: artist, album: album, duration: nil)
            guard titleScore >= Self.strongTitleScore,
                  candidateMatch(metadata, titleScore: titleScore, track: track) != nil
            else {
                DebugLog.log(
                    "Lyrics Metal-Archives rejected row title='\(title)' artist='\(artist)' titleScore=\(titleScore)"
                )
                continue
            }

            let score = candidateMatchScore(
                title: title,
                artist: artist,
                album: album,
                duration: nil,
                track: track
            )
            DebugLog.log(
                "Lyrics Metal-Archives candidate score=\(score) titleScore=\(titleScore) " +
                "title='\(title)' artist='\(artist)' hasLyrics=\(!lyricsID.isEmpty)"
            )
            if titleScore > bestTitleScore || (titleScore == bestTitleScore && score > bestScore) {
                bestTitleScore = titleScore
                bestScore = score
                bestLyricsID = lyricsID
            }
        }

        guard bestScore >= 4,
              !bestLyricsID.isEmpty,
              let lyricsURL = URL(
                  string: "https://www.metal-archives.com/release/ajax-view-lyrics/id/\(bestLyricsID)"
              ),
              let lyricsData = await fetchSecondaryData(lyricsURL, providerName: lookupRequest.providerName)
        else {
            return nil
        }

        // The endpoint can return a complete error document as well as a lyric
        // fragment. Parse it as a page so head metadata cannot become lyrics.
        guard let page = LyricsHTMLPage.parse(
            htmlString(from: lyricsData), context: "Metal-Archives \(lyricsURL.absoluteString)"
        ) else { return nil }
        return candidate(
            from: page.visibleText(),
            sourceDescription: lookupRequest.providerName,
            lookupRequest: lookupRequest,
            track: track
        )
    }

    private func geniusCandidate(
        from data: Data,
        responseURL: URL,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) async -> OnlineLyricsCandidate? {
        if responseURL.host == "api.genius.com" {
            if let lyricsURL = geniusLyricsURLFromAPIData(data, track: track) {
                return await geniusLyricsPageCandidate(
                    lyricsURL,
                    lookupRequest: lookupRequest,
                    track: track
                )
            }

            return await geniusWebsiteSearchFallback(
                lookupRequest: lookupRequest,
                track: track,
                reason: "Genius API returned no matching song URLs"
            )
        }

        if responseURL.path.hasPrefix("/search") {
            if let lyricsURL = geniusLyricsURLFromSearchData(data, track: track) {
                return await geniusLyricsPageCandidate(
                    lyricsURL,
                    lookupRequest: lookupRequest,
                    track: track
                )
            }

            return await geniusWebsiteSearchFallback(
                lookupRequest: lookupRequest,
                track: track,
                reason: "Genius website search returned no matching lyrics URL"
            )
        }

        return await geniusLyricsPageCandidate(
            responseURL,
            lookupRequest: lookupRequest,
            track: track
        )
    }

    private func geniusWebsiteSearchFallback(
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack,
        reason: String
    ) async -> OnlineLyricsCandidate? {
        DebugLog.log("Lyrics falling back to Genius website search: \(reason)")
        for query in geniusSearchQueries(for: track) {
            guard let searchURL = geniusWebsiteSearchURL(for: query) else {
                continue
            }

            DebugLog.log("Lyrics Genius fallback query='\(query)' url=\(searchURL.absoluteString)")
            guard let searchData = await fetchSecondaryData(searchURL, providerName: lookupRequest.providerName) else {
                continue
            }

            guard let lyricsURL = geniusLyricsURLFromSearchData(searchData, track: track) else {
                DebugLog.log("Lyrics Genius fallback query='\(query)' had no matching lyrics URL")
                continue
            }

            if let candidate = await geniusLyricsPageCandidate(
                lyricsURL,
                lookupRequest: lookupRequest,
                track: track
            ) {
                return candidate
            }
        }

        return nil
    }

    private func geniusLyricsPageCandidate(
        _ lyricsURL: URL,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) async -> OnlineLyricsCandidate? {
        guard let pageData = await fetchSecondaryData(lyricsURL, providerName: lookupRequest.providerName) else {
            return nil
        }

        // The URL was chosen from its slug. When the page states its own title,
        // that statement has to name the track as well.
        if let page = LyricsHTMLPage.parse(
            htmlString(from: pageData), context: "Genius \(lyricsURL.absoluteString)"
        ), !page.metadataTitles.isEmpty, !htmlLyricsPageMatches(
            page: page, pageURL: lyricsURL, track: track, providerName: lookupRequest.providerName,
            includesURLPath: false
        ) {
            return nil
        }

        let lyricsString = geniusLyricsString(from: pageData)
        guard !lyricsString.isEmpty else {
            DebugLog.log("Lyrics Genius page had no lyric container url=\(lyricsURL.absoluteString)")
            return nil
        }

        return candidate(
            from: lyricsString,
            sourceDescription: lookupRequest.providerName,
            lookupRequest: lookupRequest,
            track: track
        )
    }

    private func simpleHTMLCandidate(
        page: LyricsHTMLPage,
        responseURL: URL,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) -> OnlineLyricsCandidate? {
        // A DarkLyrics page is a whole album: its URL and title name the album,
        // and the song is found by its section heading below.
        let pageSubject = lookupRequest.sourceName == "darklyrics" ? track.album?.nonEmpty : nil
        guard htmlLyricsPageMatches(
            page: page,
            pageURL: responseURL,
            track: track,
            providerName: lookupRequest.providerName,
            expectedTitle: pageSubject
        ) else {
            return nil
        }

        let lyricsString: String
        switch lookupRequest.sourceName {
        case "azlyrics":
            lyricsString = page.visibleText(afterCommentContaining: "Usage of azlyrics.com content by any third-party lyrics provider is prohibited") ?? ""
        case "songlyrics":
            let text = page.visibleText(in: "#songLyricsDiv") ?? ""
            lyricsString = text.localizedCaseInsensitiveContains("We do not have the lyrics") ? "" : text
        case "lyricsify":
            lyricsString = page.visibleText(in: "div[id^=lyrics_][id$=_details]") ?? ""
        case "letras":
            lyricsString = page.visibleText(in: "div.lyric-original") ?? ""
        case "darklyrics":
            lyricsString = darkLyricsString(in: page, track: track)
        default:
            lyricsString = page.visibleText()
        }

        // Malformed markup can leave a serialized application payload as a text
        // node. It is visible to the DOM but is not a plain lyric document.
        guard jsonObject(from: Data(lyricsString.utf8)) == nil else {
            DebugLog.log("Lyrics rejected serialized JSON in an HTML text fallback")
            return nil
        }
        return candidate(
            from: lyricsString,
            sourceDescription: lookupRequest.providerName,
            lookupRequest: lookupRequest,
            track: track
        )
    }

    private func genericCandidate(
        from data: Data,
        lookupRequest: OnlineLyricsRequest,
        track: AudioTrack
    ) -> OnlineLyricsCandidate? {
        if let json = jsonObject(from: data),
           let lyricsString = bestLyricsString(from: collectLikelyLyricsStrings(from: json)) {
            return candidate(
                from: lyricsString,
                sourceDescription: lookupRequest.providerName,
                lookupRequest: lookupRequest,
                track: track,
                match: .unverified
            )
        }

        guard let page = LyricsHTMLPage.parse(
            htmlString(from: data), context: "\(lookupRequest.providerName) \(lookupRequest.url.absoluteString)"
        ) else { return nil }
        return candidate(
            from: page.visibleText(),
            sourceDescription: lookupRequest.providerName,
            lookupRequest: lookupRequest,
            track: track,
            match: .unverified
        )
    }

    private func candidate(
        from rawLyrics: String,
        sourceDescription: String,
        lookupRequest: OnlineLyricsRequest,
        providerName: String? = nil,
        track: AudioTrack,
        match: CandidateMatch = .validatedPage
    ) -> OnlineLyricsCandidate? {
        var placeholderLineCount = 0
        var untouchedContentLineCount = 0
        var realLineCount = 0
        let lines = normalizedLyricsLines(rawLyrics).map { line in
            let parts = LyricsParser.lyricLineParts(line)
            let result = LyricsParser.removingPlaceholderAnnotations(from: parts.content)
            if result.removed || LyricsParser.lyricContentLineLooksLikePlaceholder(parts.content) {
                placeholderLineCount += 1
            }
            if result.removed {
                // Removing a marker can expose a leading tag. Only edited lines
                // need their surviving content parsed again for the final count.
                let content = LyricsParser.lyricContentLine(result.text)
                if !content.isEmpty && !LyricsParser.lyricContentLineLooksLikeNonLyric(content) {
                    realLineCount += 1
                }
            } else if !parts.content.isEmpty && !LyricsParser.lyricContentLineLooksLikeNonLyric(parts.content) {
                untouchedContentLineCount += 1
                realLineCount += 1
            }
            return parts.prefix + result.text
        }
        // Apply one content rule to every online provider. Retained text from a
        // marker-bearing line cannot establish content, even beside a timestamp.
        if placeholderLineCount > 0 {
            guard untouchedContentLineCount >= 4, untouchedContentLineCount > placeholderLineCount else {
                DebugLog.log(
                    "Lyrics \(lookupRequest.providerName) placeholder response lacks enough remaining content; " +
                    "untouchedContentLines=\(untouchedContentLineCount), placeholderLines=\(placeholderLineCount)"
                )
                return nil
            }
        }
        let trimmedLyrics = cleanupLyricsLines(lines)
        guard LyricsParser.looksUsable(trimmedLyrics, contentLineCount: realLineCount) else {
            DebugLog.log("Lyrics rejected \(lookupRequest.providerName) result as unusable lyric text")
            return nil
        }

        guard let document = LyricsParser.parse(
            trimmedLyrics,
            sourceURL: nil,
            sourceDescription: sourceDescription
        ) else {
            DebugLog.log("Lyrics parser returned empty document for \(lookupRequest.providerName)")
            return nil
        }

        if document.isSynchronized, realLineCount == 0 {
            DebugLog.log("Lyrics rejected \(lookupRequest.providerName) synchronized result because it has no lyric content lines")
            return nil
        }

        let providerName = providerName ?? lookupRequest.providerName
        let result = onlineResultScore(
            document: document,
            realLineCount: realLineCount,
            sourceName: lookupRequest.sourceName,
            providerName: providerName,
            track: track
        )
        return OnlineLyricsCandidate(
            sourceName: lookupRequest.sourceName,
            providerName: providerName,
            rawLyrics: trimmedLyrics,
            document: document,
            score: result.score,
            match: match,
            // Exact title and artist, synchronized, and the last timestamp
            // lands where this recording ends: no other provider can do better.
            isHighConfidence: document.isSynchronized && realLineCount >= 4 &&
                match.isExactIdentity && result.durationScore >= 500
        )
    }

    private func onlineResultScore(
        document: LyricsDocument,
        realLineCount: Int,
        sourceName: String,
        providerName: String,
        track: AudioTrack
    ) -> (score: Int, durationScore: Int) {
        var score = 0
        let timedBonus: Int
        if document.isSynchronized, realLineCount >= 2 {
            timedBonus = 100_000
            score += timedBonus
        } else if document.isSynchronized {
            timedBonus = 0
            DebugLog.log(
                "Lyrics scoring thin synchronized result from \(providerName) without timed bonus; " +
                "contentLines=\(realLineCount)"
            )
        } else {
            timedBonus = 0
        }

        let lineScore = lyricLineScore(realLineCount)
        let characterScore = min(document.plainText.trimmingCharacters(in: .whitespacesAndNewlines).count, 6000) / 3
        let priorityScore = providerPriority(
            sourceName: sourceName,
            providerName: providerName,
            isSynchronized: document.isSynchronized
        )
        let durationScore = lyricDurationMatchScore(document: document, track: track, providerName: providerName)
        let densityScore = lyricDensityScore(
            document: document,
            realLineCount: realLineCount,
            track: track,
            providerName: providerName
        )
        score += lineScore
        score += characterScore
        score += priorityScore
        score += durationScore
        score += densityScore
        DebugLog.log(
            "Lyrics score source='\(sourceName)' provider='\(providerName)' timedBonus=\(timedBonus) " +
            "contentLines=\(realLineCount) lineScore=\(lineScore) characterScore=\(characterScore) " +
            "providerPriority=\(priorityScore) durationScore=\(durationScore) densityScore=\(densityScore) " +
            "total=\(score)"
        )
        return (score, durationScore)
    }

    private func lyricLineScore(_ lineCount: Int) -> Int {
        let primaryLines = min(lineCount, 24) * 100
        let extraLines = min(max(lineCount - 24, 0), 60) * 20
        return primaryLines + extraLines
    }

    private func providerPriority(sourceName: String, providerName: String, isSynchronized: Bool) -> Int {
        switch sourceName {
        case "lrclib-exact":
            return isSynchronized ? 6_000 : 1_400
        case "lrclib-search":
            return isSynchronized ? 4_800 : 1_200
        case "netease", "qqmusic", "lrcapi", "kuwo", "kugou":
            return 800
        case "musixmatch":
            return 760
        case "shazam":
            return 720
        case "genius":
            return 700
        case "letrasboom":
            return 660
        case "azlyrics", "songlyrics", "lyricsify", "letras", "lyricfind":
            return 620
        case "bandcamp":
            return 580
        case "darklyrics", "metalarchives":
            return 560
        default:
            return providerName.lowercased().contains("lrclib") ? 850 : 500
        }
    }

    private func lyricDurationMatchScore(
        document: LyricsDocument,
        track: AudioTrack,
        providerName: String
    ) -> Int {
        guard document.isSynchronized,
              let playableDuration = playableDuration(for: track),
              playableDuration > 0,
              let lastLyricTime = lastLyricTimestamp(in: document),
              lastLyricTime > 0
        else {
            return 0
        }

        let delta = abs(lastLyricTime - playableDuration)
        let coverage = lastLyricTime / playableDuration
        let closeTolerance = max(8.0, min(20.0, playableDuration * 0.08))
        let outroTolerance = max(18.0, min(35.0, playableDuration * 0.12))
        let score: Int

        if lastLyricTime > playableDuration {
            let overshoot = lastLyricTime - playableDuration
            if overshoot <= closeTolerance {
                score = 900
            } else if overshoot <= closeTolerance * 2 {
                score = -4_000
            } else {
                score = -12_000
            }
        } else if delta <= closeTolerance {
            score = 1_200
        } else if delta <= outroTolerance {
            score = 500
        } else if coverage >= 0.80 {
            score = 0
        } else if coverage >= 0.65 {
            score = -4_000
        } else {
            score = -12_000
        }

        DebugLog.log(
            "Lyrics duration match provider='\(providerName)' playable=\(display(playableDuration)) " +
            "lastLyric=\(display(lastLyricTime)) delta=\(display(delta)) coverage=\(display(coverage)) " +
            "score=\(score)"
        )
        return score
    }

    private func lyricDensityScore(
        document: LyricsDocument,
        realLineCount: Int,
        track: AudioTrack,
        providerName: String
    ) -> Int {
        guard document.isSynchronized,
              realLineCount >= 40,
              let playableDuration = playableDuration(for: track),
              playableDuration > 0
        else {
            return 0
        }

        let linesPerMinute = Double(realLineCount) / (playableDuration / 60.0)
        let score: Int
        if linesPerMinute >= 18.0 {
            score = -8_000
        } else if linesPerMinute >= 12.0 {
            score = -4_000
        } else {
            score = 0
        }

        if score != 0 {
            DebugLog.log(
                "Lyrics density penalty provider='\(providerName)' contentLines=\(realLineCount) " +
                "playable=\(display(playableDuration)) linesPerMinute=\(display(linesPerMinute)) " +
                "score=\(score)"
            )
        }

        return score
    }

    private func playableDuration(for track: AudioTrack) -> TimeInterval? {
        if let cueStart = track.cueStart,
           let cueEnd = track.cueEnd,
           cueEnd > cueStart {
            return cueEnd - cueStart
        }

        guard let duration = track.duration, duration > 0 else {
            return nil
        }

        return duration
    }

    private func lastLyricTimestamp(in document: LyricsDocument) -> TimeInterval? {
        document.lines.compactMap(\.time).max()
    }

    private func display(_ value: TimeInterval) -> String {
        String(format: "%.2f", value)
    }

    private func lrclibMatchScore(_ result: LRCLIBLyrics, track: AudioTrack) -> Int {
        let metadata = CandidateMetadata(
            title: result.trackName ?? "",
            artist: result.artistName ?? "",
            album: result.albumName ?? "",
            duration: result.duration
        )
        var score = candidateMatchScore(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            duration: metadata.duration,
            track: track
        ) + candidateContextMatchScore(metadata, track: track) * 2
        if result.syncedLyrics?.nonEmpty != nil {
            score += 2
        }
        return score
    }

    private func bestDictionaryCandidate(
        from candidates: [[String: Any]],
        track: AudioTrack,
        providerName: String,
        metadataBuilder: ([String: Any]) -> CandidateMetadata
    ) -> (value: [String: Any], match: CandidateMatch)? {
        bestMetadataCandidate(
            from: candidates, track: track, providerName: providerName, metadataBuilder: metadataBuilder
        ).map { ($0.value, $0.match) }
    }

    private func bestMetadataCandidate<Value>(
        from candidates: [Value],
        track: AudioTrack,
        providerName: String,
        metadataBuilder: (Value) -> CandidateMetadata,
        candidatesArePrevalidated: Bool = false
    ) -> (value: Value, metadata: CandidateMetadata, match: CandidateMatch)? {
        var bestCandidate: (value: Value, metadata: CandidateMetadata, match: CandidateMatch)?
        var bestScore = 0
        var consideredCandidateCount = 0

        for candidate in candidates {
            let metadata = metadataBuilder(candidate)
            let contextScore = candidateContextMatchScore(metadata, track: track)
            let match: CandidateMatch
            if candidatesArePrevalidated {
                match = .exactIdentity
            } else if let acceptedMatch = candidateMatch(
                metadata, titleScore: titleMatchScore(candidateTitle: metadata.title, track: track), track: track
            ) {
                match = acceptedMatch
            } else {
                DebugLog.log(
                    "Lyrics \(providerName) rejected candidate because metadata did not match current track: " +
                    "title='\(metadata.title)' artist='\(metadata.artist)' album='\(metadata.album)' " +
                    "trackTitle='\(track.title)' contextScore=\(contextScore)"
                )
                continue
            }

            consideredCandidateCount += 1
            let score = candidateMatchScore(
                title: metadata.title,
                artist: metadata.artist,
                album: metadata.album,
                duration: metadata.duration,
                track: track
            ) + contextScore * 2
            DebugLog.log(
                "Lyrics \(providerName) candidate score=\(score) strongTitle=\(match.isStrongTitle) " +
                "title='\(metadata.title)' artist='\(metadata.artist)' album='\(metadata.album)'"
            )
            if bestCandidate == nil || score > bestScore {
                bestCandidate = (candidate, metadata, match)
                bestScore = score
            }
        }

        guard consideredCandidateCount > 0 else {
            DebugLog.log("Lyrics \(providerName) rejected candidates because no result metadata matched '\(track.title)'")
            return nil
        }

        // A dedicated identity check already establishes an acceptable result.
        // Sparse local tags can have a low ranking score even with that proof.
        guard candidatesArePrevalidated || bestScore >= 4 else {
            DebugLog.log("Lyrics \(providerName) rejected candidates because best score \(bestScore) < 4")
            return nil
        }

        return bestCandidate
    }

    private func candidateMatchScore(
        title candidateTitle: String,
        artist candidateArtist: String,
        album candidateAlbum: String,
        duration candidateDuration: TimeInterval?,
        track: AudioTrack
    ) -> Int {
        var score = 0
        score += titleMatchScore(candidateTitle: candidateTitle, track: track)

        let title = normalizedSearchText(track.title)
        let resultTitle = normalizedSearchText(candidateTitle)
        if !title.isEmpty && title == resultTitle {
            score += 8
        } else if searchTextVariants(for: track.title).contains(where: { variant in
            searchTextVariants(for: candidateTitle).contains(variant)
        }) {
            score += 8
        }

        if searchTextsMatch(track.artist ?? "", candidateArtist) {
            score += 4
        }

        if searchTextsMatch(track.album ?? "", candidateAlbum) {
            score += 2
        }

        score += textMatchScore(
            "\(candidateTitle) \(candidateArtist) \(candidateAlbum)",
            track: track
        )

        if let candidateDuration, let duration = playableDuration(for: track) ?? track.duration {
            let delta = abs(candidateDuration - duration)
            if delta <= 2 {
                score += 3
            } else if delta <= 5 {
                score += 1
            }
        }

        return score
    }

    /// Decides whether search-result metadata names the playing track, and how
    /// firmly. Returns nil for a different song.
    ///
    /// - A title that is equal, or contained as a whole phrase, is strong.
    ///   Only then may the artist be unknown; a *different* artist also needs
    ///   the album or the length to agree (covers, romanized artist names).
    /// - A title that merely shares words is weak. It needs the artist and
    ///   every significant word of a multi-word title.
    /// - No title evidence at all (another script) is accepted only for the
    ///   same position on the same release, never for an album sibling.
    private func candidateMatch(
        _ metadata: CandidateMetadata,
        titleScore: Int,
        track: AudioTrack
    ) -> CandidateMatch? {
        let trackArtist = track.artist?.nonEmpty ?? ""
        let artistIsKnown = !trackArtist.isEmpty && !metadata.artist.isEmpty
        let artistMatches = artistIsKnown && artistCreditsOverlap(trackArtist, metadata.artist)
        let albumMatches = searchTextsMatch(track.album ?? "", metadata.album)
        let durationDelta: TimeInterval?
        if let candidateDuration = metadata.duration, let duration = playableDuration(for: track) ?? track.duration {
            durationDelta = abs(candidateDuration - duration)
        } else {
            durationDelta = nil
        }

        guard titleScore > 0 else {
            guard artistMatches, albumMatches,
                  let trackNumber = track.trackNumber, trackNumber == metadata.trackNumber,
                  durationDelta.map({ $0 <= 5 }) ?? true
            else {
                return nil
            }

            return .unverified
        }

        let titleIsStrong = titleScore >= Self.strongTitleScore
        if artistIsKnown, !artistMatches {
            guard titleIsStrong, albumMatches || (durationDelta.map { $0 <= 2 } ?? false) else {
                return nil
            }

            return .validatedPage
        }

        guard titleIsStrong else {
            guard artistMatches, titleWordsAreFullyCovered(by: metadata.title, track: track) else {
                return nil
            }

            return .unverified
        }

        return CandidateMatch(isStrongTitle: true, isExactIdentity: titleScore >= 12 && artistMatches)
    }

    /// Test seam for `candidateMatch`: nil when the metadata names another song.
    func metadataMatch(
        title: String, artist: String, album: String = "", duration: TimeInterval? = nil,
        trackNumber: Int? = nil, track: AudioTrack
    ) -> (isStrongTitle: Bool, isExactIdentity: Bool)? {
        let metadata = CandidateMetadata(
            title: title, artist: artist, album: album, duration: duration, trackNumber: trackNumber
        )
        return candidateMatch(
            metadata, titleScore: titleMatchScore(candidateTitle: title, track: track), track: track
        ).map { ($0.isStrongTitle, $0.isExactIdentity) }
    }

    /// Equal or phrase-contained titles score at least this; shared words stay below it.
    private static let strongTitleScore = 7
    private static let maximumSharedWordTitleScore = 6

    private func titleWordsAreFullyCovered(by candidateTitle: String, track: AudioTrack) -> Bool {
        let titleWords = Set(significantTokens(from: simplifiedTitleForSearch(track.title)))
        guard titleWords.count >= 2 else {
            return false
        }

        let candidateWords = Set(searchTextVariants(for: candidateTitle).flatMap {
            $0.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        })
        return titleWords.isSubset(of: candidateWords)
    }

    /// True when the two credits share a performer: equal credits, a shared
    /// name once each credit is split ("A / B", "A feat. B"), or one credit
    /// contained in the other as a whole phrase ("周杰伦" in "周杰伦 Jay Chou").
    private func artistCreditsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        if searchTextsMatch(lhs, rhs) {
            return true
        }

        let lhsNames = artistNameKeys(lhs)
        let rhsNames = artistNameKeys(rhs)
        if !lhsNames.isDisjoint(with: rhsNames) {
            return true
        }

        return lhsNames.contains { lhsName in
            rhsNames.contains { phrase(lhsName, isContainedIn: $0) || phrase($0, isContainedIn: lhsName) }
        }
    }

    private func artistNameKeys(_ credit: String) -> Set<String> {
        let delimited = credit
            .replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: "，", with: ",")
        let parts = featuredCredit(in: delimited)
        let names = [delimited] + artistNames(in: parts.main) + parts.guests.flatMap(artistNames)
        return Set(names.flatMap { aliasedTexts(for: $0).map(normalizedSearchText) }.filter { !$0.isEmpty })
    }

    /// Whole-token containment of normalized text. Very short phrases are too
    /// ambiguous to count ("war" in "war pigs"), except in scripts written
    /// without spaces, where two characters are already a word.
    private func phrase(_ phrase: String, isContainedIn text: String) -> Bool {
        guard !phrase.isEmpty, phrase != text else {
            return false
        }

        let compactCount = phrase.filter { $0 != " " }.count
        let isASCII = phrase.unicodeScalars.allSatisfy(\.isASCII)
        guard compactCount >= (isASCII ? 4 : 2) else {
            return false
        }

        return " \(text) ".contains(" \(phrase) ")
    }

    private func candidateContextMatchScore(_ metadata: CandidateMetadata, track: AudioTrack) -> Int {
        var score = 0
        if searchTextsMatch(track.artist ?? "", metadata.artist) {
            score += 4
        }

        if searchTextsMatch(track.album ?? "", metadata.album) {
            score += 4
        }

        if let trackNumber = track.trackNumber,
           let candidateTrackNumber = metadata.trackNumber,
           trackNumber == candidateTrackNumber {
            score += 5
        }

        if let candidateDuration = metadata.duration,
           let duration = playableDuration(for: track) ?? track.duration {
            let delta = abs(candidateDuration - duration)
            if delta <= 2 {
                score += 3
            } else if delta <= 5 {
                score += 1
            }
        }

        return score
    }

    /// 12: equal titles. 7-8: equal once the candidate's parenthetical labels
    /// are dropped, equal ignoring spacing, or one title contained in the
    /// other as a whole phrase. 1-6: shared words only. 0: nothing in common.
    func titleMatchScore(candidateTitle: String, track: AudioTrack) -> Int {
        let resultTitleVariants = searchTextVariants(for: candidateTitle)
        guard !resultTitleVariants.isEmpty else {
            return 0
        }

        let trackTitles = LyricsTextNormalization.uniqueNonEmptyStrings([
            track.title,
            simplifiedTitleForSearch(track.title)
        ])

        for trackTitle in trackTitles {
            for normalizedTitle in searchTextVariants(for: trackTitle) where resultTitleVariants.contains(normalizedTitle) {
                return 12
            }
        }

        let simplifiedResultVariants = Set(searchTextVariants(for: simplifiedTitleForSearch(candidateTitle)))
        for trackTitle in trackTitles {
            let titleVariants = searchTextVariants(for: trackTitle)
            if titleVariants.contains(where: simplifiedResultVariants.contains) {
                return 8
            }

            for normalizedTitle in titleVariants {
                let compactTitle = normalizedTitle.components(separatedBy: .whitespaces).joined()
                for resultTitle in resultTitleVariants {
                    let compactResultTitle = resultTitle.components(separatedBy: .whitespaces).joined()
                    if compactTitle == compactResultTitle ||
                        phrase(normalizedTitle, isContainedIn: resultTitle) ||
                        phrase(resultTitle, isContainedIn: normalizedTitle) {
                        return normalizedTitle == normalizedSearchText(trackTitle) ? 8 : 7
                    }
                }
            }
        }

        var score = 0
        let titleTokens = Set(trackTitles.flatMap { significantTokens(from: $0) })
        let resultTitleTokens = Set(resultTitleVariants.flatMap {
            $0.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        })
        for token in titleTokens where resultTitleTokens.contains(token) {
            score += 3
        }

        return min(score, Self.maximumSharedWordTitleScore)
    }

    private func textMatchScore(_ text: String, track: AudioTrack) -> Int {
        let normalizedText = normalizedSearchText(text)
        let textTokens = Set(normalizedText.components(separatedBy: .whitespaces).filter { !$0.isEmpty })
        let compactText = normalizedText.components(separatedBy: .whitespaces).joined()
        let titleTokens = significantTokens(from: track.title)
        let artistTokens = significantTokens(from: track.artist ?? "")

        var score = 0
        for token in titleTokens where textTokens.contains(token) || (token.count >= 5 && compactText.contains(token)) {
            score += 2
        }
        for token in artistTokens where textTokens.contains(token) {
            score += 1
        }
        return score
    }

    private func significantTokens(from string: String) -> [String] {
        let ignoredTokens: Set<String> = ["a", "an", "and", "de", "la", "le", "the", "to", "lyrics"]
        return normalizedSearchText(string)
            .components(separatedBy: .whitespaces)
            .filter { $0.count >= 3 && !ignoredTokens.contains($0) }
    }

    private func normalizedSearchText(_ text: String) -> String {
        LyricsTextNormalization.key(text)
    }

    private func aliasedTexts(for text: String) -> [String] {
        LyricsTextNormalization.uniqueNonEmptyStrings([text] + semanticSearchAliases(for: text))
    }

    private func searchTextVariants(for text: String) -> [String] {
        LyricsTextNormalization.uniqueNonEmptyStrings(aliasedTexts(for: text).map(normalizedSearchText))
    }

    private func searchTextsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhsVariants = searchTextVariants(for: lhs)
        guard !lhsVariants.isEmpty else {
            return false
        }

        let rhsVariants = Set(searchTextVariants(for: rhs))
        return lhsVariants.contains { rhsVariants.contains($0) }
    }

    private func semanticSearchAliases(for text: String) -> [String] {
        semanticSearchAliasMap[normalizedSearchText(text)] ?? []
    }

    private func simplifiedTitleForSearch(_ title: String) -> String {
        title
            .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? title
    }

    private func kuwoLyricsString(from data: Data) -> String {
        guard let json = jsonObject(from: data) as? [String: Any],
              let dataDictionary = json["data"] as? [String: Any] else {
            return ""
        }

        let lines = dictionaries(from: dataDictionary["lrclist"])
        return lines.compactMap { line -> String? in
            let lyricText = stringValue(line["lineLyric"])
            guard !lyricText.isEmpty else {
                return nil
            }

            let timeSeconds = max(numberValue(line["time"]) ?? 0, 0)
            let minutes = Int(timeSeconds / 60)
            let seconds = timeSeconds - Double(minutes * 60)
            return String(format: "[%02d:%05.2f]", minutes, seconds) + lyricText
        }
        .joined(separator: "\n")
    }

    private func kuGouLyricsString(from data: Data) -> String {
        guard let json = jsonObject(from: data) as? [String: Any] else {
            let plainText = String(data: data, encoding: .utf8) ?? ""
            return LyricsParser.looksUsable(plainText) ? plainText : ""
        }

        let encodedLyrics = stringValue(json["content"])
        if let decodedLyrics = base64DecodedString(encodedLyrics).nonEmpty {
            return decodedLyrics
        }

        return likelyLyricsString(in: json) ?? ""
    }

    private func likelyLyricsString(in dictionary: [String: Any]) -> String? {
        bestLyricsString(from: collectLikelyLyricsStrings(from: dictionary))
    }

    private func collectLikelyLyricsStrings(from value: Any, currentKey: String = "") -> [String] {
        if let string = value as? String {
            let lowerKey = currentKey.lowercased()
            if isLikelyLyricsKey(lowerKey) || stringContainsTimestamp(string) {
                return LyricsParser.looksUsable(string) ? [string] : []
            }
            return []
        }

        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { key, value in
                collectLikelyLyricsStrings(from: value, currentKey: key)
            }
        }

        if let array = value as? [Any] {
            return array.flatMap { collectLikelyLyricsStrings(from: $0, currentKey: currentKey) }
        }

        return []
    }

    private func isLikelyLyricsKey(_ lowerKey: String) -> Bool {
        [
            "lyrics",
            "lyric",
            "lrc",
            "syncedlyrics",
            "plainlyrics",
            "content",
            "subtitle_body",
            "lyrics_body",
            "lineLyric"
        ]
        .contains { lowerKey.replacingOccurrences(of: "_", with: "").contains($0.lowercased()) }
    }

    private func bestLyricsString(from strings: [String]) -> String? {
        strings
            .filter { LyricsParser.looksUsable($0) }
            .sorted {
                let lhsScore = (stringContainsTimestamp($0) ? 10_000 : 0) + LyricsParser.contentLineCount($0) * 100 + $0.count
                let rhsScore = (stringContainsTimestamp($1) ? 10_000 : 0) + LyricsParser.contentLineCount($1) * 100 + $1.count
                return lhsScore > rhsScore
            }
            .first
    }

    private func stringContainsTimestamp(_ string: String) -> Bool {
        firstRegexCapture(
            in: string,
            pattern: #"\[(\d{1,3}):\d{2}(?:[\.:]\d{1,3})?(?:-\d+)?\]"#
        )
        .isEmpty == false
    }

    private func cleanupLyricsText(_ text: String) -> String {
        cleanupLyricsLines(normalizedLyricsLines(text))
    }

    private func normalizedLyricsLines(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n")
    }

    private func cleanupLyricsLines(_ lines: [String]) -> String {
        var cleanedLines: [String] = []
        var previousWasBlank = false
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if !previousWasBlank, !cleanedLines.isEmpty {
                    cleanedLines.append("")
                }
                previousWasBlank = true
            } else {
                cleanedLines.append(line)
                previousWasBlank = false
            }
        }

        while cleanedLines.last == "" {
            cleanedLines.removeLast()
        }

        return cleanedLines.joined(separator: "\n")
    }

    private func jsonObject(from data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    private func dictionaries(from value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    private func stringValue(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    private func numberValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private func trackNumberValue(_ dictionary: [String: Any]) -> Int? {
        [
            "trackNumber",
            "trackNum",
            "track_number",
            "track_no",
            "trackNo",
            "position",
            "no"
        ]
        .lazy
        .compactMap { key -> Int? in
            guard let value = numberValue(dictionary[key]) else {
                return nil
            }

            return Int(value)
        }
        .first { (1...199).contains($0) }
    }

    private func base64DecodedString(_ encodedString: String) -> String {
        guard !encodedString.isEmpty,
              let data = Data(base64Encoded: encodedString, options: [.ignoreUnknownCharacters])
        else {
            return ""
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    private func htmlString(from data: Data) -> String {
        if let string = String(data: data, encoding: .utf8) {
            return string
        }

        // Not UTF-8 and no usable HTTP charset: honour the page's own
        // declaration (<meta charset=gbk>, content="text/html; charset=shift_jis").
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        if let charset = firstRegexCapture(in: head, pattern: #"charset\s*=\s*["']?\s*([A-Za-z0-9_\-]+)"#).nonEmpty,
           let encoding = Self.stringEncoding(forCharset: charset),
           let string = String(data: data, encoding: encoding) {
            return string
        }

        return String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    // General HTML providers retain their tolerant title/artist checks. Shazam's
    // unrelated fallback pages require the separate near-identity validator below.
    //
    // `expectedTitle` replaces the track title for pages whose subject is not
    // the song (an album page). `includesURLPath` is false when the URL was
    // itself selected by its text, so that only the page's own titles count.
    func htmlLyricsPageMatches(
        page: LyricsHTMLPage, pageURL: URL, track: AudioTrack, providerName: String,
        expectedTitle: String? = nil, includesURLPath: Bool = true
    ) -> Bool {
        let titleVariants = htmlValidationTitleVariants(for: expectedTitle ?? track.title)
        guard !titleVariants.isEmpty else {
            return true
        }

        var validationParts: [String] = []
        if includesURLPath, !pageURL.path.isEmpty {
            validationParts.append(pageURL.path)
        }

        validationParts += page.metadataTitles

        let validationText = validationParts.joined(separator: " ")
        guard !validationText.isEmpty else {
            return true
        }

        let normalizedText = normalizedSearchText(validationText)
        let textTokens = Set(normalizedText.components(separatedBy: .whitespaces).filter { !$0.isEmpty })
        let compactText = normalizedText.components(separatedBy: .whitespaces).joined()

        let matchedTitle = titleVariants.contains { titleVariant in
            htmlValidationTextContainsTitleVariant(
                titleVariant,
                normalizedText: normalizedText,
                textTokens: textTokens,
                compactText: compactText
            )
        }
        guard matchedTitle else {
            DebugLog.log(
                "Lyrics rejecting \(providerName) page because it does not match title='\(expectedTitle ?? track.title)' " +
                "url=\(pageURL.absoluteString)"
            )
            return false
        }

        let artistTokens = significantTokens(from: track.artist ?? "")
        guard !artistTokens.isEmpty else {
            return true
        }

        let matchedArtist = artistTokens.contains { token in
            textTokens.contains(token) || (token.count >= 5 && compactText.contains(token))
        }
        guard matchedArtist else {
            DebugLog.log(
                "Lyrics rejecting \(providerName) page because it does not match artist='\(track.artist ?? "")' " +
                "url=\(pageURL.absoluteString)"
            )
            return false
        }

        return true
    }

    private func htmlValidationTitleVariants(for title: String) -> [String] {
        LyricsTextNormalization.uniqueNonEmptyStrings(
            (searchTextVariants(for: title) + searchTextVariants(for: simplifiedTitleForSearch(title)))
                .filter { !$0.isEmpty }
        )
    }

    private func htmlValidationTextContainsTitleVariant(
        _ titleVariant: String,
        normalizedText: String,
        textTokens: Set<String>,
        compactText: String
    ) -> Bool {
        let variantTokens = titleVariant
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        let compactVariant = variantTokens.joined()
        guard !compactVariant.isEmpty else {
            return false
        }

        if variantTokens.count >= 2 {
            return normalizedText.contains(titleVariant) || compactText.contains(compactVariant)
        }

        // A one-word title counts when it stands as a word of its own, however
        // short ("Halo", "Stay", "晴天"). Only the spacing-insensitive substring
        // search needs a length floor, or "stay" would match "yesterstay...".
        return textTokens.contains(titleVariant) ||
            (compactVariant.count >= 5 && compactText.contains(compactVariant))
    }

    private func fragmentText(fromHTML html: String, context: @autoclosure () -> String) -> String {
        (LyricsHTMLPage.fragmentText(html, context: context()) ?? "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func bandcampLyricsString(from data: Data, pageURL: URL) -> String {
        guard let page = LyricsHTMLPage.parse(
            htmlString(from: data), context: "Bandcamp \(pageURL.absoluteString)"
        ) else { return "" }
        return page.visibleText(in: "div.lyricsText") ?? ""
    }

    private func darkLyricsString(in page: LyricsHTMLPage, track: AudioTrack) -> String {
        // Headings read "3. War". Compare the title itself, so "War" cannot
        // select an earlier "1. Warlord".
        let titleVariants = Set(htmlValidationTitleVariants(for: track.title))
        return page.visibleSections(in: "div.lyrics", headingTag: "h3").first { section in
            let heading = section.heading.replacingOccurrences(
                of: #"^\s*\d+\s*[\.\)\-:]\s*"#, with: "", options: .regularExpression
            )
            return searchTextVariants(for: heading).contains(where: titleVariants.contains) ||
                titleVariants.contains(normalizedSearchText(simplifiedTitleForSearch(heading)))
        }?.text ?? ""
    }

    private func featuredCredit(in text: String) -> (main: String, guests: [String]) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = Self.featuredCreditExpression.matches(in: text, range: range)
        let guests = matches.compactMap { match in
            (Range(match.range(at: 1), in: text) ?? Range(match.range(at: 2), in: text)).map { String(text[$0]) }
        }
        let main = NSMutableString(string: text)
        for match in matches.reversed() { main.deleteCharacters(in: match.range) }
        return (main as String, guests)
    }

    private func creditedTitleKey(_ title: String) -> String {
        var words = normalizedSearchText(title).components(separatedBy: " ")
        if let marker = words.indices.first(where: {
            $0 > 0 && $0 < words.count - 1 && ["feat", "ft", "featuring"].contains(words[$0])
        }) { words[marker] = "feat" }
        return words.joined(separator: " ")
    }

    private func creditedTitleIdentities(_ title: String) -> Set<String> {
        Set(aliasedTexts(for: title).map(creditedTitleKey).filter { !$0.isEmpty })
    }

    private func titleIdentities(_ title: String, allowingUnlabeledEdition: Bool = false) -> TitleMatchIdentity {
        var variants = creditedTitleIdentities(title)
        var remasterVariants = Set<String>()
        for value in aliasedTexts(for: title) {
            let withoutCredit = featuredCredit(in: value).main
            variants.insert(normalizedSearchText(withoutCredit))
            let range = NSRange(withoutCredit.startIndex..<withoutCredit.endIndex, in: withoutCredit)
            // Remaster and edition labels do not remove recording distinctions:
            // Live, Clean, Demo, Acoustic, etc. remain part of both identities.
            let withoutRemaster = Self.titleRemasterExpression.stringByReplacingMatches(
                in: withoutCredit, range: range, withTemplate: ""
            )
            remasterVariants.insert(normalizedSearchText(withoutRemaster))
            if allowingUnlabeledEdition {
                let withoutLabels = Self.titleEditionExpression.stringByReplacingMatches(
                    in: withoutCredit, range: range, withTemplate: ""
                )
                variants.insert(normalizedSearchText(withoutLabels))
            }
        }
        variants.remove("")
        remasterVariants.remove("")
        return TitleMatchIdentity(variants: variants, remasterVariants: remasterVariants)
    }

    private func artistNames(in value: String) -> [String] {
        // Treat tag and page delimiters alike, without guessing from a name's
        // first word. Full-credit matching preserves punctuated band names;
        // requiring every primary prevents a component from matching the band.
        value.components(separatedBy: CharacterSet(charactersIn: "&;,"))
            .compactMap(\.nonEmpty).flatMap { name -> [String] in
                let parts = name.components(separatedBy: "/")
                guard parts.count > 1 else { return [name] }
                let explicitSeparator = name.contains(" /") || name.contains("/ ")
                // Preserve compact names such as AC/DC; spaced slashes explicitly
                // separate credits, and full names may also use a bare slash.
                guard explicitSeparator || parts.allSatisfy({ ($0.nonEmpty?.count ?? 0) > 3 }) else { return [name] }
                return parts.compactMap(\.nonEmpty)
            }
    }

    private func artistIdentity(for metadata: CandidateMetadata) -> ArtistMatchIdentity {
        func names(_ value: String) -> Set<String> {
            Set(aliasedTexts(for: value).map(normalizedSearchText).filter { !$0.isEmpty })
        }
        let artistCredit = featuredCredit(in: metadata.artist)
        // JSON-LD already separates performers. Keep each supplied name atomic,
        // including punctuation that could otherwise be mistaken for a delimiter.
        let primary = (metadata.structuredArtistNames ?? artistNames(in: artistCredit.main)).map(names)
        let guests = (artistCredit.guests + featuredCredit(in: metadata.title).guests)
            .flatMap(artistNames).map(names)
        // Match the complete credit before considering individual artists. This
        // accepts Simon and Garfunkel / Simon & Garfunkel without splitting "and"
        // inside names such as Florence and the Machine.
        let completePrimary = Set(aliasedTexts(for: artistCredit.main)
            .map { normalizedSearchText($0.replacingOccurrences(of: "&", with: " and ")) }.filter { !$0.isEmpty })
        return ArtistMatchIdentity(primary: primary, credits: primary + guests, completePrimary: completePrimary)
    }

    private func pageIdentity(for metadata: CandidateMetadata, allowingUnlabeledEdition: Bool = false) -> PageSongIdentity {
        PageSongIdentity(
            titles: titleIdentities(metadata.title, allowingUnlabeledEdition: allowingUnlabeledEdition),
            artists: artistIdentity(for: metadata)
        )
    }

    private func pageIdentityMatches(
        _ candidate: PageSongIdentity, expected: PageSongIdentity, allowingLeadOnlyCredit: Bool = false
    ) -> Bool {
        candidate.titles.matches(expected.titles) &&
            artistIdentityMatches(candidate.artists, expected: expected.artists, allowingLeadOnlyCredit: allowingLeadOnlyCredit)
    }

    private func artistIdentityMatches(
        _ candidate: ArtistMatchIdentity, expected: ArtistMatchIdentity, allowingLeadOnlyCredit: Bool = false
    ) -> Bool {
        if !candidate.completePrimary.isDisjoint(with: expected.completePrimary) { return true }
        guard !expected.primary.isEmpty, expected.primary.allSatisfy({ name in
            candidate.primary.contains { !name.isDisjoint(with: $0) }
        }) else {
            return false
        }
        // During search, an incomplete single-artist tag may expand to an ordered
        // iTunes credit led by that artist. Page validation then requires the
        // complete corroborated credit, without treating array order as lead order.
        if allowingLeadOnlyCredit, expected.primary.count == 1,
           let lead = candidate.primary.first, !lead.isDisjoint(with: expected.primary[0]) {
            return true
        }
        return candidate.primary.allSatisfy { name in
            expected.credits.contains { !name.isDisjoint(with: $0) }
        }
    }

    private func shazamSongID(in url: URL) -> String? {
        guard let host = url.host?.lowercased(), host == "shazam.com" || host.hasSuffix(".shazam.com") else { return nil }
        var components = url.path.split(separator: "/").map(String.init)
        if let first = components.first, Self.shazamLocaleExpression.firstMatch(
            in: first, range: NSRange(first.startIndex..<first.endIndex, in: first)
        ) != nil {
            components.removeFirst()
        }
        guard components.count >= 2, ["song", "track"].contains(components[0]),
              !components[1].isEmpty, components[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return components[1]
    }

    private func validatedShazamRecordings(
        page: LyricsHTMLPage,
        pageURL: URL,
        requestedTrackID: String,
        expected: PageSongIdentity
    ) -> [SongPageMetadata]? {
        guard !expected.titles.variants.isEmpty, !expected.artists.primary.isEmpty else { return nil }
        let declaredIDs = page.identityURLReferences
            .compactMap { URL(string: $0, relativeTo: pageURL)?.absoluteURL }
            .compactMap(shazamSongID)
        let returnedIDs = declaredIDs + [shazamSongID(in: pageURL)].compactMap { $0 }
        // An unchanged response URL only echoes our request. Require the page to
        // declare the ID independently, and reject any recognized contradiction.
        guard declaredIDs.contains(requestedTrackID), returnedIDs.allSatisfy({ $0 == requestedTrackID }) else {
            DebugLog.log("Lyrics Shazam rejected missing or conflicting page IDs for requested track ID '\(requestedTrackID)'")
            return nil
        }
        func referencedSongID(_ value: String) -> String? {
            guard let url = URL(string: value, relativeTo: pageURL)?.absoluteURL else { return nil }
            return shazamSongID(in: url)
        }
        func anchorsRequestedPage(_ value: String) -> Bool {
            // A fragment identifies an entity on a page, including recommendations.
            // Only an explicit mainEntity association may anchor such a recording.
            guard let reference = URL(string: value), reference.fragment == nil else { return false }
            return referencedSongID(value) == requestedTrackID
        }
        let primary = songMetadata(in: page).filter { recording in
            recording.isMainEntity || recording.mainPageURLs.contains(where: anchorsRequestedPage) ||
                recording.urls.contains(where: anchorsRequestedPage)
        }
        guard !primary.isEmpty, primary.allSatisfy({ recording in
            let metadata = recording.identity
            guard metadata.title.nonEmpty != nil, metadata.artist.nonEmpty != nil else { return false }
            let referencedIDs = (recording.urls + recording.mainPageURLs).compactMap(referencedSongID)
            return referencedIDs.allSatisfy({ $0 == requestedTrackID }) &&
                pageIdentityMatches(pageIdentity(for: metadata), expected: expected)
        }) else {
            DebugLog.log("Lyrics Shazam rejected missing, incomplete, or conflicting anchored recordings")
            return nil
        }
        return primary
    }

    private func songMetadata(in page: LyricsHTMLPage) -> [SongPageMetadata] {
        var result: [SongPageMetadata] = []
        var mainEntityIDs = Set<String>()
        let maximumDepth = 32
        var exceededDepthLimit = false
        func identifiers(_ value: Any?, depth: Int = 0) -> [String] {
            guard depth < maximumDepth else { exceededDepthLimit = true; return [] }
            if let values = value as? [Any] {
                return values.flatMap { identifiers($0, depth: depth + 1) }
            }
            if let value = (value as? String)?.nonEmpty { return [value] }
            if let object = value as? [String: Any] { return identifiers(object["@id"], depth: depth + 1) }
            return []
        }
        func structuredArtistNames(_ value: Any?, depth: Int = 0) -> [String] {
            guard depth < maximumDepth else { exceededDepthLimit = true; return [] }
            if let name = (value as? String)?.nonEmpty { return [name] }
            if let artists = value as? [Any] {
                return artists.flatMap { structuredArtistNames($0, depth: depth + 1) }
            }
            return ((value as? [String: Any])?["name"] as? String)?.nonEmpty.map { [$0] } ?? []
        }
        func lyricTexts(_ value: Any?, depth: Int) -> [String] {
            guard depth < maximumDepth else { exceededDepthLimit = true; return [] }
            if let text = (value as? String)?.nonEmpty { return [text] }
            if let values = value as? [Any] {
                return values.flatMap { lyricTexts($0, depth: depth + 1) }
            }
            if let object = value as? [String: Any] {
                return lyricTexts(object["text"], depth: depth + 1)
            }
            return []
        }
        func compositionLyrics(_ value: Any?, depth: Int = 0) -> [String] {
            guard depth < maximumDepth else { exceededDepthLimit = true; return [] }
            if let compositions = value as? [Any] {
                return compositions.flatMap { compositionLyrics($0, depth: depth + 1) }
            }
            if let composition = value as? [String: Any] {
                return lyricTexts(composition["lyrics"], depth: depth + 1)
            }
            return []
        }
        func visit(_ value: Any, main: Bool = false, depth: Int = 0) {
            guard depth < maximumDepth else { exceededDepthLimit = true; return }
            if let values = value as? [Any] {
                values.forEach { visit($0, main: main, depth: depth + 1) }
                return
            }
            if main { mainEntityIDs.formUnion(identifiers(value)) }
            guard let object = value as? [String: Any] else { return }
            let types = (object["@type"] as? [String]) ?? [stringValue(object["@type"])]
            if types.contains("MusicRecording") {
                let artists = structuredArtistNames(object["byArtist"])
                result.append(SongPageMetadata(
                    identity: CandidateMetadata(
                        title: stringValue(object["name"]), artist: artists.joined(separator: " & "),
                        album: "", duration: nil,
                        structuredArtistNames: object["byArtist"] is String || artists.isEmpty ? nil : artists
                    ),
                    lyrics: compositionLyrics(object["recordingOf"]),
                    urls: identifiers(object["url"]) + identifiers(object["@id"]),
                    mainPageURLs: identifiers(object["mainEntityOfPage"]),
                    isMainEntity: main
                ))
            }
            for key in ["@graph", "mainEntity", "track", "itemListElement", "item", "about", "hasPart", "subjectOf"] {
                if let child = object[key] {
                    visit(child, main: key == "mainEntity", depth: depth + 1)
                }
            }
        }
        for script in page.structuredData {
            if let data = script.data(using: .utf8), let json = jsonObject(from: data) {
                visit(json)
            }
        }
        // A truncated traversal could hide a conflicting ID or artist while a
        // shallow sibling still appears valid. Never trust partial evidence.
        guard !exceededDepthLimit else {
            DebugLog.log("Lyrics Shazam rejected JSON-LD exceeding the nesting limit of \(maximumDepth)")
            return []
        }
        for index in result.indices where result[index].urls.contains(where: mainEntityIDs.contains) {
            result[index].isMainEntity = true
        }
        return result
    }

    func letrasBoomLyricsString(in page: LyricsHTMLPage, track: AudioTrack) -> String {
        let controls = "nav, footer, aside, button, form, [role=navigation], [role=button], .lb-noprint, .lb-adslot"
        guard let region = page.textRegion(
            preferred: "#lb-lyrics", excluding: controls,
            excludingInContainer: "header, h1, h2, h3, h4, h5, h6, dl"
        ) else { return "" }
        let metadataNames: Set<String> = ["artista", "cancion", "visitas", "colaboran", "favoritos", "genero", "album"]
        let normalizedArtist = normalizedSearchText(track.artist ?? "")
        let lines = cleanupLyricsText(region.text).components(separatedBy: .newlines)
            .map { text -> (text: String, key: String, label: String?) in
                let key = normalizedSearchText(text)
                let label = text.firstIndex(of: ":").map { normalizedSearchText(String(text[..<$0])) }
                return (text, key, label.flatMap { metadataNames.contains($0) ? $0 : nil })
            }

        if region.isBounded {
            // The DOM supplies the lyric boundary. Do not infer headings or end
            // markers from verse wording; a metadata line cannot erase verses.
            let verses = lines.filter { (normalizedArtist.isEmpty || $0.key != normalizedArtist) && $0.label == nil }
                .map(\.text).joined(separator: "\n")
            return verses
        }

        // Legacy pages lack that boundary. Match a heading once, then stop at
        // metadata, including labels whose values occupy separate DOM blocks.
        let titleTokens = significantTokens(from: track.title)
        let artistTokens = significantTokens(from: track.artist ?? "")
        var started = false
        var verses: [String] = []
        for line in lines where !line.text.isEmpty {
            let isArtistCredit = !normalizedArtist.isEmpty && (line.key == normalizedArtist ||
                (line.label == "artista" && line.text.firstIndex(of: ":").map {
                    normalizedSearchText(String(line.text[line.text.index(after: $0)...])) == normalizedArtist
                } == true))
            if (!started || verses.isEmpty) && isArtistCredit { continue }
            let isFooter = line.label != nil || metadataNames.contains(line.key) ||
                line.key.contains("informacion de") || line.key.contains("top 10 canciones")
            if isFooter { break }

            var isHeading = false
            let tokens = Set(line.key.split(separator: " ").map(String.init))
            if tokens.contains("lyrics") {
                let compact = line.key.replacingOccurrences(of: " ", with: "")
                let titleScore = titleTokens.filter { tokens.contains($0) || ($0.count >= 5 && compact.contains($0)) }.count * 2
                let artistScore = artistTokens.filter { tokens.contains($0) }.count
                isHeading = titleScore + artistScore >= 3
            }
            if !started {
                if isHeading { started = true }
                continue
            }
            if !normalizedArtist.isEmpty && line.key == normalizedArtist { continue }
            if isHeading {
                if verses.isEmpty { continue }
                break
            }
            verses.append(line.text)
        }
        return verses.joined(separator: "\n")
    }

    private func letrasBoomLyricsURL(fromArtistPageData data: Data, baseURL: URL, track: AudioTrack) -> URL? {
        let html = htmlString(from: data)
        let links = allRegexCaptures(in: html, pattern: #"href=["']([^"']*?/letra/[^"']+)["']"#)
        var bestURL: URL?
        var bestScore = 0

        for link in links {
            guard let candidateURL = URL(string: link, relativeTo: baseURL)?.absoluteURL else {
                continue
            }

            let score = textMatchScore(candidateURL.absoluteString, track: track)
            DebugLog.log("Lyrics LetrasBoom candidate score=\(score) url=\(candidateURL.absoluteString)")
            if score > bestScore {
                bestScore = score
                bestURL = candidateURL
            }
        }

        return bestScore >= 5 ? bestURL : nil
    }

    private func geniusLyricsURLFromAPIData(_ data: Data, track: AudioTrack) -> URL? {
        guard let json = jsonObject(from: data) as? [String: Any],
              let response = json["response"] as? [String: Any] else {
            return nil
        }

        let hits = dictionaries(from: response["hits"])
        var bestURL: URL?
        var bestScore = 0
        for hit in hits {
            guard let result = hit["result"] as? [String: Any],
                  let url = URL(string: stringValue(result["url"]))
            else {
                continue
            }

            let score = geniusURLScore(url, track: track)
            DebugLog.log("Lyrics Genius API candidate score=\(score) url=\(url.absoluteString)")
            if score > bestScore {
                bestScore = score
                bestURL = url
            }
        }

        return bestScore > 0 ? bestURL : nil
    }

    private func geniusSearchQueries(for track: AudioTrack) -> [String] {
        let title = track.title
        let artist = track.artist ?? ""
        let simplifiedTitle = simplifiedTitleForSearch(title)
        var queries: [String] = []

        if !artist.isEmpty, !simplifiedTitle.isEmpty {
            queries.append("\(artist) \(simplifiedTitle)")
        }
        if !artist.isEmpty, !title.isEmpty, title != simplifiedTitle {
            queries.append("\(artist) \(title)")
        }
        if !simplifiedTitle.isEmpty {
            queries.append(simplifiedTitle)
        }
        if !title.isEmpty, title != simplifiedTitle {
            queries.append(title)
        }

        var seen = Set<String>()
        return queries.filter { seen.insert($0).inserted }
    }

    private func geniusWebsiteSearchURL(for query: String) -> URL? {
        url(
            "https://genius.com/search",
            queryItems: [URLQueryItem(name: "q", value: query)]
        )
    }

    private func geniusLyricsURLFromSearchData(_ data: Data, track: AudioTrack) -> URL? {
        var html = htmlString(from: data)
        html = html
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u002F", with: "/")

        var urls: [URL] = []
        for urlString in allRegexCaptures(
            in: html,
            pattern: #"href=["'](https://genius\.com/[^"'#?]+-lyrics)["']"#
        ) {
            if let url = URL(string: urlString), !urls.contains(url) {
                urls.append(url)
            }
        }
        for path in allRegexCaptures(in: html, pattern: #"href=["'](/[^"'#?]+-lyrics)["']"#) {
            if let url = URL(string: path, relativeTo: URL(string: "https://genius.com"))?.absoluteURL,
               !urls.contains(url) {
                urls.append(url)
            }
        }

        var bestURL: URL?
        var bestScore = 0
        for url in urls {
            let score = geniusURLScore(url, track: track)
            DebugLog.log("Lyrics Genius website candidate score=\(score) url=\(url.absoluteString)")
            if score > bestScore {
                bestScore = score
                bestURL = url
            }
        }

        return bestScore > 0 ? bestURL : nil
    }

    private func geniusLyricsString(from data: Data) -> String {
        let html = htmlString(from: data)
        let containers = geniusLyricsContainerFragments(in: html)
        let legacyContainers = allRegexCaptures(
            in: html,
            pattern: #"<div\b[^>]*class=["'][^"']*Lyrics__Container[^"']*["'][^>]*>(.*?)</div>"#
        )
        let fragments = containers.isEmpty ? legacyContainers : containers
        let text = fragments
            .map { textFromGeniusLyricsHTMLFragment($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return text.isEmpty ? "" : cleanedGeniusLyricsString(text)
    }

    private func geniusLyricsContainerFragments(in html: String) -> [String] {
        guard !html.isEmpty,
              let markerExpression = try? NSRegularExpression(
                  pattern: #"data-lyrics-container=["']true["']"#,
                  options: [.caseInsensitive]
              )
        else {
            return []
        }

        let nsHTML = html as NSString
        let matches = markerExpression.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        var fragments: [String] = []
        for match in matches {
            let searchRange = NSRange(location: 0, length: match.range.location)
            let divStartRange = nsHTML.range(
                of: "<div",
                options: [.backwards, .caseInsensitive],
                range: searchRange
            )
            guard divStartRange.location != NSNotFound,
                  let fragment = balancedDivFragment(in: html, startingAtUTF16Offset: divStartRange.location),
                  !fragments.contains(fragment)
            else {
                continue
            }

            fragments.append(fragment)
        }

        return fragments
    }

    private func balancedDivFragment(in html: String, startingAtUTF16Offset offset: Int) -> String? {
        let nsHTML = html as NSString
        guard offset >= 0, offset < nsHTML.length,
              let expression = try? NSRegularExpression(
                  pattern: #"</?div\b[^>]*>"#,
                  options: [.caseInsensitive]
              )
        else {
            return nil
        }

        var depth = 0
        let range = NSRange(location: offset, length: nsHTML.length - offset)
        for match in expression.matches(in: html, range: range) {
            let tag = nsHTML.substring(with: match.range).lowercased()
            if tag.hasPrefix("</div") {
                depth -= 1
                if depth == 0 {
                    let fragmentRange = NSRange(location: offset, length: NSMaxRange(match.range) - offset)
                    return nsHTML.substring(with: fragmentRange)
                }
            } else {
                depth += 1
            }
        }

        return nil
    }

    private func textFromGeniusLyricsHTMLFragment(_ fragment: String) -> String {
        LyricsHTMLPage.fragmentText(fragment, context: "Genius lyrics fragment") ?? ""
    }

    private func cleanedGeniusLyricsString(_ lyricsString: String) -> String {
        let withoutJoinedHeader = replacingMatches(
            in: lyricsString,
            pattern: #"^\s*\d+\s*Contributors?.*?Lyrics\s*"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators],
            with: ""
        )

        let contributorExpression = try? NSRegularExpression(
            pattern: #"^\d+\s+Contributors?$"#,
            options: [.caseInsensitive]
        )
        var cleanedLines: [String] = []
        for rawLine in withoutJoinedHeader.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if cleanedLines.last?.isEmpty == false {
                    cleanedLines.append("")
                }
                continue
            }

            let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
            if contributorExpression?.firstMatch(in: line, range: lineRange) != nil {
                continue
            }
            if line.hasSuffix(" Lyrics") || line == "Lyrics" {
                continue
            }
            if line.localizedCaseInsensitiveContains("You might also like") {
                continue
            }

            cleanedLines.append(line)
        }

        while cleanedLines.last == "" {
            cleanedLines.removeLast()
        }
        return cleanedLines.joined(separator: "\n")
    }

    /// Scores a Genius lyrics URL ("/Adele-hello-lyrics") against the track.
    /// 0 rejects. The slug has to contain the whole title as consecutive
    /// words, however short the title is, and the artist (or one word of it)
    /// when the track has one. An artist alone is never enough. Slug words
    /// that belong to neither ("live", "remix") lower the score, so the plain
    /// song page is preferred.
    func geniusURLScore(_ url: URL, track: AudioTrack) -> Int {
        var slugWords = normalizedSearchText(url.lastPathComponent)
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if slugWords.last == "lyrics" {
            slugWords.removeLast()
        }

        // Slugs drop apostrophes ("dont-stop"), so compare without spaces.
        func slugRun(spelling text: String) -> Range<Int>? {
            let compact = text.components(separatedBy: .whitespaces).joined()
            guard !compact.isEmpty else {
                return nil
            }

            for start in slugWords.indices {
                var joined = ""
                for end in start..<slugWords.count {
                    joined += slugWords[end]
                    if joined == compact {
                        return start..<(end + 1)
                    }
                    if joined.count >= compact.count {
                        break
                    }
                }
            }
            return nil
        }

        let titleRun = htmlValidationTitleVariants(for: track.title)
            .compactMap(slugRun)
            .max { $0.count < $1.count }
        guard let titleRun else {
            return 0
        }

        var explained = Set(titleRun)
        let artistVariants = searchTextVariants(for: track.artist ?? "")
        if !artistVariants.isEmpty {
            let artistWords = Set(artistVariants.flatMap {
                $0.components(separatedBy: .whitespaces).filter { $0.count >= 2 }
            })
            let artistIndices = slugWords.indices.filter { !titleRun.contains($0) && artistWords.contains(slugWords[$0]) }
            let artistRun = artistVariants.compactMap(slugRun).first { !$0.overlaps(titleRun) }
            guard !artistIndices.isEmpty || artistRun != nil else {
                return 0
            }

            explained.formUnion(artistIndices)
            explained.formUnion(artistRun.map(Array.init) ?? [])
        }

        let unexplainedWords = slugWords.count - explained.count
        return max(1, 100 + explained.count - unexplainedWords * 3)
    }

    private func firstRegexCapture(in string: String, pattern: String) -> String {
        guard !string.isEmpty,
              let expression = try? NSRegularExpression(
                  pattern: pattern,
                  options: [.caseInsensitive, .dotMatchesLineSeparators]
              ),
              let match = expression.firstMatch(
                  in: string,
                  range: NSRange(string.startIndex..<string.endIndex, in: string)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: string)
        else {
            return ""
        }

        return String(string[range])
    }

    private func allRegexCaptures(in string: String, pattern: String) -> [String] {
        guard !string.isEmpty,
              let expression = try? NSRegularExpression(
                  pattern: pattern,
                  options: [.caseInsensitive, .dotMatchesLineSeparators]
              )
        else {
            return []
        }

        return allRegexCaptures(in: string, expression: expression)
    }

    private func allRegexCaptures(in string: String, expression: NSRegularExpression) -> [String] {
        return expression.matches(
            in: string,
            range: NSRange(string.startIndex..<string.endIndex, in: string)
        )
        .compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: string)
            else {
                return nil
            }

            return String(string[range])
        }
    }

    private func replacingMatches(
        in string: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        with template: String
    ) -> String {
        guard !string.isEmpty,
              let expression = try? NSRegularExpression(pattern: pattern, options: options)
        else {
            return string
        }

        return expression.stringByReplacingMatches(
            in: string,
            range: NSRange(string.startIndex..<string.endIndex, in: string),
            withTemplate: template
        )
    }

    private func responseBodySnippet(from data: Data) -> String {
        let body = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return String(body.prefix(240))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func simpleSlug(_ string: String) -> String {
        asciiSlug(string, separator: "-", keepSeparators: true, ampersandWords: false)
    }

    private func songLyricsSlug(_ string: String) -> String {
        asciiSlug(string, separator: "-", keepSeparators: true, ampersandWords: true)
    }

    private func compactSlug(_ string: String) -> String {
        asciiSlug(string, separator: "", keepSeparators: false, ampersandWords: false)
    }

    private func asciiSlug(
        _ string: String,
        separator: String,
        keepSeparators: Bool,
        ampersandWords: Bool
    ) -> String {
        let folded = string.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        .lowercased()
        var slug = ""
        var previousWasSeparator = true

        for scalar in folded.unicodeScalars {
            let value = scalar.value
            if (97...122).contains(value) || (48...57).contains(value) {
                slug.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if ampersandWords, scalar.value == 38 {
                slug += "and"
                previousWasSeparator = false
            } else if ampersandWords, scalar.value == 64 {
                slug += "at"
                previousWasSeparator = false
            } else if keepSeparators, !previousWasSeparator {
                slug += separator
                previousWasSeparator = true
            }
        }

        return slug.trimmingCharacters(in: CharacterSet(charactersIn: separator))
    }

    private func shazamSlug(_ string: String) -> String {
        let lowerString = string.lowercased()
        var slug = ""
        var previousWasSeparator = true

        for scalar in lowerString.unicodeScalars {
            let value = scalar.value
            if (97...122).contains(value) || (48...57).contains(value) {
                slug.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if value <= 127 {
                if !previousWasSeparator {
                    slug.append("-")
                    previousWasSeparator = true
                }
            } else {
                for byte in String(scalar).utf8 {
                    slug += String(format: "%02x", Int(byte))
                }
                previousWasSeparator = false
            }
        }

        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func musixmatchUserToken() -> String? {
        UserDefaults.standard.string(forKey: "VLCLyricsMusixmatchUserToken")?.nonEmpty
            ?? ProcessInfo.processInfo.environment["FENGLU_MUSIXMATCH_USER_TOKEN"]?.nonEmpty
            ?? ProcessInfo.processInfo.environment["MUSIXMATCH_USER_TOKEN"]?.nonEmpty
    }

    private func geniusAccessToken() -> String? {
        UserDefaults.standard.string(forKey: "VLCLyricsGeniusAccessToken")?.nonEmpty
            ?? ProcessInfo.processInfo.environment["FENGLU_GENIUS_ACCESS_TOKEN"]?.nonEmpty
            ?? ProcessInfo.processInfo.environment["GENIUS_ACCESS_TOKEN"]?.nonEmpty
    }

    private func bestCandidateSort(_ lhs: OnlineLyricsCandidate, _ rhs: OnlineLyricsCandidate) -> Bool {
        // The synchronized bonus dwarfs everything else in `score`, so match
        // confidence is compared first: a result that only shares words with
        // the title never beats one whose title matched.
        if lhs.match.isStrongTitle != rhs.match.isStrongTitle {
            return lhs.match.isStrongTitle
        }

        if lhs.score == rhs.score {
            return lhs.document.isSynchronized && !rhs.document.isSynchronized
        }

        return lhs.score > rhs.score
    }
}

private struct LyricsLookupMetadata: Sendable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval?

    var searchQuery: String {
        artist.isEmpty ? title : "\(artist) \(title)"
    }
}

private struct OnlineLyricsRequest: Sendable {
    var sourceName: String
    var providerName: String
    var url: URL
}

private struct OnlineLyricsCandidate: Sendable {
    var sourceName: String
    var providerName: String
    var rawLyrics: String
    var document: LyricsDocument
    var score: Int
    var match: CandidateMatch
    var isHighConfidence: Bool
}

private enum OnlineLookupEvent: Sendable {
    case candidate(OnlineLyricsCandidate?)
    case deadlineReached
}

/// How firmly a candidate was tied to the playing track before its lyrics
/// were read. Carried into cross-provider selection.
private struct CandidateMatch: Sendable {
    var isStrongTitle: Bool
    /// Equal title and matching artist from provider metadata.
    var isExactIdentity: Bool

    /// Title confirmed, by metadata or by the page that was fetched.
    static let validatedPage = CandidateMatch(isStrongTitle: true, isExactIdentity: false)
    static let exactIdentity = CandidateMatch(isStrongTitle: true, isExactIdentity: true)
    /// Accepted on shared words, release position, or without any identity check.
    static let unverified = CandidateMatch(isStrongTitle: false, isExactIdentity: false)
}

private struct ArtistMatchIdentity {
    var primary: [Set<String>]
    var credits: [Set<String>]
    var completePrimary: Set<String>
}

private struct PageSongIdentity {
    var titles: TitleMatchIdentity
    var artists: ArtistMatchIdentity
}

private struct TitleMatchIdentity {
    var variants: Set<String>
    var remasterVariants: Set<String>

    func matches(_ expected: TitleMatchIdentity) -> Bool {
        !variants.isDisjoint(with: expected.variants) ||
            !remasterVariants.isDisjoint(with: expected.remasterVariants)
    }
}

private struct SongPageMetadata {
    var identity: CandidateMetadata
    var lyrics: [String]
    var urls: [String]
    var mainPageURLs: [String]
    var isMainEntity: Bool
}

private struct ShazamSearchCandidate {
    var dictionary: [String: Any]
    var metadata: CandidateMetadata
    var expected: PageSongIdentity
    var isAcceptable: Bool
}

private struct CandidateMetadata {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval?
    var trackNumber: Int?
    var structuredArtistNames: [String]?

    init(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval?,
        trackNumber: Int? = nil,
        structuredArtistNames: [String]? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.trackNumber = trackNumber
        self.structuredArtistNames = structuredArtistNames
    }
}

private struct LRCLIBLyrics: Decodable {
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: TimeInterval?
    let plainLyrics: String?
    let syncedLyrics: String?
}
