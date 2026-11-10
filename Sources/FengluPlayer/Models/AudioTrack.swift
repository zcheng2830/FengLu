import Foundation

struct AudioTrack: Identifiable, Hashable, Sendable {
    let id: UUID
    var url: URL
    var title: String
    var artist: String?
    var album: String?
    var trackNumber: Int?
    var duration: TimeInterval?
    var cueStart: TimeInterval?
    var cueEnd: TimeInterval?
    var source: TrackSource
    var playlistName: String?

    init(
        id: UUID = UUID(),
        url: URL,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        trackNumber: Int? = nil,
        duration: TimeInterval? = nil,
        cueStart: TimeInterval? = nil,
        cueEnd: TimeInterval? = nil,
        source: TrackSource = .file,
        playlistName: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title?.nonEmpty ?? url.deletingPathExtension().lastPathComponent
        self.artist = artist?.nonEmpty
        self.album = album?.nonEmpty
        self.trackNumber = trackNumber
        self.duration = duration
        self.cueStart = cueStart
        self.cueEnd = cueEnd
        self.source = source
        self.playlistName = playlistName?.nonEmpty
    }

    var fileName: String {
        url.lastPathComponent
    }

    var formatLabel: String {
        let pathExtension = url.pathExtension.uppercased()
        return pathExtension.isEmpty ? "STREAM" : pathExtension
    }

    var subtitle: String {
        [artist, album].compactMap(\.self).joined(separator: " - ")
    }

    var displayDuration: String {
        if let cueStart, let cueEnd, cueEnd > cueStart {
            return TimeFormatter.duration(cueEnd - cueStart)
        }

        if let duration {
            return TimeFormatter.duration(duration)
        }

        return "--:--"
    }

    var startTimeForPlayback: TimeInterval {
        cueStart ?? 0
    }

    var routePreferenceLabel: String {
        isFFmpegLikely ? "FFmpeg likely" : "Native first"
    }

    var isFFmpegLikely: Bool {
        !NativeFormatHeuristics.prefersNativeDecoder(for: self)
    }
}

enum TrackSource: String, CaseIterable, Identifiable, Sendable {
    case file
    case playlist
    case cue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .file:
            "Files"
        case .playlist:
            "Playlists"
        case .cue:
            "Cue Sheets"
        }
    }

    var systemImage: String {
        switch self {
        case .file:
            "music.note"
        case .playlist:
            "list.bullet.rectangle"
        case .cue:
            "text.badge.checkmark"
        }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case files
    case playlists
    case cues
    case ffmpegLikely

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "All Tracks"
        case .files:
            "Audio Files"
        case .playlists:
            "Playlist Items"
        case .cues:
            "Cue Tracks"
        case .ffmpegLikely:
            "FFmpeg Route"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            "music.quarternote.3"
        case .files:
            "waveform"
        case .playlists:
            "list.bullet"
        case .cues:
            "rectangle.stack.badge.play"
        case .ffmpegLikely:
            "shippingbox"
        }
    }
}
