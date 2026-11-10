import Foundation

struct XSPFExporter {
    func write(_ tracks: [AudioTrack], to url: URL, title: String) throws {
        let document = documentString(for: tracks, title: title)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try document.write(to: url, atomically: true, encoding: .utf8)
        DebugLog.log("XSPF exporter wrote \(tracks.count) track(s) to \(url.path)")
    }

    func documentString(for tracks: [AudioTrack], title: String) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<playlist version="1" xmlns="http://xspf.org/ns/0/" xmlns:fenglu="urn:fenglu:xspf">"#,
            "  <title>\(escape(title))</title>",
            "  <trackList>"
        ]

        for track in tracks {
            appendTrack(track, to: &lines)
        }

        lines.append("  </trackList>")
        lines.append("</playlist>")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func appendTrack(_ track: AudioTrack, to lines: inout [String]) {
        lines.append("    <track>")
        lines.append("      <location>\(escape(track.url.standardizedFileURL.absoluteString))</location>")
        lines.append("      <title>\(escape(track.title))</title>")

        if let artist = track.artist {
            lines.append("      <creator>\(escape(artist))</creator>")
        }

        if let album = track.album {
            lines.append("      <album>\(escape(album))</album>")
        }

        if let trackNumber = track.trackNumber {
            lines.append("      <trackNum>\(trackNumber)</trackNum>")
        }

        if let duration = PlaylistDuration.sanitized(exportedDuration(for: track)) {
            let milliseconds = Int((duration * 1000).rounded())
            lines.append("      <duration>\(milliseconds)</duration>")
        }

        if track.source == .cue || track.cueStart != nil || track.cueEnd != nil {
            lines.append("      <extension application=\"com.fenglu.player\">")
            if let cueStart = track.cueStart {
                lines.append("        <fenglu:cueStart>\(display(cueStart))</fenglu:cueStart>")
            }
            if let cueEnd = track.cueEnd {
                lines.append("        <fenglu:cueEnd>\(display(cueEnd))</fenglu:cueEnd>")
            }
            lines.append("      </extension>")
        }

        lines.append("    </track>")
    }

    private func exportedDuration(for track: AudioTrack) -> TimeInterval? {
        if let cueStart = track.cueStart, let cueEnd = track.cueEnd, cueEnd > cueStart {
            return cueEnd - cueStart
        }

        return track.duration
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func display(_ time: TimeInterval) -> String {
        String(format: "%.6f", time)
    }
}
