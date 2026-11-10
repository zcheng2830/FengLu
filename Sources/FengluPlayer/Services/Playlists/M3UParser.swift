import Foundation

struct M3UParser {
    var environment: PlaylistParsingEnvironment = .live

    func parse(_ url: URL) throws -> [AudioTrack] {
        let baseURL = url.deletingLastPathComponent()
        let contents = try TextFileLoader.load(url) { candidate in
            referencesExistingMedia(candidate, baseURL: baseURL)
        }
        return parse(
            contents: contents,
            baseURL: baseURL,
            playlistName: url.deletingPathExtension().lastPathComponent
        )
    }

    /// Pure parse step: no file is read here; media lookups go through `environment`.
    func parse(contents: String, baseURL: URL, playlistName: String? = nil) -> [AudioTrack] {
        var pendingInfo: ExtendedInfo?
        var tracks: [AudioTrack] = []
        let lines = contents.components(separatedBy: .newlines)
        var commentLineCount = 0
        var blankLineCount = 0
        var mediaLineCount = 0

        DebugLog.log("M3U parser started for \(playlistName ?? "<unnamed>"); \(lines.count) line(s), base \(baseURL.path)")

        for (lineNumber, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                blankLineCount += 1
                continue
            }

            if line.uppercased().hasPrefix(Self.extendedInfoPrefix) {
                pendingInfo = parseExtendedInfo(line)
                DebugLog.log("M3U line \(lineNumber + 1): EXTINF duration=\(display(pendingInfo?.duration)) artist=\(pendingInfo?.artist ?? "<none>") title=\(pendingInfo?.title ?? "<none>")")
                continue
            }

            if line.hasPrefix("#") {
                commentLineCount += 1
                DebugLog.log("M3U line \(lineNumber + 1): ignored comment/directive \(line)")
                continue
            }

            mediaLineCount += 1
            let mediaURL = resolve(line, relativeTo: baseURL)
            let info = pendingInfo
            let duration = info?.duration ?? PlaylistDuration.sanitized(environment.duration(mediaURL))
            DebugLog.log(
                "M3U line \(lineNumber + 1): media \(line) -> \(mediaURL.path) " +
                "duration=\(display(duration))"
            )
            tracks.append(AudioTrack(
                url: mediaURL,
                title: info?.title,
                artist: info?.artist,
                duration: duration,
                source: .playlist,
                playlistName: playlistName
            ))
            pendingInfo = nil
        }

        DebugLog.log("M3U parser summary: \(tracks.count) track(s), \(mediaLineCount) media line(s), \(commentLineCount) comment/directive line(s), \(blankLineCount) blank line(s)")
        return tracks
    }

    private static let extendedInfoPrefix = "#EXTINF:"

    private func referencesExistingMedia(_ contents: String, baseURL: URL) -> Bool {
        contents.components(separatedBy: .newlines).contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                return false
            }

            return environment.fileExists(resolve(line, relativeTo: baseURL))
        }
    }

    private func parseExtendedInfo(_ line: String) -> ExtendedInfo {
        let payload = String(line.dropFirst(Self.extendedInfoPrefix.count))
        let parts = payload.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        // The length may be followed by attributes: `#EXTINF:123 tvg-id="x",Title`.
        // Unknown (-1), zero and absurd lengths are dropped so the file is probed.
        let duration = parts.first
            .flatMap { $0.split(whereSeparator: \.isWhitespace).first }
            .flatMap { TimeInterval($0) }
            .flatMap { PlaylistDuration.sanitized($0) }
        let display = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil

        if let display, display.contains(" - ") {
            let titleParts = display.components(separatedBy: " - ")
            return ExtendedInfo(
                duration: duration,
                artist: titleParts.first?.nonEmpty,
                title: titleParts.dropFirst().joined(separator: " - ").nonEmpty
            )
        }

        return ExtendedInfo(duration: duration, artist: nil, title: display?.nonEmpty)
    }

    private func resolve(_ value: String, relativeTo baseURL: URL) -> URL {
        PlaylistPathResolver.resolve(
            value,
            relativeTo: baseURL,
            isURI: false,
            fileExists: environment.fileExists
        )
    }

    private func display(_ value: TimeInterval?) -> String {
        guard let value else {
            return "<none>"
        }

        return String(value)
    }

    private struct ExtendedInfo {
        var duration: TimeInterval?
        var artist: String?
        var title: String?
    }
}
