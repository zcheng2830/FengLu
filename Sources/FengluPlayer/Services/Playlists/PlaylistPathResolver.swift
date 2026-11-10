import Foundation

/// File-system and media lookups used by the playlist parsers. Injected so the
/// parsers can be exercised without touching the disk or decoding audio.
struct PlaylistParsingEnvironment: Sendable {
    var fileExists: @Sendable (URL) -> Bool
    var duration: @Sendable (URL) -> TimeInterval?

    static let live = PlaylistParsingEnvironment(
        fileExists: { url in
            url.isFileURL && FileManager.default.fileExists(atPath: url.path)
        },
        duration: { url in
            AudioFileDurationProbe.duration(for: url)
        }
    )
}

enum PlaylistDuration {
    /// Longest duration a playlist may declare (about 115 days). Anything above
    /// it is treated as unknown, not trusted.
    static let maximum: TimeInterval = 10_000_000

    /// A positive, finite, plausible duration; `nil` for everything else.
    static func sanitized(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0, value <= maximum else {
            return nil
        }

        return value
    }

    /// A finite, non-negative, plausible position inside a media file.
    static func sanitizedPosition(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0, value <= maximum else {
            return nil
        }

        return value
    }
}

enum PlaylistPathResolver {
    private static let urlSchemes: Set<String> = ["file", "http", "https"]

    /// Resolves one playlist entry to a URL.
    ///
    /// - Parameters:
    ///   - isURI: `true` when the format defines entries as URIs (XSPF), so
    ///     relative entries are percent-encoded. M3U entries are plain paths.
    static func resolve(
        _ rawValue: String,
        relativeTo baseURL: URL,
        isURI: Bool,
        fileExists: (URL) -> Bool
    ) -> URL {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Only real URL schemes count. `C:\Music\a.mp3` and `Re: Zero.mp3`
        // both parse with a "scheme" but are paths.
        if let scheme = scheme(of: value), urlSchemes.contains(scheme) {
            if let url = URL(string: value) ?? URL(string: percentEncoded(value)) {
                return url.isFileURL ? url.standardizedFileURL : url
            }
        }

        if value.hasPrefix("~") {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
        }

        // A literal file name may legitimately contain a backslash on macOS.
        let literalURL = fileURL(forPath: value, relativeTo: baseURL)
        if value.contains("\\"), fileExists(literalURL) {
            return literalURL
        }

        let path = value.replacingOccurrences(of: "\\", with: "/")
        let pathURL = fileURL(forPath: path, relativeTo: baseURL)
        let decodedURL = path.removingPercentEncoding
            .flatMap { $0 == path ? nil : fileURL(forPath: $0, relativeTo: baseURL) }

        var candidates: [URL] = []
        if isURI, let decodedURL {
            candidates = [decodedURL, pathURL]
        } else {
            candidates = [pathURL] + (decodedURL.map { [$0] } ?? [])
        }

        // `C:/Music/a.mp3` cannot exist here; the file often sits next to the playlist.
        if hasWindowsDrivePrefix(path), let lastComponent = path.split(separator: "/").last {
            candidates.append(fileURL(forPath: String(lastComponent), relativeTo: baseURL))
        }

        return candidates.first(where: fileExists) ?? candidates[0]
    }

    private static func fileURL(forPath path: String, relativeTo baseURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }

        return baseURL.appendingPathComponent(path).standardizedFileURL
    }

    private static func scheme(of value: String) -> String? {
        guard let colon = value.firstIndex(of: ":") else {
            return nil
        }

        let scheme = value[..<colon]
        guard scheme.count > 1,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }),
              value[colon...].hasPrefix(":/")
        else {
            return nil
        }

        return scheme.lowercased()
    }

    private static func hasWindowsDrivePrefix(_ path: String) -> Bool {
        let characters = Array(path.prefix(3))
        return characters.count == 3
            && characters[0].isASCII && characters[0].isLetter
            && characters[1] == ":"
            && characters[2] == "/"
    }

    private static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert(charactersIn: ":%?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
