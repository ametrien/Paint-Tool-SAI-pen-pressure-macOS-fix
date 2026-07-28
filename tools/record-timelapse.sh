#!/bin/bash
# record-timelapse.sh — one command: draw, quit, get a video.
#
# MVP SCAFFOLDING. Once the recorder is wired into the app's UI (Phase 4) none
# of this is needed — you will just tick a box.
#
#   bash tools/record-timelapse.sh
#
# What it handles for you:
#
#   * The app reinstalls its OWN bundled wintab32.dll into the prefix on every
#     launch (ensureBridgeUpToDate), which silently replaces the freshly built
#     one and leaves you wondering why nothing records. Rather than racing it by
#     hand, a background guard keeps the current DLL in place for as long as the
#     app runs. Rebuilding and re-signing the app would also work, but the
#     installed bundle's TeamIdentifier no longer matches the available signing
#     identity, so re-signing costs the Input Monitoring grant.
#   * Clearing stale frames, so the video is only this session.
#   * Building the video once you quit.
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${SAI_PREFIX:-$HOME/SAI2-pressure}"
APP="${SAI_APP:-/Applications/SAI Pen Pressure.app}"
DLL="$REPO/wintab-src/wintab32.dll"
TARGET="$PREFIX/drive_c/windows/system32/wintab32.dll"
FRAMES="$PREFIX/drive_c/sai-timelapse/frames"

[ -f "$DLL" ] || { echo "no built DLL at $DLL — build it first"; exit 1; }
[ -d "$APP" ] || { echo "app not found at $APP"; exit 1; }

echo "clearing old frames"
rm -f "$FRAMES"/*.frame 2>/dev/null || true

# Guard the DLL for the whole session rather than trying to copy it at exactly
# the right moment between the app starting and SAI launching.
( while :; do
      cmp -s "$DLL" "$TARGET" 2>/dev/null || cp "$DLL" "$TARGET" 2>/dev/null
      sleep 0.5
  done ) &
GUARD=$!
trap 'kill "$GUARD" 2>/dev/null || true' EXIT

cat <<'EOS'

  Starting the app with timelapse recording ON.

    1. Start SAI from the app, open a canvas, and draw with the tablet.
    2. One finished stroke = one frame. Strokes that change nothing are dropped.
    3. When you are done: quit SAI, then QUIT THE APP (the pen menu -> Quit).

  The video is built automatically once the app exits.

EOS

WT_DEBUG=1 WT_TIMELAPSE=1 "$APP/Contents/MacOS/$(basename "$APP" .app | tr -d ' ')" || true

kill "$GUARD" 2>/dev/null || true

echo ""
echo "app exited — building the video"
bash "$REPO/tools/make-timelapse.sh"
