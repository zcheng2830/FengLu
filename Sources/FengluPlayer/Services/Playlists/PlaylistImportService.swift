import Foundation

struct PlaylistImportResult: Sendable {
    var tracks: [AudioTrack] = []
    /// One human-readable line per item that could not be imported in full.
    var warnings: [String] = []
}

struct PlaylistImportService {
    private let parser = PlaylistParsingService()

    /// Imports every item it can. A file that fails to parse is reported in
    /// `warnings` and never discards the tracks from the other items.
    func importItems(_ urls: [URL]) -> PlaylistImportResult {
        var result = PlaylistImportResult()

        for url in urls {
            DebugLog.log("Import service received: \(url.path)")
            let didAccess = url.startAccessingSecurityScopedResource()
            DebugLog.log("Security scoped access for \(url.lastPathComponent): \(didAccess)")
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let countBefore = result.tracks.count
            importItem(url, into: &result)
            DebugLog.log("Import service item result for \(url.lastPathComponent): \(result.tracks.count - countBefore) track(s)")
        }

        DebugLog.log("Import service total result: \(result.tracks.count) track(s), \(result.warnings.count) warning(s)")
        return result
    }

    private func importItem(_ url: URL, into result: inout PlaylistImportResult) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        DebugLog.log("Import item stat exists=\(exists), isDirectory=\(isDirectory.boolValue), ext=\(url.pathExtension.localizedLowercase)")

        guard exists else {
            result.warnings.append("\(url.lastPathComponent): the file could not be found")
            return
        }

        if isDirectory.boolValue {
            DebugLog.log("Importing directory: \(url.path)")
            importDirectory(url, into: &result)
            return
        }

        if SupportedFileTypes.isPlaylist(url) {
            DebugLog.log("Parsing playlist file: \(url.path)")
            result.tracks.append(contentsOf: parsePlaylist(url, warnings: &result.warnings))
            return
        }

        guard SupportedFileTypes.isAudio(url) else {
            DebugLog.log("Skipping unsupported file: \(url.path)")
            let pathExtension = url.pathExtension.isEmpty ? "this" : ".\(url.pathExtension.lowercased())"
            result.warnings.append("\(url.lastPathComponent): \(pathExtension) files are not supported")
            return
        }

        DebugLog.log("Importing audio file: \(url.path)")
        result.tracks.append(audioTrack(for: url))
    }

    private func parsePlaylist(_ url: URL, warnings: inout [String]) -> [AudioTrack] {
        let tracks: [AudioTrack]
        do {
            tracks = try parser.parsePlaylist(url)
        } catch {
            DebugLog.log("Playlist parse failed for \(url.path): \(error.localizedDescription)")
            warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
            return []
        }

        if tracks.isEmpty {
            warnings.append("\(url.lastPathComponent): no tracks were found")
            return []
        }

        let missingCount = tracks.count { track in
            track.url.isFileURL && !FileManager.default.fileExists(atPath: track.url.path)
        }
        if missingCount > 0 {
            warnings.append(
                "\(url.lastPathComponent): \(missingCount) of \(tracks.count) track(s) point to files that could not be found"
            )
        }

        return tracks
    }

    private func importDirectory(_ url: URL, into result: inout PlaylistImportResult) {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            result.warnings.append("\(url.lastPathComponent): the folder could not be read")
            return
        }

        var playlistURLs: [URL] = []
        var audioURLs: [URL] = []
        var skippedCount = 0
        for case let itemURL as URL in enumerator {
            if SupportedFileTypes.isPlaylist(itemURL) {
                playlistURLs.append(itemURL)
            } else if SupportedFileTypes.isAudio(itemURL) {
                audioURLs.append(itemURL)
            } else {
                skippedCount += 1
            }
        }

        playlistURLs.sort(by: pathSort)
        audioURLs.sort(by: pathSort)

        var tracks: [AudioTrack] = []
        var playlistTrackCount = 0
        var playlistMediaPaths = Set<String>()
        for playlistURL in playlistURLs {
            DebugLog.log("Parsing playlist in directory: \(playlistURL.path)")
            let playlistTracks = parsePlaylist(playlistURL, warnings: &result.warnings)
            playlistTrackCount += playlistTracks.count
            playlistMediaPaths.formUnion(playlistTracks.map { mediaPath(for: $0.url) })
            tracks.append(contentsOf: playlistTracks)
        }

        var importedAudioCount = 0
        var duplicateAudioCount = 0
        for audioURL in audioURLs {
            if playlistMediaPaths.contains(mediaPath(for: audioURL)) {
                duplicateAudioCount += 1
                DebugLog.log("Skipping audio file already covered by playlist: \(audioURL.path)")
                continue
            }

            importedAudioCount += 1
            DebugLog.log("Importing audio file in directory: \(audioURL.path)")
            tracks.append(audioTrack(for: audioURL))
        }

        DebugLog.log(
            "Directory import produced \(tracks.count) track(s): " +
            "\(playlistTrackCount) from \(playlistURLs.count) playlist file(s), " +
            "\(importedAudioCount) imported audio file(s), \(duplicateAudioCount) playlist-covered audio file(s), " +
            "\(skippedCount) skipped item(s)"
        )
        result.tracks.append(contentsOf: tracks)
    }

    private func pathSort(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    private func mediaPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func audioTrack(for url: URL) -> AudioTrack {
        let metadata = FilenameMetadataParser.parse(url)
        let duration = AudioFileDurationProbe.duration(for: url)
        DebugLog.log(
            "Audio filename metadata: file='\(url.lastPathComponent)' " +
            "track=\(display(metadata.trackNumber)) artist='\(metadata.artist ?? "<none>")' " +
            "title='\(metadata.title ?? "<none>")' duration=\(display(duration))"
        )
        return AudioTrack(
            url: url.standardizedFileURL,
            title: metadata.title,
            artist: metadata.artist,
            trackNumber: metadata.trackNumber,
            duration: duration
        )
    }

    private func display(_ number: Int?) -> String {
        guard let number else {
            return "<none>"
        }

        return String(number)
    }

    private func display(_ time: TimeInterval?) -> String {
        guard let time else {
            return "<none>"
        }

        return String(format: "%.2f", time)
    }
}
