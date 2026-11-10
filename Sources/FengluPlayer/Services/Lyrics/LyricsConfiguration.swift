import Foundation

enum LyricsConfiguration {
    static let onlineLookupEnabledKey = "LyricsOnlineLookupEnabled"
    static let sourceListKey = "LyricsSourceList"
    static let sourceListEnvironmentKey = "FENGLU_LYRICS_SOURCES"
    static let configPathEnvironmentKey = "FENGLU_LYRICS_CONFIG"
    static let fontSizeKey = "LyricsFontSize"
    static let alwaysOnTopKey = "LyricsWindowAlwaysOnTop"
    static let opacityKey = "LyricsWindowOpacity"

    static let defaultOnlineLookupEnabled = true
    static let defaultSourceList = [
        "embedded",
        "local",
        "cache",
        "lrclib-exact",
        "lrclib-search",
        "netease",
        "qqmusic",
        "lrcapi",
        "kuwo",
        "kugou",
        "musixmatch",
        "letrasboom",
        "azlyrics",
        "songlyrics",
        "lyricsify",
        "letras",
        "lyricfind",
        "bandcamp",
        "darklyrics",
        "metalarchives",
        "genius"
    ].joined(separator: ",")

    static let defaultFontSize = 14.0
    static let minimumFontSize = 11.0
    static let maximumFontSize = 32.0

    static let defaultOpacity = 1.0
    static let minimumOpacity = 0.35
    static let maximumOpacity = 1.0

    // Earlier caches may contain lyrics accepted by the looser title matching,
    // and use cache keys that collide for sparsely tagged files.
    static let cacheDirectoryName = "Lyrics-v17"
    static let configDirectoryName = "FengluPlayer"
    static let configFileName = "lyrics.conf"
    static let aliasConfigFileSuffix = "lyrics-aliases.json"
}
