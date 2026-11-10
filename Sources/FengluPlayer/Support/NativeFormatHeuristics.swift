import Foundation

enum NativeFormatHeuristics {
    private static let commonlyNativeExtensions: Set<String> = [
        "aac",
        "aif",
        "aiff",
        "caf",
        "flac",
        "m4a",
        "m4b",
        "mp3",
        "mp4",
        "wav"
    ]

    static func prefersNativeDecoder(url: URL) -> Bool {
        commonlyNativeExtensions.contains(url.pathExtension.localizedLowercase)
    }

    static func prefersNativeDecoder(for track: AudioTrack) -> Bool {
        return prefersNativeDecoder(url: track.url)
    }
}
