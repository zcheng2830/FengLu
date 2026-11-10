import Foundation

struct PlaylistParsingService {
    func parsePlaylist(_ url: URL) throws -> [AudioTrack] {
        DebugLog.log("Playlist parser dispatch for .\(url.pathExtension.localizedLowercase): \(url.path)")
        switch url.pathExtension.localizedLowercase {
        case "cue":
            let tracks = try CueSheetParser().parse(url)
            DebugLog.log("Cue parser produced \(tracks.count) track(s)")
            return tracks
        case "m3u", "m3u8":
            let tracks = try M3UParser().parse(url)
            DebugLog.log("M3U parser produced \(tracks.count) track(s)")
            return tracks
        case "xspf", "xsfp":
            let tracks = try XSPFParser().parse(url)
            DebugLog.log("XSPF parser produced \(tracks.count) track(s)")
            return tracks
        default:
            DebugLog.log("No playlist parser for: \(url.path)")
            return []
        }
    }
}
