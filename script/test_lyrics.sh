#!/usr/bin/env bash
set -euo pipefail

# Runs `swift test` with the FFmpeg runtime libraries on the loader path.
# Extra arguments are passed straight to `swift test`.
#
# Library directory, first match wins:
#   1. FENGLU_TEST_LIBRARY_DIR, when set.
#   2. dist/FengluPlayer.app/Contents/Frameworks, when the app has been staged.
#   3. The libdir pkg-config reports for libavformat (a clean checkout).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_BINARY="$(xcrun --find swift)"
STAGED_LIBRARY_DIR="$ROOT_DIR/dist/FengluPlayer.app/Contents/Frameworks"

TEST_LIBRARY_DIR=""
if [[ -n "${FENGLU_TEST_LIBRARY_DIR:-}" ]]; then
  TEST_LIBRARY_DIR="$FENGLU_TEST_LIBRARY_DIR"
  if [[ ! -d "$TEST_LIBRARY_DIR" ]]; then
    echo "warning: FENGLU_TEST_LIBRARY_DIR is not a directory: $TEST_LIBRARY_DIR" >&2
    TEST_LIBRARY_DIR=""
  fi
elif [[ -d "$STAGED_LIBRARY_DIR" ]]; then
  TEST_LIBRARY_DIR="$STAGED_LIBRARY_DIR"
elif command -v pkg-config >/dev/null 2>&1; then
  TEST_LIBRARY_DIR="$(pkg-config --variable=libdir libavformat 2>/dev/null || true)"
  [[ -d "$TEST_LIBRARY_DIR" ]] || TEST_LIBRARY_DIR=""
fi

cd "$ROOT_DIR"
if [[ -n "$TEST_LIBRARY_DIR" ]]; then
  echo "Using FFmpeg runtime libraries from $TEST_LIBRARY_DIR" >&2
  export DYLD_LIBRARY_PATH="$TEST_LIBRARY_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
else
  echo "note: no FFmpeg runtime library directory found; relying on the default loader path" >&2
fi

# Invoke the toolchain binary directly: /usr/bin/swift can strip DYLD variables.
exec "$SWIFT_BINARY" test "$@"
