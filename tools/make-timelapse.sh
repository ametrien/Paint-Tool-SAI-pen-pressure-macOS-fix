#!/bin/bash
# make-timelapse.sh — turn dumped .frame files into a video.
#
# MVP SCAFFOLDING, not the shipping path. The real encoder (Phase 3) will be a
# small Swift binary using AVAssetWriter, which needs no extra dependencies and
# can consume frames live. This exists to get an end-to-end video on screen
# today, so we find out whether the whole idea works before polishing it.
#
#   bash tools/make-timelapse.sh [frames_dir] [out.mp4] [fps] [from] [to]
#
#   fps        playback speed. Frames are captured per stroke, not per second,
#              so this IS the speed control: 4 = slow, 30 = fast.
#   from/to    1-based frame range, inclusive. Trims the boring warm-up or a
#              long tail. Omit for everything.
#
#   bash tools/make-timelapse.sh "" "" 4          # same frames, slower
#   bash tools/make-timelapse.sh "" "" 12 20 60   # only frames 20..60
set -e

FRAMES="${1:-$HOME/SAI2-pressure/drive_c/sai-timelapse/frames}"
OUT="${2:-$HOME/Movies/sai-timelapse.mp4}"
FPS="${3:-12}"
FROM="${4:-1}"
TO="${5:-0}"          # 0 = to the end
[ -n "$FRAMES" ] || FRAMES="$HOME/SAI2-pressure/drive_c/sai-timelapse/frames"
[ -n "$OUT" ] || OUT="$HOME/Movies/sai-timelapse.mp4"

command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)"; exit 1; }
[ -d "$FRAMES" ] || { echo "no frames directory: $FRAMES"; exit 1; }

COUNT=$(find "$FRAMES" -name '*.frame' | wc -l | tr -d ' ')
[ "$COUNT" -gt 0 ] || { echo "no .frame files in $FRAMES — did capture run?"; exit 1; }
echo "found $COUNT frame(s) in $FRAMES"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Frames can differ in size within one session — a canvas resize does it, and so
# did the scratch pad before that was fixed. ffmpeg takes its output dimensions
# from the FIRST image and squashes everything after to match, so a single odd
# frame at the front silently ruins the whole video (a 1000x700 drawing came out
# as 198x878). Pick the dominant size and use only those frames.
DIMS=$(for f in $(find "$FRAMES" -name '*.frame' | sort); do
           python3 "$(dirname "$0")/frame2png.py" --dims "$f"
       done | sort | uniq -c | sort -rn)
MAIN=$(echo "$DIMS" | head -1 | awk '{print $2}')
echo "frame sizes seen:"
echo "$DIMS" | sed 's/^/  /'
echo "using $MAIN"

# Renumber while converting: dedup means the recorder's sequence numbers can
# have gaps, and ffmpeg's %05d input pattern stops dead at the first missing
# index rather than skipping it.
i=0; skipped=0; n=0
for f in $(find "$FRAMES" -name '*.frame' | sort); do
    if [ "$(python3 "$(dirname "$0")/frame2png.py" --dims "$f")" != "$MAIN" ]; then
        skipped=$((skipped + 1)); continue
    fi
    # Range is applied over frames of the CHOSEN size, so the numbers match what
    # you see in the finished video rather than counting frames that were
    # dropped for being a different size.
    n=$((n + 1))
    [ "$n" -ge "$FROM" ] || continue
    [ "$TO" -eq 0 ] || [ "$n" -le "$TO" ] || continue
    printf -v name "%05d" "$i"
    python3 "$(dirname "$0")/frame2png.py" "$f" "$WORK/$name.png" >/dev/null
    i=$((i + 1))
done
echo "converted $i frame(s)${skipped:+, skipped $skipped of another size}"
[ "$FROM" -eq 1 ] && [ "$TO" -eq 0 ] || echo "range: $FROM..${TO:-end} of $n"
[ "$i" -gt 0 ] || { echo "nothing to encode"; exit 1; }

mkdir -p "$(dirname "$OUT")"
# yuv420p for players that refuse anything else; the scale filter forces even
# dimensions, which H.264 requires and an odd-sized canvas will not give you.
ffmpeg -y -loglevel error \
    -framerate "$FPS" -i "$WORK/%05d.png" \
    -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
    -c:v libx264 -pix_fmt yuv420p -crf 18 \
    "$OUT"

echo "wrote $OUT  ($i frames at ${FPS}fps = $(echo "scale=1; $i/$FPS" | bc)s)"
