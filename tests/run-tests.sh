#!/bin/bash
# Build + run all unit tests (native, no tablet/Wine/mingw needed).
# Usage: bash tests/run-tests.sh
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== C core (wintab_core.h) — under AddressSanitizer + UBSanitizer =="
# Sanitizers turn any out-of-bounds / divide-by-zero / integer-UB into a hard
# failure, so CI catches memory bugs in the pure logic, not just wrong answers.
cc -Wall -Wextra -Werror -fsanitize=address,undefined -fno-sanitize-recover=all \
   -o "$WORK/test_wintab_core" "$REPO/tests/test_wintab_core.c"
"$WORK/test_wintab_core"

echo ""
echo "== C core (timelapse_core.h) — under AddressSanitizer + UBSanitizer =="
# The tile walk runs inside SAI's own process, where an out-of-bounds read is a
# crash that costs the artist unsaved work. Sanitizers here are the substitute
# for that being unrecoverable in production.
cc -Wall -Wextra -Werror -fsanitize=address,undefined -fno-sanitize-recover=all \
   -o "$WORK/test_timelapse_core" "$REPO/tests/test_timelapse_core.c"
"$WORK/test_timelapse_core"

echo ""
echo "== Swift core (PressureCore.swift) =="
swiftc -o "$WORK/core-tests" "$REPO/wacom-helper/PressureCore.swift" "$REPO/tests/CoreTests.swift"
"$WORK/core-tests"

echo ""
echo "== Swift core (EncoderCore.swift) =="
swiftc -o "$WORK/encoder-tests" "$REPO/timelapse-encoder/EncoderCore.swift" "$REPO/tests/EncoderTests.swift"
"$WORK/encoder-tests"

echo ""
echo "== Swift core (LibraryCore.swift) =="
# Deciding that tonight's session continues a drawing from three weeks ago. A
# wrong "yes" welds two unrelated drawings into one video, so the thresholds
# here are measured against synthesised canvases rather than guessed at.
swiftc -o "$WORK/library-tests" "$REPO/timelapse-encoder/LibraryCore.swift" "$REPO/tests/LibraryTests.swift"
"$WORK/library-tests"

echo ""
echo "All test suites passed."

echo ""
echo "== SAI update keeps the user's files (real filesystem) =="
# updateSAIFromFolder() deletes the SAI folder in the prefix and restores the
# user's files afterwards. That is the only place this app destroys data, so it
# is tested against a throwaway prefix rather than reasoned about.
UPD="$WORK/upd"
mkdir -p "$UPD/prefix/drive_c/SAI2/settings" "$UPD/newsrc/init"
printf 'OLD-EXE'      > "$UPD/prefix/drive_c/SAI2/sai2.exe"
printf 'MY-LAYOUT'    > "$UPD/prefix/drive_c/SAI2/sai2.ini"
printf 'MY-BRUSH'     > "$UPD/prefix/drive_c/SAI2/settings/brushes.dat"
printf 'MY-HISTORY'   > "$UPD/prefix/drive_c/SAI2/history.txt"
printf 'MY-LICENCE'   > "$UPD/prefix/drive_c/SAI2/sai-123456.slc"
printf 'REMOVED-UPSTREAM' > "$UPD/prefix/drive_c/SAI2/obsolete.dll"
printf 'NEW-EXE'      > "$UPD/newsrc/sai2.exe"
printf 'FACTORY'      > "$UPD/newsrc/sai2.ini"
printf 'SHIPPED'      > "$UPD/newsrc/init/brushform.conf"

swiftc -o "$WORK/helper-upd" "$REPO/wacom-helper/main.swift" "$REPO/wacom-helper/PressureCore.swift"
SAI_PREFIX="$UPD/prefix" SAIPP_CONFIG_DIR="$UPD/cfg" \
  SAIPP_SELFTEST_UPDATE="$UPD/newsrc" "$WORK/helper-upd" > "$UPD/out" 2>&1 || {
    echo "  FAIL update reported: $(cat "$UPD/out")"; exit 1; }

D="$UPD/prefix/drive_c/SAI2"
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; fail=1; fi; }
check "update: sai2.exe is replaced"            "$(cat "$D/sai2.exe")"              "NEW-EXE"
check "update: the user's sai2.ini wins over the shipped one" "$(cat "$D/sai2.ini")" "MY-LAYOUT"
check "update: brushes and presets survive"     "$(cat "$D/settings/brushes.dat")"  "MY-BRUSH"
check "update: recent-files history survives"   "$(cat "$D/history.txt")"           "MY-HISTORY"
check "update: the licence survives"            "$(cat "$D"/*.slc 2>/dev/null)"     "MY-LICENCE"
check "update: files new to this build arrive"  "$(cat "$D/init/brushform.conf")"   "SHIPPED"
# A file dropped upstream must not linger: that is why the folder is cleared
# rather than copied over in place.
if [ -f "$D/obsolete.dll" ]; then echo "  FAIL update: a file removed upstream lingers"; fail=1
else echo "  ok   update: a file removed upstream is gone"; fi
[ "$fail" = 0 ] || exit 1
echo "All SAI update tests passed."

echo ""
echo "== Live encoding accumulates instead of overwriting =="
# --watch used to open a fresh AVAssetWriter on every poll, and a new writer
# truncates its output file — so each pass silently threw away everything
# encoded before it. Frames are deleted once consumed, so that lost footage for
# good. This checks the writers stay open across polls.
LIVE="$WORK/live"; mkdir -p "$LIVE/frames"
swiftc -O -o "$WORK/enc-live" "$REPO/timelapse-encoder/EncoderCore.swift" \
    "$REPO/timelapse-encoder/main.swift"

mkframes() {  # start end canvas_id name w h
  python3 - "$@" <<'PY'
import struct, sys, pathlib
HDR = struct.Struct("<8sIIIIQQQ64s")
a,b,cid,name,w,h = int(sys.argv[1]),int(sys.argv[2]),int(sys.argv[3],16),sys.argv[4],int(sys.argv[5]),int(sys.argv[6])
for i in range(a,b+1):
    px = bytes([(i*20)%256,255-(i*20)%256,128,255])*(w*h)
    pathlib.Path(f"{sys.argv[7]}/{i:08d}.frame").write_bytes(
        HDR.pack(b"SAITLF2",w,h,w*4,0,i,1000*i,cid,name.encode())+px)
PY
}
mkframes 1 3 AAAA Sketch 64 48 "$LIVE/frames"
"$WORK/enc-live" --frames "$LIVE/frames" --out "$LIVE/out.mp4" --fps 5 --watch > "$LIVE/log" 2>&1 &
LIVEPID=$!
sleep 3
mkframes 4 9 AAAA Sketch 64 48 "$LIVE/frames"      # more of the same canvas
mkframes 10 12 BBBB Second 32 32 "$LIVE/frames"    # a second canvas, different size
sleep 4
kill -INT $LIVEPID 2>/dev/null; wait $LIVEPID 2>/dev/null || true
sleep 1

live_fail=0
# The totals line is the assertion that matters: 12 frames means none of the
# first three were lost when the later ones arrived.
if grep -q "finished 2 canvas(es), 12 frame(s)" "$LIVE/log"; then
  echo "  ok   live: every frame reaches a video, across two canvases"
else
  echo "  FAIL live: expected 2 canvases / 12 frames, log says:"; cat "$LIVE/log"; live_fail=1
fi
[ -s "$LIVE/out.Sketch.000.mp4" ] && echo "  ok   live: first canvas has its own video" \
  || { echo "  FAIL live: no video for the first canvas"; live_fail=1; }
[ -s "$LIVE/out.Second.000.mp4" ] && echo "  ok   live: a canvas of another size gets its own video" \
  || { echo "  FAIL live: no video for the second canvas"; live_fail=1; }
# Disk staying flat is the entire point of encoding live.
left=$(ls "$LIVE/frames" 2>/dev/null | wc -l | tr -d ' ')
[ "$left" = "0" ] && echo "  ok   live: frames are deleted as they are encoded" \
  || { echo "  FAIL live: $left frame(s) left on disk"; live_fail=1; }
[ "$live_fail" = 0 ] || exit 1
echo "All live encoding tests passed."
