import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

struct XSPFParser {
    var environment: PlaylistParsingEnvironment = .live

    func parse(_ url: URL) throws -> [AudioTrack] {
        let data = try Data(contentsOf: url)
        DebugLog.log("XSPF parser loaded \(data.count) byte(s) from \(url.path)")
        return try parse(
            data: data,
            baseURL: url.deletingLastPathComponent(),
            playlistName: url.deletingPathExtension().lastPathComponent
        )
    }

    /// Pure parse step: no file is read here; media lookups go through `environment`.
    func parse(data: Data, baseURL: URL, playlistName: String? = nil) throws -> [AudioTrack] {
        let delegate = XSPFDelegate(baseURL: baseURL, playlistName: playlistName, environment: environment)
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse() else {
            DebugLog.log("XSPF parser failed at line \(parser.lineNumber), column \(parser.columnNumber): \(parser.parserError?.localizedDescription ?? "<unknown error>")")
            throw PlaylistParseError.invalidXSPF(line: parser.lineNumber > 0 ? parser.lineNumber : nil)
        }

        DebugLog.log("XSPF parser summary: \(delegate.trackElementCount) track element(s), \(delegate.tracks.count) imported track(s), \(delegate.skippedTrackCount) skipped track(s)")
        return delegate.tracks
    }
}

private final class XSPFDelegate: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private let playlistName: String?
    private let environment: PlaylistParsingEnvironment
    private var currentElement = ""
    private var currentTrack: XSPFTrack?
    private var text = ""
    private(set) var tracks: [AudioTrack] = []
    private(set) var trackElementCount = 0
    private(set) var skippedTrackCount = 0

    init(baseURL: URL, playlistName: String?, environment: PlaylistParsingEnvironment) {
        self.baseURL = baseURL
        self.playlistName = playlistName
        self.environment = environment
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        text = ""

        if elementName == "track" {
            trackElementCount += 1
            currentTrack = XSPFTrack()
            DebugLog.log("XSPF started track element \(trackElementCount)")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            text = ""
        }

        guard var track = currentTrack else {
            return
        }

        switch elementName {
        case "location":
            track.location = value.nonEmpty
            DebugLog.log("XSPF track \(trackElementCount) location=\(track.location ?? "<missing>")")
        case "title":
            track.title = value.nonEmpty
            DebugLog.log("XSPF track \(trackElementCount) title=\(track.title ?? "<none>")")
        case "creator":
            track.creator = value.nonEmpty
            DebugLog.log("XSPF track \(trackElementCount) creator=\(track.creator ?? "<none>")")
        case "album":
            track.album = value.nonEmpty
            DebugLog.log("XSPF track \(trackElementCount) album=\(track.album ?? "<none>")")
        case "duration":
            track.duration = PlaylistDuration.sanitized(TimeInterval(value).map { $0 / 1000 })
            DebugLog.log("XSPF track \(trackElementCount) duration=\(display(track.duration))")
        case "trackNum":
            track.trackNumber = Int(value)
            DebugLog.log("XSPF track \(trackElementCount) number=\(display(track.trackNumber))")
        case "cueStart", "fenglu:cueStart":
            track.cueStart = PlaylistDuration.sanitizedPosition(TimeInterval(value))
            DebugLog.log("XSPF track \(trackElementCount) cueStart=\(display(track.cueStart))")
        case "cueEnd", "fenglu:cueEnd":
            track.cueEnd = PlaylistDuration.sanitizedPosition(TimeInterval(value))
            DebugLog.log("XSPF track \(trackElementCount) cueEnd=\(display(track.cueEnd))")
        case "track":
            if let location = track.location {
                let resolvedURL = resolve(location)
                // For cue ranges the exported <duration> is the sub-track length, while
                // AudioTrack.duration means the whole media file (as CUE import sets it).
                // Using the sub-track length there would make playback at an absolute
                // position past it look like end-of-track, so probe the file instead.
                let hasCueRange = track.cueStart != nil || track.cueEnd != nil
                let duration = hasCueRange
                    ? PlaylistDuration.sanitized(environment.duration(resolvedURL))
                    : track.duration ?? PlaylistDuration.sanitized(environment.duration(resolvedURL))
                DebugLog.log(
                    "XSPF track \(trackElementCount) resolved \(location) -> \(resolvedURL.path) " +
                    "duration=\(display(duration))"
                )
                let source: TrackSource = track.cueStart != nil || track.cueEnd != nil ? .cue : .playlist
                tracks.append(AudioTrack(
                    url: resolvedURL,
                    title: track.title,
                    artist: track.creator,
                    album: track.album,
                    trackNumber: track.trackNumber,
                    duration: duration,
                    cueStart: track.cueStart,
                    cueEnd: track.cueEnd,
                    source: source,
                    playlistName: playlistName
                ))
            } else {
                skippedTrackCount += 1
                DebugLog.log("XSPF skipped track \(trackElementCount) because it has no location")
            }
            currentTrack = nil
            return
        default:
            break
        }

        currentTrack = track
    }

    private func resolve(_ value: String) -> URL {
        // XSPF locations are URIs, so relative entries are percent-encoded.
        PlaylistPathResolver.resolve(
            value,
            relativeTo: baseURL,
            isURI: true,
            fileExists: environment.fileExists
        )
    }

    private func display(_ time: TimeInterval?) -> String {
        guard let time else {
            return "<none>"
        }

        return String(time)
    }

    private func display(_ number: Int?) -> String {
        guard let number else {
            return "<none>"
        }

        return String(number)
    }

    private struct XSPFTrack {
        var location: String?
        var title: String?
        var creator: String?
        var album: String?
        var duration: TimeInterval?
        var trackNumber: Int?
        var cueStart: TimeInterval?
        var cueEnd: TimeInterval?
    }
}
