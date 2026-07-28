#!/bin/bash
# make-timelapse.sh — turn dumped .frame files into a video.
#
# MVP SCAFFOLDING, not the shipping path. The real encoder (Phase 3) will be a
# small Swift binary using AVAssetWriter, which needs no extra dependencies and
# can consume frames live. This exists to get an end-to-end video on screen
# today, so we find out whether the whole idea works before polishing it.
#
#   bash tools/make-timelapse.sh [frames_dir] [out.mp4] [fps]
set -e

FRAMES="${1:-$HOME/SAI2-pressure/drive_c/sai-timelapse/frames}"
OUT="${2:-$HOME/Movies/sai-timelapse.mp4}"
FPS="${3:-12}"

command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)"; exit 1; }
[ -d "$FRAMES" ] || { echo "no frames directory: $FRAMES"; exit 1; }

COUNT=$(find "$FRAMES" -name '*.frame' | wc -l | tr -d ' ')
[ "$COUNT" -gt 0 ] || { echo "no .frame files in $FRAMES — did capture run?"; exit 1; }
echo "found $COUNT frame(s) in $FRAMES"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Renumber while converting: dedup means the recorder's sequence numbers can
# have gaps, and ffmpeg's %05d input pattern stops dead at the first missing
# index rather than skipping it.
i=0
for f in $(find "$FRAMES" -name '*.frame' | sort); do
    printf -v name "%05d" "$i"
    python3 "$(dirname "$0")/frame2png.py" "$f" "$WORK/$name.png" >/dev/null
    i=$((i + 1))
done
echo "converted $i frame(s)"

mkdir -p "$(dirname "$OUT")"
# yuv420p for players that refuse anything else; the scale filter forces even
# dimensions, which H.264 requires and an odd-sized canvas will not give you.
ffmpeg -y -loglevel error \
    -framerate "$FPS" -i "$WORK/%05d.png" \
    -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
    -c:v libx264 -pix_fmt yuv420p -crf 18 \
    "$OUT"

echo "wrote $OUT  ($i frames at ${FPS}fps = $(echo "scale=1; $i/$FPS" | bc)s)"
