import Foundation
import UniformTypeIdentifiers

enum SupportedFileTypes {
    static let audioExtensions: Set<String> = [
        "aac",
        "aif",
        "aiff",
        "alac",
        "ape",
        "caf",
        "dff",
        "dsf",
        "flac",
        "m4a",
        "m4b",
        "mp3",
        "oga",
        "ogg",
        "opus",
        "wav",
        "wv"
    ]

    static let playlistExtensions: Set<String> = [
        "cue",
        "m3u",
        "m3u8",
        "xspf",
        "xsfp"
    ]

    static var importableExtensions: Set<String> {
        audioExtensions.union(playlistExtensions)
    }

    static var importableTypes: [UTType] {
        let audioTypes = audioExtensions.compactMap { UTType(filenameExtension: $0) }
        let playlistTypes = playlistExtensions.compactMap { UTType(filenameExtension: $0) }
        return Array(Set([.audio, .folder] + audioTypes + playlistTypes))
    }

    static func isAudio(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.localizedLowercase)
    }

    static func isPlaylist(_ url: URL) -> Bool {
        playlistExtensions.contains(url.pathExtension.localizedLowercase)
    }
}
