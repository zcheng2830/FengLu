import Foundation

struct CueSheetParser {
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
        var albumTitle: String?
        var albumPerformer: String?
        var currentFile: String?
        var pendingTrack: CueTrack?
        var cueTracks: [CueTrack] = []
        var hasEnteredTrack = false
        let lines = contents.components(separatedBy: .newlines)
        var blankLineCount = 0
        var ignoredCommandCount = 0

        DebugLog.log("Cue parser started for \(playlistName ?? "<unnamed>"); \(lines.count) line(s), base \(baseURL.path)")

        for (lineNumber, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                blankLineCount += 1
                continue
            }

            guard let command = cueCommand(in: line) else {
                ignoredCommandCount += 1
                DebugLog.log("Cue line \(lineNumber + 1): could not read command: \(line)")
                continue
            }

            switch command.name {
            case "FILE":
                currentFile = fileName(in: command.arguments)
                DebugLog.log("Cue line \(lineNumber + 1): FILE \(currentFile ?? "<missing>")")
                // EAC "non-compliant" sheets put the next FILE after TRACK (and an
                // optional INDEX 00 pregap in the previous file). Until INDEX 01
                // is seen, the pending track belongs to the newest FILE.
                if pendingTrack != nil, pendingTrack?.start == nil {
                    pendingTrack?.fileName = currentFile
                    DebugLog.log("Cue line \(lineNumber + 1): rebound pending track \(display(pendingTrack?.number)) to this FILE")
                }
                continue

            case "TRACK":
                if let pendingTrack {
                    cueTracks.append(pendingTrack)
                }

                hasEnteredTrack = true
                let number = trackNumber(in: command.arguments)
                pendingTrack = CueTrack(number: number, fileName: currentFile)
                DebugLog.log("Cue line \(lineNumber + 1): TRACK \(display(number)) using file \(currentFile ?? "<missing>")")
                continue

            case "TITLE":
                if hasEnteredTrack {
                    pendingTrack?.title = cueValue(in: command.arguments)
                    DebugLog.log("Cue line \(lineNumber + 1): track \(display(pendingTrack?.number)) title=\(pendingTrack?.title ?? "<none>")")
                } else {
                    albumTitle = cueValue(in: command.arguments)
                    DebugLog.log("Cue line \(lineNumber + 1): album title=\(albumTitle ?? "<none>")")
                }
                continue

            case "PERFORMER":
                if hasEnteredTrack {
                    pendingTrack?.performer = cueValue(in: command.arguments)
                    DebugLog.log("Cue line \(lineNumber + 1): track \(display(pendingTrack?.number)) performer=\(pendingTrack?.performer ?? "<none>")")
                } else {
                    albumPerformer = cueValue(in: command.arguments)
                    DebugLog.log("Cue line \(lineNumber + 1): album performer=\(albumPerformer ?? "<none>")")
                }
                continue

            case "INDEX":
                if let index = cueIndex(in: command.arguments) {
                    if Int(index.number) == 1 {
                        pendingTrack?.start = parseCueTime(index.time)
                        DebugLog.log("Cue line \(lineNumber + 1): track \(display(pendingTrack?.number)) INDEX 01 \(index.time)")
                    } else {
                        DebugLog.log("Cue line \(lineNumber + 1): track \(display(pendingTrack?.number)) ignored INDEX \(index.number) \(index.time)")
                    }
                }

            default:
                ignoredCommandCount += 1
                continue
            }
        }

        if let pendingTrack {
            cueTracks.append(pendingTrack)
        }

        DebugLog.log("Cue parser collected \(cueTracks.count) raw cue track(s); \(blankLineCount) blank line(s), \(ignoredCommandCount) ignored command(s)")

        cueTracks = cueTracks.enumerated().map { index, track in
            var mutableTrack = track
            if cueTracks.indices.contains(index + 1) {
                let nextTrack = cueTracks[index + 1]
                let trackFile = track.fileName ?? currentFile
                let nextTrackFile = nextTrack.fileName ?? currentFile
                // The next track only bounds this one when both live in the same
                // file and it starts later; otherwise this track runs to the end
                // of its own file.
                if trackFile == nextTrackFile,
                   let nextStart = nextTrack.start,
                   nextStart > (track.start ?? 0) {
                    mutableTrack.end = nextStart
                } else {
                    mutableTrack.end = nil
                }
            }
            return mutableTrack
        }

        var resolvedMediaURLs: [String: URL] = [:]
        var mediaDurations: [URL: TimeInterval] = [:]
        let tracks = cueTracks.compactMap { cueTrack -> AudioTrack? in
            guard let fileName = cueTrack.fileName ?? currentFile else {
                DebugLog.log("Cue parser skipped track \(display(cueTrack.number)) because it has no FILE")
                return nil
            }

            let mediaURL: URL
            if let cachedURL = resolvedMediaURLs[fileName] {
                mediaURL = cachedURL
            } else {
                mediaURL = resolvedMediaURL(for: fileName, relativeTo: baseURL)
                resolvedMediaURLs[fileName] = mediaURL
            }

            let mediaDuration = cachedMediaDuration(for: mediaURL, in: &mediaDurations)
            let resolvedEnd = resolvedCueEnd(for: cueTrack, mediaDuration: mediaDuration)
            DebugLog.log(
                "Cue parser resolved track \(display(cueTrack.number)) media \(fileName) -> \(mediaURL.path); " +
                "start=\(display(cueTrack.start)), end=\(display(resolvedEnd)), " +
                "mediaDuration=\(display(mediaDuration))"
            )
            return AudioTrack(
                url: mediaURL,
                title: cueTrack.title,
                artist: cueTrack.performer ?? albumPerformer,
                album: albumTitle,
                trackNumber: cueTrack.number,
                duration: mediaDuration,
                cueStart: cueTrack.start,
                cueEnd: resolvedEnd,
                source: .cue,
                playlistName: playlistName
            )
        }

        DebugLog.log("Cue parser returning \(tracks.count) audio track(s)")
        return tracks
    }

    /// Whether any `FILE` in this decoding of the sheet resolves to media on
    /// disk. Used to pick between legacy text encodings.
    private func referencesExistingMedia(_ contents: String, baseURL: URL) -> Bool {
        contents.components(separatedBy: .newlines).contains { rawLine in
            guard let command = cueCommand(in: rawLine),
                  command.name == "FILE",
                  let fileName = fileName(in: command.arguments)
            else {
                return false
            }

            return environment.fileExists(resolvedMediaURL(for: fileName, relativeTo: baseURL))
        }
    }

    /// Extensions tried, in this order, when a sheet names media that was
    /// re-encoded after the sheet was written (`album.wav` next to `album.flac`).
    private static let alternateMediaExtensions: [String] = {
        let preferred = ["flac", "ape", "wv", "wav", "m4a", "alac", "aiff", "aif", "dsf", "dff"]
        let remaining = SupportedFileTypes.audioExtensions.subtracting(preferred).sorted()
        return preferred.filter(SupportedFileTypes.audioExtensions.contains) + remaining
    }()

    private func resolvedMediaURL(for fileName: String, relativeTo baseURL: URL) -> URL {
        let declaredURL = mediaURL(for: fileName, relativeTo: baseURL)
        if environment.fileExists(declaredURL) {
            return declaredURL
        }

        let stem = declaredURL.deletingPathExtension()
        let declaredExtension = declaredURL.pathExtension.lowercased()
        for pathExtension in Self.alternateMediaExtensions where pathExtension != declaredExtension {
            let candidate = stem.appendingPathExtension(pathExtension)
            if environment.fileExists(candidate) {
                DebugLog.log("Cue parser substituted \(candidate.lastPathComponent) for missing \(declaredURL.lastPathComponent)")
                return candidate
            }
        }

        // The sheet may carry a Windows path whose directories do not exist here.
        let siblingURL = baseURL.appendingPathComponent(declaredURL.lastPathComponent).standardizedFileURL
        if siblingURL != declaredURL, environment.fileExists(siblingURL) {
            return siblingURL
        }

        DebugLog.log("Cue parser could not find media \(declaredURL.lastPathComponent)")
        return declaredURL
    }

    private func cueCommand(in line: String) -> CueCommand? {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else {
            return nil
        }

        guard let boundary = trimmedLine.firstIndex(where: \.isWhitespace) else {
            return CueCommand(name: trimmedLine.uppercased(), arguments: "")
        }

        let name = String(trimmedLine[..<boundary]).uppercased()
        let arguments = String(trimmedLine[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return CueCommand(name: name, arguments: arguments)
    }

    private func cueValue(in arguments: String) -> String? {
        quotedValue(in: arguments) ?? arguments.nonEmpty
    }

    private func fileName(in arguments: String) -> String? {
        if let quotedFileName = quotedValue(in: arguments) {
            return quotedFileName
        }

        let parts = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else {
            return nil
        }

        if parts.count == 1 {
            return parts[0].nonEmpty
        }

        return parts.dropLast().joined(separator: " ").nonEmpty
    }

    private func trackNumber(in arguments: String) -> Int? {
        arguments.split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) }
    }

    private func cueIndex(in arguments: String) -> (number: String, time: String)? {
        let parts = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 2 else {
            return nil
        }

        return (parts[0], parts[1])
    }

    private func mediaURL(for fileName: String, relativeTo baseURL: URL) -> URL {
        let normalizedFileName = fileName.replacingOccurrences(of: "\\", with: "/")
        if normalizedFileName.hasPrefix("/") {
            return URL(fileURLWithPath: normalizedFileName).standardizedFileURL
        }

        return baseURL.appendingPathComponent(normalizedFileName).standardizedFileURL
    }

    private func cachedMediaDuration(for mediaURL: URL, in cache: inout [URL: TimeInterval]) -> TimeInterval? {
        if let cachedDuration = cache[mediaURL] {
            return cachedDuration
        }

        guard let duration = PlaylistDuration.sanitized(environment.duration(mediaURL)) else {
            return nil
        }

        cache[mediaURL] = duration
        return duration
    }

    private func resolvedCueEnd(for cueTrack: CueTrack, mediaDuration: TimeInterval?) -> TimeInterval? {
        if let end = cueTrack.end {
            return end
        }

        guard let start = cueTrack.start,
              let mediaDuration,
              mediaDuration > start
        else {
            return nil
        }

        return mediaDuration
    }

    private func display(_ number: Int?) -> String {
        guard let number else {
            return "?"
        }

        return String(number)
    }

    private func display(_ time: TimeInterval?) -> String {
        guard let time else {
            return "<none>"
        }

        return String(time)
    }

    private func quotedValue(in line: String) -> String? {
        guard let start = line.firstIndex(of: "\""), let end = line.lastIndex(of: "\""), start < end else {
            return nil
        }

        return String(line[line.index(after: start)..<end]).nonEmpty
    }

    private func parseCueTime(_ value: String?) -> TimeInterval? {
        guard let value else {
            return nil
        }

        let parts = value.split(separator: ":").compactMap { TimeInterval($0) }
        guard parts.count == 3, parts.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return nil
        }

        return PlaylistDuration.sanitizedPosition((parts[0] * 60) + parts[1] + (parts[2] / 75))
    }

    private struct CueCommand {
        var name: String
        var arguments: String
    }

    private struct CueTrack {
        var number: Int?
        var fileName: String?
        var title: String?
        var performer: String?
        var start: TimeInterval?
        var end: TimeInterval?
    }
}
