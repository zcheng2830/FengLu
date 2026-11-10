#!/usr/bin/env bash
set -euo pipefail

MODE=""
BUILD_CONFIGURATION="debug"
FFMPEG_DIR="${FENGLU_FFMPEG_DIR:-}"
LYRICS_SOURCES="${FENGLU_LYRICS_SOURCES:-}"
LYRICS_CONFIG="${FENGLU_LYRICS_CONFIG:-}"
APP_NAME="FengluPlayer"
BUNDLE_ID="com.fenglu.player"
# Keep in sync with the platforms entry in Package.swift.
MIN_SYSTEM_VERSION="15.7"
APP_VERSION="${FENGLU_APP_VERSION:-0.1.0}"
COPYRIGHT_NOTICE="Copyright (c) 2026 FengluPlayer contributors. MIT License."

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Resources/AppIcon/FengluPlayer.icns"
APP_ICON_NAME="FengluPlayer"
APP_ICON_FILE="$APP_ICON_NAME.icns"

# Environment variables forwarded to the app in every launch mode. The modes
# that launch through /usr/bin/open pass them with `open --env`, because open
# does not hand the calling shell's environment to the application.
FORWARDED_ENVIRONMENT_NAMES=(
  FENGLU_LYRICS_SOURCES
  FENGLU_LYRICS_CONFIG
  FENGLU_MUSIXMATCH_USER_TOKEN
  FENGLU_GENIUS_ACCESS_TOKEN
  MUSIXMATCH_USER_TOKEN
  GENIUS_ACCESS_TOKEN
)

usage() {
  cat <<USAGE >&2
usage: $0 [MODE] [--release] [--ffmpeg-dir PATH] [--lyrics-sources LIST] [--lyrics-config PATH]

Modes (at most one; default: run):
  run                     Build, stage dist/$APP_NAME.app, and launch it.
  --console               Launch the binary from this terminal with logs attached.
  --debug                 Launch under lldb.
  --logs                  Launch, then stream unified logs for the process.
  --telemetry             Launch, then stream unified logs for the $BUNDLE_ID subsystem.
  --verify                Launch and check that the process is running.

Options:
  --release               Build with -c release instead of the default debug build.
  --ffmpeg-dir PATH       Link FFmpeg statically from PATH/include and PATH/lib/lib*.a.
                          Same as FENGLU_FFMPEG_DIR. Without it, FFmpeg is found
                          through pkg-config and linked dynamically.
  --lyrics-sources LIST   Override lyrics source order, for example local,cache,lrclib,letras.
  --lyrics-config PATH    Read lyrics source configuration from PATH.

Environment:
  FENGLU_APP_VERSION      CFBundleShortVersionString for the staged app (default 0.1.0).
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

# Run a tool whose normal output is noise (signature-invalidation warnings,
# "replacing existing signature"), but show everything it printed if it fails.
run_quietly() {
  local output
  if ! output="$("$@" 2>&1)"; then
    [[ -n "$output" ]] && printf '%s\n' "$output" >&2
    return 1
  fi
}

set_mode() {
  if [[ -n "$MODE" ]]; then
    echo "error: more than one mode given ('$MODE' and '$1')" >&2
    usage
    exit 2
  fi
  MODE="$1"
}

while (($#)); do
  case "$1" in
    run|--console|console|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
      set_mode "$1"
      shift
      ;;
    --release)
      BUILD_CONFIGURATION="release"
      shift
      ;;
    --ffmpeg-dir)
      if [[ $# -lt 2 ]]; then
        usage
        exit 2
      fi

      FFMPEG_DIR="$2"
      shift 2
      ;;
    --ffmpeg-dir=*)
      FFMPEG_DIR="${1#*=}"
      shift
      ;;
    --lyrics-sources)
      if [[ $# -lt 2 ]]; then
        usage
        exit 2
      fi

      LYRICS_SOURCES="$2"
      shift 2
      ;;
    --lyrics-sources=*)
      LYRICS_SOURCES="${1#*=}"
      shift
      ;;
    --lyrics-config)
      if [[ $# -lt 2 ]]; then
        usage
        exit 2
      fi

      LYRICS_CONFIG="$2"
      shift 2
      ;;
    --lyrics-config=*)
      LYRICS_CONFIG="${1#*=}"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

MODE="${MODE:-run}"

if [[ -n "$FFMPEG_DIR" ]]; then
  [[ -d "$FFMPEG_DIR/include" && -d "$FFMPEG_DIR/lib" ]] ||
    fail "--ffmpeg-dir / FENGLU_FFMPEG_DIR must contain include/ and lib/: $FFMPEG_DIR"
  # Absolute path: SwiftPM evaluates the manifest from the package root.
  FFMPEG_DIR="$(cd "$FFMPEG_DIR" && pwd)"
  export FENGLU_FFMPEG_DIR="$FFMPEG_DIR"
  echo "Using static FFmpeg from $FENGLU_FFMPEG_DIR" >&2
fi

if [[ -n "$LYRICS_SOURCES" ]]; then
  export FENGLU_LYRICS_SOURCES="$LYRICS_SOURCES"
  echo "Using lyrics sources from FENGLU_LYRICS_SOURCES: $FENGLU_LYRICS_SOURCES" >&2
fi

if [[ -n "$LYRICS_CONFIG" ]]; then
  # Absolute path: an app launched through open does not share this directory.
  case "$LYRICS_CONFIG" in
    /*|"~"*) ;;
    *) LYRICS_CONFIG="$PWD/$LYRICS_CONFIG" ;;
  esac
  export FENGLU_LYRICS_CONFIG="$LYRICS_CONFIG"
  echo "Using lyrics config from FENGLU_LYRICS_CONFIG: $FENGLU_LYRICS_CONFIG" >&2
fi

cd "$ROOT_DIR"

swift build -c "$BUILD_CONFIGURATION"
BUILD_DIR="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
[[ -x "$BUILD_BINARY" ]] || fail "build product not found at $BUILD_BINARY"

# Stop a running copy only now that the build has succeeded, so a failed build
# never interrupts playback.
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

BUNDLE_VERSION="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || true)"
BUNDLE_VERSION="${BUNDLE_VERSION:-1}"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ROOT_DIR/LICENSE" "$APP_RESOURCES/LICENSE"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_RESOURCES/THIRD_PARTY_NOTICES.md"
chmod +x "$APP_BINARY"

# No NSAppTransportSecurity exception is declared: every network request the
# app makes is expected to use https. A plaintext http endpoint will be blocked
# by App Transport Security in the packaged app.
cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUNDLE_VERSION</string>
  <key>NSHumanReadableCopyright</key>
  <string>$COPYRIGHT_NOTICE</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Fenglu Audio Files</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.audio</string>
        <string>public.aac-audio</string>
        <string>public.aifc-audio</string>
        <string>public.aiff-audio</string>
        <string>public.m3u-playlist</string>
        <string>public.mp3</string>
        <string>public.mpeg-4-audio</string>
        <string>public.wav</string>
        <string>com.apple.coreaudio-format</string>
        <string>org.xiph.flac</string>
        <string>org.xiph.ogg</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Fenglu Supported Audio and Playlist Extensions</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>aac</string>
        <string>aif</string>
        <string>aiff</string>
        <string>alac</string>
        <string>ape</string>
        <string>caf</string>
        <string>cue</string>
        <string>dff</string>
        <string>dsf</string>
        <string>flac</string>
        <string>m3u</string>
        <string>m3u8</string>
        <string>m4a</string>
        <string>m4b</string>
        <string>mp3</string>
        <string>oga</string>
        <string>ogg</string>
        <string>opus</string>
        <string>wav</string>
        <string>wv</string>
        <string>xspf</string>
        <string>xsfp</string>
      </array>
    </dict>
  </array>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>LSSupportsOpeningDocumentsInPlace</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>
      <dict>
        <key>default</key>
        <string>Add to Fenglu Player Playlist</string>
      </dict>
      <key>NSMessage</key>
      <string>addToPlaylist</string>
      <key>NSPortName</key>
      <string>$APP_NAME</string>
      <key>NSServiceDescription</key>
      <string>Add selected audio, playlist, CUE, or folder items to Fenglu Player's playlist.</string>
      <key>NSRequiredContext</key>
      <dict/>
      <key>NSSendFileTypes</key>
      <array>
        <string>public.data</string>
        <string>public.folder</string>
      </array>
      <key>NSSendTypes</key>
      <array>
        <string>NSFilenamesPboardType</string>
        <string>public.file-url</string>
      </array>
    </dict>
  </array>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

stage_app_icon() {
  if [[ -f "$APP_ICON_SOURCE" ]]; then
    cp "$APP_ICON_SOURCE" "$APP_RESOURCES/$APP_ICON_FILE"
    echo "Using app icon $APP_ICON_SOURCE" >&2
  else
    echo "warning: app icon not found at $APP_ICON_SOURCE" >&2
  fi
}

stage_app_icon

stage_swiftpm_resources() {
  local bundle

  shopt -s nullglob
  for bundle in "$BUILD_DIR"/*.bundle "$BUILD_DIR"/*.resources; do
    case "$(basename "$bundle")" in
      *Tests.bundle|*Tests.resources|*PackageTests*)
        # Left behind in the same directory by `swift test`; fixtures only.
        echo "Skipping test-only resources $(basename "$bundle")" >&2
        continue
        ;;
    esac
    cp -R "$bundle" "$APP_RESOURCES/"
    echo "Using SwiftPM resources $(basename "$bundle")" >&2
  done
  shopt -u nullglob
}

stage_swiftpm_resources

declare -a DYLIB_SEARCH_DIRS
DYLIB_SEARCH_DIR_COUNT=0

append_dylib_search_dir() {
  local directory="$1"
  [[ -n "$directory" && -d "$directory" ]] || return 0

  local existing
  if ((DYLIB_SEARCH_DIR_COUNT > 0)); then
    for existing in "${DYLIB_SEARCH_DIRS[@]}"; do
      [[ "$existing" == "$directory" ]] && return 0
    done
  fi

  DYLIB_SEARCH_DIRS[$DYLIB_SEARCH_DIR_COUNT]="$directory"
  DYLIB_SEARCH_DIR_COUNT=$((DYLIB_SEARCH_DIR_COUNT + 1))
}

configure_dylib_search_dirs() {
  if [[ -n "${FENGLU_FFMPEG_LIB_DIR:-}" ]]; then
    append_dylib_search_dir "$FENGLU_FFMPEG_LIB_DIR"
  fi
  if [[ -n "${FENGLU_FFMPEG_DIR:-}" ]]; then
    append_dylib_search_dir "$FENGLU_FFMPEG_DIR/lib"
  fi

  if command -v pkg-config >/dev/null 2>&1; then
    append_dylib_search_dir "$(pkg-config --variable=libdir libavformat 2>/dev/null || true)"
  fi

  if command -v brew >/dev/null 2>&1; then
    local brew_prefix
    brew_prefix="$(brew --prefix 2>/dev/null || true)"
    if [[ -n "$brew_prefix" ]]; then
      append_dylib_search_dir "$brew_prefix/lib"
    fi
  fi

  append_dylib_search_dir /opt/homebrew/lib
  append_dylib_search_dir /usr/local/lib
}

# The architecture the staged app runs as; fallback dylibs must contain it.
APP_ARCHITECTURE="$(lipo -archs "$APP_BINARY" 2>/dev/null | awk '{print $1}' || true)"
APP_ARCHITECTURE="${APP_ARCHITECTURE:-$(uname -m)}"

dylib_matches_app_architecture() {
  local archs
  archs="$(lipo -archs "$1" 2>/dev/null || true)"
  # lipo unavailable or unreadable file: do not reject on missing evidence.
  [[ -z "$archs" ]] && return 0
  [[ " $archs " == *" $APP_ARCHITECTURE "* ]]
}

is_system_dependency() {
  local dependency="$1"
  case "$dependency" in
    /System/*|/usr/lib/*)
      return 0
      ;;
    @rpath/libswift*|@rpath/libc++*|@rpath/libobjc*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

find_dylib_by_name() {
  local name="$1"
  local directory

  if ((DYLIB_SEARCH_DIR_COUNT > 0)); then
    for directory in "${DYLIB_SEARCH_DIRS[@]}"; do
      if [[ -f "$directory/$name" ]]; then
        if dylib_matches_app_architecture "$directory/$name"; then
          printf '%s\n' "$directory/$name"
          return 0
        fi
        echo "note: skipping $directory/$name (does not contain $APP_ARCHITECTURE)" >&2
      fi
    done
  fi

  local candidate
  while IFS= read -r candidate; do
    if dylib_matches_app_architecture "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    echo "note: skipping $candidate (does not contain $APP_ARCHITECTURE)" >&2
  done < <(find /opt/homebrew /usr/local -path "*/lib/$name" -type f -print 2>/dev/null || true)
}

resolve_dylib_dependency() {
  local dependency="$1"
  local loader="$2"
  local loader_directory
  local candidate

  loader_directory="$(cd "$(dirname "$loader")" && pwd)"

  case "$dependency" in
    @loader_path/*)
      candidate="$loader_directory/${dependency#@loader_path/}"
      [[ -f "$candidate" ]] && printf '%s\n' "$candidate"
      return 0
      ;;
    @executable_path/*)
      candidate="$APP_MACOS/${dependency#@executable_path/}"
      [[ -f "$candidate" ]] && printf '%s\n' "$candidate"
      return 0
      ;;
    @rpath/*)
      candidate="$APP_FRAMEWORKS/${dependency#@rpath/}"
      if [[ -f "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      find_dylib_by_name "$(basename "$dependency")"
      return 0
      ;;
    /*)
      if [[ -f "$dependency" ]]; then
        printf '%s\n' "$dependency"
        return 0
      fi
      find_dylib_by_name "$(basename "$dependency")"
      return 0
      ;;
    *)
      candidate="$loader_directory/$dependency"
      if [[ -f "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      find_dylib_by_name "$dependency"
      return 0
      ;;
  esac
}

list_dylib_dependencies() {
  local target="$1"

  otool -L "$target" | sed '
    1d
    s/^[[:space:]]*//
    s/[[:space:]]*(compatibility version.*$//
    s/[[:space:]]*(current version.*$//
    /^$/d
  '
}

sign_app_bundle() {
  command -v codesign >/dev/null 2>&1 ||
    fail "codesign not found; an unsigned app is killed at launch on Apple silicon"

  local dylib
  while IFS= read -r dylib; do
    run_quietly codesign --force --sign - "$dylib" ||
      fail "ad-hoc signing failed for $dylib"
  done < <(find "$APP_FRAMEWORKS" -type f -name "*.dylib" -print)

  run_quietly codesign --force --deep --sign - "$APP_BUNDLE" ||
    fail "ad-hoc signing failed for $APP_BUNDLE"
  run_quietly codesign --verify --deep --strict "$APP_BUNDLE" ||
    fail "signature verification failed for $APP_BUNDLE"
}

# Adding an rpath that is already present is an error for install_name_tool,
# so check first instead of ignoring every failure.
add_rpath_if_missing() {
  local rpath="$1"
  local target="$2"

  local existing
  existing="$(otool -l "$target" | awk '$1 == "path" { print $2 }')"
  if [[ $'\n'"$existing"$'\n' == *$'\n'"$rpath"$'\n'* ]]; then
    return 0
  fi

  run_quietly install_name_tool -add_rpath "$rpath" "$target" ||
    fail "could not add rpath $rpath to $target"
}

register_app_bundle() {
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [[ -x "$lsregister" ]] || return 0

  # Optional: only refreshes Finder's "Open With" and Services entries.
  "$lsregister" -f "$APP_BUNDLE" >/dev/null 2>&1 ||
    echo "warning: lsregister could not register $APP_BUNDLE" >&2
}

copy_and_rewrite_dylibs() {
  if ! command -v otool >/dev/null 2>&1 || ! command -v install_name_tool >/dev/null 2>&1; then
    fail "otool and install_name_tool are required to stage the app (install the Xcode command line tools)"
  fi

  configure_dylib_search_dirs

  add_rpath_if_missing "@executable_path/../Frameworks" "$APP_BINARY"

  local -a queue=("$APP_BINARY")
  local processed="|"
  local missing=0

  while [[ ${queue[0]+set} ]]; do
    local target="${queue[0]}"
    if ((${#queue[@]} > 1)); then
      queue=("${queue[@]:1}")
    else
      queue=()
    fi

    if [[ "$processed" == *"|$target|"* ]]; then
      continue
    fi
    processed+="$target|"

    if [[ "$target" == "$APP_FRAMEWORKS/"* ]]; then
      add_rpath_if_missing "@loader_path" "$target"
      add_rpath_if_missing "@loader_path/../Frameworks" "$target"
    fi

    while IFS= read -r dependency; do
      [[ -n "$dependency" ]] || continue
      is_system_dependency "$dependency" && continue

      if [[ "$target" == "$APP_FRAMEWORKS/"* && "$(basename "$dependency")" == "$(basename "$target")" ]]; then
        continue
      fi

      local resolved
      resolved="$(resolve_dylib_dependency "$dependency" "$target")"
      if [[ -z "$resolved" || ! -f "$resolved" ]]; then
        echo "error: could not locate dylib dependency '$dependency' required by '$target'" >&2
        missing=1
        continue
      fi
      if [[ "$resolved" == "$target" ]]; then
        continue
      fi

      local dylib_name
      dylib_name="$(basename "$resolved")"
      local bundled="$APP_FRAMEWORKS/$dylib_name"

      if [[ ! -f "$bundled" ]]; then
        cp "$resolved" "$bundled"
        chmod u+w "$bundled"
        run_quietly install_name_tool -id "@rpath/$dylib_name" "$bundled" ||
          fail "could not set the install name of $bundled"
        queue+=("$bundled")
      fi

      run_quietly install_name_tool -change "$dependency" "@rpath/$dylib_name" "$target" ||
        fail "could not rewrite $dependency in $target"
    done < <(list_dylib_dependencies "$target")
  done

  if [[ "$missing" -ne 0 ]]; then
    echo "error: app bundle is missing one or more non-system dylibs" >&2
    exit 1
  fi
}

# Report what kind of FFmpeg ended up in the bundle. FFmpeg records its
# configure flags in every libav* library, static or dynamic, so the staged
# binaries themselves say whether GPL or nonfree components were enabled.
report_ffmpeg_licensing() {
  local report="$APP_RESOURCES/FFMPEG_BUILD_INFO.txt"
  local -a inspected=("$APP_BINARY")
  local -a gpl_reasons=()
  local -a nonfree_reasons=()
  local configuration=""
  local file name flags

  shopt -s nullglob
  for file in "$APP_FRAMEWORKS"/*.dylib; do
    inspected+=("$file")
  done
  shopt -u nullglob

  for file in "${inspected[@]}"; do
    name="$(basename "$file")"
    flags="$(strings -a "$file" 2>/dev/null | awk '/--(enable|disable)-[a-z0-9-]+/ && !seen { print; seen = 1 }' || true)"
    if [[ -n "$flags" ]]; then
      [[ -z "$configuration" ]] && configuration="$flags"
      [[ "$flags" == *"--enable-gpl"* ]] && gpl_reasons+=("$name was configured with --enable-gpl")
      [[ "$flags" == *"--enable-nonfree"* ]] && nonfree_reasons+=("$name was configured with --enable-nonfree")
    fi

    case "$name" in
      libx264*|libx265*|libxvidcore*|libvidstab*|librubberband*|libpostproc*|libxavs*|libdavs2*)
        gpl_reasons+=("$name is a GPL library")
        ;;
      libfdk-aac*)
        nonfree_reasons+=("$name (Fraunhofer FDK AAC) is not GPL/LGPL compatible")
        ;;
    esac
  done

  {
    echo "FFmpeg build information for this copy of $APP_NAME"
    echo "(generated by script/build_and_run.sh; not legal advice)"
    echo
    echo "FFmpeg configuration found in the staged binaries:"
    echo "  ${configuration:-<none found>}"
    echo
    echo "Bundled dynamic libraries:"
    if ((${#inspected[@]} > 1)); then
      for file in "${inspected[@]:1}"; do
        echo "  $(basename "$file")"
      done
    else
      echo "  <none; FFmpeg is linked statically or not at all>"
    fi
    echo
    if ((${#nonfree_reasons[@]} > 0)); then
      echo "Classification: NONFREE - not redistributable"
      printf '  %s\n' "${nonfree_reasons[@]}"
    fi
    if ((${#gpl_reasons[@]} > 0)); then
      echo "Classification: GPL components present"
      printf '  %s\n' "${gpl_reasons[@]}"
    fi
    if ((${#nonfree_reasons[@]} == 0 && ${#gpl_reasons[@]} == 0)); then
      echo "Classification: no GPL or nonfree markers detected"
    fi
  } >"$report"

  if ((${#nonfree_reasons[@]} > 0 || ${#gpl_reasons[@]} > 0)); then
    {
      echo
      echo "================================================================"
      echo "WARNING: $APP_BUNDLE is NOT an LGPL-only build."
      if ((${#nonfree_reasons[@]} > 0)); then
        echo "It contains nonfree FFmpeg components and must not be redistributed:"
        printf '  - %s\n' "${nonfree_reasons[@]}"
      fi
      if ((${#gpl_reasons[@]} > 0)); then
        echo "It contains GPL components, so the combined app can only be"
        echo "distributed under GPL-compatible terms, not the LGPL terms"
        echo "described in THIRD_PARTY_NOTICES.md:"
        printf '  - %s\n' "${gpl_reasons[@]}"
      fi
      echo "This is fine for running the app on your own machine."
      echo "Details: $report"
      echo "================================================================"
      echo
    } >&2
  elif [[ -z "$configuration" ]]; then
    echo "note: no FFmpeg configuration string found in the staged binaries; licensing not classified" >&2
  else
    echo "FFmpeg licensing check: no GPL or nonfree markers detected (see $report)" >&2
  fi
}

copy_and_rewrite_dylibs
report_ffmpeg_licensing
# Sign last: the licensing report above is written inside the bundle.
sign_app_bundle
register_app_bundle

open_app() {
  local -a open_arguments=()
  local name

  for name in "${FORWARDED_ENVIRONMENT_NAMES[@]}"; do
    if [[ -n "${!name:-}" ]]; then
      open_arguments+=(--env "$name=${!name}")
    fi
  done

  # ${array[@]+...} keeps an empty array from tripping `set -u` on bash 3.2.
  /usr/bin/open ${open_arguments[@]+"${open_arguments[@]}"} "$APP_BUNDLE"
}

run_console() {
  echo "Launching $APP_NAME from the terminal. Debug logs will be printed here." >&2
  "$APP_BINARY"
}

verify_app_running() {
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if pgrep -x "$APP_NAME" >/dev/null; then
      echo "$APP_NAME is running" >&2
      return 0
    fi
    /bin/sleep 0.5
  done

  fail "$APP_NAME did not start within 10 seconds"
}

case "$MODE" in
  run)
    open_app
    ;;
  --console|console)
    run_console
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    verify_app_running
    ;;
  *)
    usage
    exit 2
    ;;
esac
