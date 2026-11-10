import Foundation

enum DecoderRoute: String, Sendable {
    case idle
    case native
    case ffmpeg

    var title: String {
        switch self {
        case .idle:
            "Ready"
        case .native:
            "AVFoundation"
        case .ffmpeg:
            "FFmpeg"
        }
    }

    var systemImage: String {
        switch self {
        case .idle:
            "circle"
        case .native:
            "apple.logo"
        case .ffmpeg:
            "cpu"
        }
    }
}

enum PlaybackState: Equatable {
    case stopped
    case loading
    case playing
    case paused
    case failed(String)

    var isPlaying: Bool {
        if case .playing = self {
            return true
        }
        return false
    }

    var title: String {
        switch self {
        case .stopped:
            "Stopped"
        case .loading:
            "Loading"
        case .playing:
            "Playing"
        case .paused:
            "Paused"
        case .failed:
            "Error"
        }
    }
}
