# Fenglu Player

Fenglu Player is a macOS audio player for local files, CUE sheets, and
playlists, with a dense playlist table, compact transport controls, and a
synchronized lyrics window. It requires macOS 15.7 or later.

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): targets, playback routing, the
  FFmpeg backend, and the invariants the code relies on.
- [docs/LYRICS_MATCHING.md](docs/LYRICS_MATCHING.md): the rules an online lyric
  result must pass before it is shown or saved.

## Supported Formats

| Kind | Extensions | Decoder |
|---|---|---|
| Native audio | `aac` `aif` `aiff` `caf` `flac` `m4a` `m4b` `mp3` `wav` | AVFoundation first, FFmpeg if that fails |
| FFmpeg audio | `alac` `ape` `dff` `dsf` `oga` `ogg` `opus` `wv` | FFmpeg |
| Playlists | `cue` `m3u` `m3u8` `xspf` (and the common misspelling `xsfp`) | n/a |

Files with more than two channels play on the FFmpeg route. Playlists can be
exported as XSPF, including CUE track ranges, and imported again.

Playlist text may be UTF-8, UTF-16, or a legacy encoding: GBK/GB18030,
Shift-JIS, Big5, and EUC-KR are detected, so Chinese, Japanese, and Korean CUE
and M3U files import with the right titles. CUE sheets in the EAC "non-compliant" layout
(`FILE` after `TRACK`) are supported, and a CUE that names `album.wav` still
resolves when only `album.flac` (or another supported extension) exists.

## Build And Run

Requirements: Xcode command line tools with Swift 6.0 or later, `pkg-config`,
and FFmpeg development libraries.

```bash
brew install ffmpeg pkg-config
./script/build_and_run.sh
```

The script builds with SwiftPM, stages `dist/FengluPlayer.app`, copies the
non-system dylibs the binary needs into `Contents/Frameworks`, signs the bundle
ad hoc, and launches it. A running copy is stopped only after the build
succeeds. Any failure to rewrite a load path or sign the bundle stops the build.

```text
./script/build_and_run.sh [MODE] [--release] [--ffmpeg-dir PATH]
                          [--lyrics-sources LIST] [--lyrics-config PATH]
```

| Mode (at most one) | Effect |
|---|---|
| `run` (default) | Launch the staged app. |
| `--console` | Run the binary from the terminal with debug logs attached. |
| `--debug` | Run under `lldb`. |
| `--logs` | Launch, then stream unified logs for the process. |
| `--telemetry` | Launch, then stream logs for the `com.fenglu.player` subsystem. |
| `--verify` | Launch and check that the process is running. |

`--release` builds with `-c release`. `FENGLU_APP_VERSION` sets the bundle's
version string (default `0.1.0`).

### FFmpeg Linking

By default SwiftPM finds FFmpeg through `pkg-config` and links it dynamically.
To link a static FFmpeg, point at a folder containing `include/` and `lib/`.
There is no built-in default path; it must be given explicitly:

```bash
./script/build_and_run.sh --ffmpeg-dir /path/to/ffmpeg
FENGLU_FFMPEG_DIR=/path/to/ffmpeg swift build      # same, without the script
```

Static mode links `libavformat.a`, `libavcodec.a`, `libswresample.a`, and
`libavutil.a`, plus zlib, bzip2, iconv, AudioToolbox, CoreFoundation, CoreMedia,
CoreVideo, Security, and VideoToolbox. `FENGLU_FFMPEG_INCLUDE_DIR` and
`FENGLU_FFMPEG_LIB_DIR` override the derived paths, `FENGLU_FFMPEG_LIBS` replaces
the library list (comma, semicolon, or space separated), and
`FENGLU_FFMPEG_EXTRA_LINKER_FLAGS` adds semicolon-separated linker arguments for
codec archives your FFmpeg build needs.

### App Icon

`Resources/AppIcon/FengluPlayer.icns` is committed and copied into the bundle.
`script/generate_app_icon.py [SOURCE_IMAGE]` regenerates it from a sketch PNG;
it needs Python 3 with `numpy` and `pillow`, and the original source image is
not tracked, so pass your own.

## Using The App

| Action | Shortcut |
|---|---|
| File > Open… (imports and plays the first imported track) | Command-O |
| File > Save Playlist As… (XSPF) | Command-Shift-S |
| File > Clear All Tracks | n/a |
| Window > Show Lyrics | Command-Shift-L |
| Play / Pause | Space |
| Previous / Next track | Command-Left / Command-Right |
| Remove the selected track | Delete |

Space, Delete, and the Command-arrow keys are ignored while you type in the
search field. The toolbar Import button adds rows without starting playback, and
Finder's Services menu offers **Add to Fenglu Player Playlist** for files and
folders. Right-clicking a row and choosing Remove removes that row. Next,
Previous, and auto-advance follow the visible order, so an active filter or
search limits what plays next. The seek slider seeks when you release it.

Importing something that is already in the playlist does not add a second row.
Import problems (an unreadable playlist, missing media files, unsupported
files) are listed in one alert, and everything that could be read is still
added. The playlist is not saved between launches; use Save Playlist As.

Debug logging is on in debug builds only. In a release build, enable it with
`FENGLU_DEBUG_LOG=1` or
`defaults write com.fenglu.player FengluDebugLog -bool YES`.

The transport bar has an output device picker. **System Default** follows the
system default device, including when a device is disconnected; choosing a
device pins playback to it. Closing the last window quits the app and stops
playback.

The lyrics window has an **Online** toggle, font size, opacity, and Always on
Top controls. LRC lyrics scroll with playback; plain text is shown statically.
`[offset:]` tags follow the common convention (positive values show lyrics
earlier).

## Lyrics Configuration

Sources are tried in order: `embedded` (recognized, not implemented), `local`
sidecar files, the `cache`, then online providers queried in parallel under one
overall deadline. If nothing usable is found the window shows the track's
metadata.

The built-in order is `embedded`, `local`, `cache`, `lrclib-exact`,
`lrclib-search`, `netease`, `qqmusic`, `lrcapi`, `kuwo`, `kugou`, `musixmatch`,
`letrasboom`, `azlyrics`, `songlyrics`, `lyricsify`, `letras`, `lyricfind`,
`bandcamp`, `darklyrics`, `metalarchives`, `genius`. `shazam` is opt-in and must
be named explicitly. `lrclib` expands to both LRCLIB sources, and `default`
expands to the built-in list, so `default,shazam` adds Shazam to it.

The source list comes from the first of these that is set:

1. The `FENGLU_LYRICS_SOURCES` environment variable (`--lyrics-sources`).
2. A config file: the path in `FENGLU_LYRICS_CONFIG` (`--lyrics-config`) if
   set, otherwise `~/Library/Application Support/FengluPlayer/lyrics.conf`, then
   `~/.config/fenglu/lyrics.conf`.
3. The saved `LyricsSourceList` user default, preserved exactly as saved.
4. The built-in list.

```text
# lyrics.conf: lines starting with # or // are comments
sources=local,cache,lrclib,letras
```

The key may also be written `source`, `sourcelist`, or `lyricssources`, and a
line with no key is read as a source list. Use `sources=default` to follow the
built-in list instead of a saved one.

`build_and_run.sh` passes the lyrics and token environment variables to the app
in every mode. An app started from Finder or the Dock does not see your shell
environment, so use the config file there.

### Tokens

Musixmatch does nothing without a user token; it is skipped entirely. Genius
uses its API with a token and falls back to reading genius.com without one.
Each token is read from the first of:

| Provider | User default | Environment variables |
|---|---|---|
| Musixmatch | `VLCLyricsMusixmatchUserToken` | `FENGLU_MUSIXMATCH_USER_TOKEN`, then `MUSIXMATCH_USER_TOKEN` |
| Genius | `VLCLyricsGeniusAccessToken` | `FENGLU_GENIUS_ACCESS_TOKEN`, then `GENIUS_ACCESS_TOKEN` |

The `VLCLyrics` prefix and "VLC-style" log lines are historical: the source list
was first modelled on a lyrics extension for VLC. Set a default with
`defaults write com.fenglu.player VLCLyricsGeniusAccessToken <token>`.

### Aliases

When a track's tags differ from the name lyric sites use, list the equivalent
names in a JSON file beside the media, named after the playlist or CUE:
`CD4.cue` uses `CD4.lyrics-aliases.json`, and a standalone file uses
`<audio-file-name>.lyrics-aliases.json`.

```json
{
  "aliases": { "Velvet Lantern": ["amber meadow"] },
  "tracks": {
    "13": { "aliases": { "Hidden Marigold": ["lunar pebble", "bright fern"] } }
  },
  "trackAliases": { "7": { "Copper Moon": ["paper valley"] } }
}
```

Top-level `aliases` apply to every track. `tracks` and its shorthand
`trackAliases` are keyed by track number, override a top-level entry with the
same key, and also count as aliases of that CUE track's title. An `aliasGroups`
array, at the top level or inside a track, lists names that are all equivalent.
Aliases are explicit: Chinese text is never matched to a transliteration
automatically.

## What This App Writes And Contacts

**Files written**

- **Lyrics sidecars**, beside the media file. A `.lrc` is created only for a
  synchronized result, only when no file exists at that path, and never for a
  lookup you cancelled by skipping the track. Existing files are never
  overwritten. A standalone file uses its own base name (`Song.flac` →
  `Song.lrc`). A CUE track uses `Artist - Title.lrc`, or
  `<media name> - NN Title.lrc` when it has no artist; the bare media name is
  never used for CUE tracks.
- **Lyrics cache**, `~/Library/Caches/Lyrics-v17`, synchronized lyrics only.
  Older `Lyrics-v*` folders are ignored and can be deleted.
- **Playlists**, only where you choose in Save Playlist As.

Local lyrics take precedence, so a wrong sidecar must be renamed or removed
before a new online lookup can replace it.

**Network**

With the lyrics window open and Online enabled, each track's title, artist, and
album are sent to the configured providers. With the built-in list these are
lrclib.net, music.163.com, c.y.qq.com, api.lrc.cx, search.kuwo.cn, m.kuwo.cn,
kugou.com (krcs, lyrics2), letrasboom.com, azlyrics.com, songlyrics.com,
lyricsify.com, letras.com, lyrics.lyricfind.com, bandcamp.com,
darklyrics.com, metal-archives.com, and genius.com. Opt-in sources add
itunes.apple.com and shazam.com (Shazam), apic-desktop.musixmatch.com
(Musixmatch token), and api.genius.com (Genius token). Lookups are made by the
lyrics window, for the track it is showing.

To stop online lookups, turn off **Online** in the lyrics window, or use a
source list with only `local,cache`.

**Logs** go to unified logging (`com.fenglu.player`) and standard error. They
include file paths and track titles.

## Testing

```bash
./script/test_lyrics.sh            # arguments are passed to `swift test`
```

The script puts the FFmpeg runtime libraries on the loader path: the directory
in `FENGLU_TEST_LIBRARY_DIR` if set, else the staged app's
`Contents/Frameworks`, else the library directory `pkg-config` reports. The
tests are offline and do not contact lyric providers.

## License

Fenglu Player's source code is MIT licensed; see [LICENSE](LICENSE).

No FFmpeg binaries are in this repository, but the staged app contains whatever
FFmpeg your machine provides, and that decides how the app may be shared.
Homebrew's `ffmpeg` is built with GPL components such as x264 and x265, so an
app built against it is **not** an LGPL build, and a build with
`--enable-nonfree` may not be redistributed at all. The build script inspects
the staged binaries, prints a warning in those cases, and records the result in
`Contents/Resources/FFMPEG_BUILD_INFO.txt`. Codec libraries copied into
`Contents/Frameworks` carry their own licences, which the bundled notices do
not reproduce. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the
LGPL-only FFmpeg configuration and the SwiftSoup licence. This is an
engineering description, not legal advice.
