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

# The helper is one binary: main.swift now refers to the library tab, so every
# source it needs has to be here too.
HELPER_SRC=("$REPO/wacom-helper/main.swift" "$REPO/wacom-helper/PressureCore.swift"
            "$REPO/wacom-helper/LibraryStore.swift" "$REPO/wacom-helper/LibraryUI.swift"
            "$REPO/timelapse-encoder/LibraryCore.swift")
swiftc -o "$WORK/helper-upd" "${HELPER_SRC[@]}"
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
    "$REPO/timelapse-encoder/LibraryCore.swift" "$REPO/timelapse-encoder/main.swift"

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

echo ""
echo "== A session leaves a fingerprint, and pieces rebuild into one video =="
# The two halves of drawing across several evenings: a session has to record
# what the canvas looked like (so a later session can recognise it), and the
# per-session pieces have to become the single video somebody watches.
REB="$WORK/reb"; mkdir -p "$REB/frames" "$REB/out"
reb_fail=0

# --- a live session, then a separate --finalize run, as the app does it -------
mkframes 1 6 CAFE Sketch 64 48 "$REB/frames"
"$WORK/enc-live" --frames "$REB/frames" --out "$REB/out/session.mp4" --fps 5 --watch \
    > "$REB/log" 2>&1 &
RPID=$!
sleep 3
kill -INT $RPID 2>/dev/null; wait $RPID 2>/dev/null || true
# Frames captured after the watcher stopped: --finalize must fold these in
# WITHOUT losing the session's original opening fingerprint.
mkframes 7 9 CAFE Sketch 64 48 "$REB/frames"
"$WORK/enc-live" --frames "$REB/frames" --out "$REB/out/session.mp4" --fps 5 --finalize \
    >> "$REB/log" 2>&1 || { echo "  FAIL rebuild: --finalize failed"; cat "$REB/log"; exit 1; }

SIDE="$REB/out/session.Sketch.json"
if [ -s "$SIDE" ]; then echo "  ok   session: a fingerprint sidecar is written"
else echo "  FAIL session: no sidecar at $SIDE"; ls "$REB/out"; reb_fail=1; fi

# THE TRAP: --finalize runs in a DIFFERENT process from --watch and re-opens the
# session. Drop the sidecar-adoption in LiveWriter.init and the opening
# fingerprint gets overwritten by one taken from the last few strokes — the
# drawing then stops matching itself next session, silently.
#
# mkframes paints frame i a flat colour B=(i*20), G=255-(i*20), R=128, and the
# fingerprint stores luma (B + 2G + R)/4, so every cell of frame i reads
# (i*20 + 2*(255 - i*20) + 128)/4:
#     frame 1 -> 154   the session's opening, written by --watch
#     frame 7 -> 124   the first frame --finalize sees; what a broken adoption
#                      would report as the opening
#     frame 9 -> 114   the closing, after --finalize folded in the leftovers
python3 - "$SIDE" <<'PY' || reb_fail=1
import json, sys
d = json.load(open(sys.argv[1]))
ok = True
def check(cond, msg):
    global ok
    print(("  ok   " if cond else "  FAIL ") + msg); ok = ok and cond
check(d["frames"] == 9, f"session: all 9 frames counted across both runs (got {d['frames']})")
check(d["title"] == "Sketch", "session: the canvas name is recorded")
check(len(d["opening"]["cells"]) == 256 and len(d["closing"]["cells"]) == 256,
      "session: both fingerprints are 16x16")
check(d["opening"]["cells"][0] == 154,
      f"session: the opening fingerprint survives --finalize (got {d['opening']['cells'][0]}, want 154 = frame 1)")
check(d["closing"]["cells"][0] == 114,
      f"session: the closing fingerprint is the LAST frame (got {d['closing']['cells'][0]}, want 114 = frame 9)")
check(d["opening"]["cells"] != d["closing"]["cells"],
      "session: opening and closing are actually different")
sys.exit(0 if ok else 1)
PY

# --- rebuilding a drawing from its pieces ------------------------------------
mkpiece() {  # dir name w h count
  local d="$1" n="$2" w="$3" h="$4" c="$5"
  rm -rf "$WORK/pf"; mkdir -p "$WORK/pf"
  mkframes 1 "$c" DEAD Piece "$w" "$h" "$WORK/pf"
  "$WORK/enc-live" --frames "$WORK/pf" --out "$d/$n" --fps 5 > /dev/null 2>&1
}
PIECES="$REB/draw/pieces"; mkdir -p "$PIECES"
mkpiece "$PIECES" "2026-07-27 2015.mp4" 64 48 5
mkpiece "$PIECES" "2026-07-28 1903.mp4" 64 48 7
"$WORK/enc-live" --rebuild "$PIECES" --out "$REB/draw/Sketch.mp4" > "$REB/rlog" 2>&1 \
  || { echo "  FAIL rebuild: uniform rebuild failed"; cat "$REB/rlog"; exit 1; }
probe=$("$WORK/enc-live" --probe "$REB/draw/Sketch.mp4")
[ "$probe" = "64x48 2.40s" ] && echo "  ok   rebuild: two sessions become one video of both ($probe)" \
  || { echo "  FAIL rebuild: expected 64x48 2.40s, got $probe"; reb_fail=1; }
grep -q "2 piece(s)" "$REB/rlog" && echo "  ok   rebuild: both pieces were used" \
  || { echo "  FAIL rebuild: log says $(cat "$REB/rlog")"; reb_fail=1; }

# Pieces are the archive: a rebuild must never consume them.
[ -f "$PIECES/2026-07-27 2015.mp4" ] && [ -f "$PIECES/2026-07-28 1903.mp4" ] \
  && echo "  ok   rebuild: the session pieces survive the rebuild" \
  || { echo "  FAIL rebuild: a piece was consumed"; reb_fail=1; }

# Derived, therefore repeatable. Running it again must give the same video, not
# a video of the video.
"$WORK/enc-live" --rebuild "$PIECES" --out "$REB/draw/Sketch.mp4" > /dev/null 2>&1
probe2=$("$WORK/enc-live" --probe "$REB/draw/Sketch.mp4")
[ "$probe2" = "$probe" ] && echo "  ok   rebuild: rebuilding again is idempotent" \
  || { echo "  FAIL rebuild: second rebuild gave $probe2, first gave $probe"; reb_fail=1; }

# THE TRAP: a canvas resized between sessions. Passthrough cannot mix
# dimensions, so this takes the composition path — and getting it wrong is how a
# 1000x700 drawing once came out as 198x878. The output must be big enough for
# BOTH pieces, with neither stretched.
MIX="$REB/mixed/pieces"; mkdir -p "$MIX"
mkpiece "$MIX" "2026-07-27 2015.mp4" 64 48 5
mkpiece "$MIX" "2026-07-28 1903.mp4" 96 32 5
"$WORK/enc-live" --rebuild "$MIX" --out "$REB/mixed/Big.mp4" > "$REB/mlog" 2>&1 \
  || { echo "  FAIL rebuild: mixed-size rebuild failed"; cat "$REB/mlog"; exit 1; }
mprobe=$("$WORK/enc-live" --probe "$REB/mixed/Big.mp4")
[ "${mprobe%% *}" = "96x48" ] && echo "  ok   rebuild: a resized canvas gets a frame that fits both ($mprobe)" \
  || { echo "  FAIL rebuild: expected 96x48, got $mprobe"; reb_fail=1; }
grep -q "mixed sizes" "$REB/mlog" && echo "  ok   rebuild: the mixed-size path is the one that ran" \
  || { echo "  FAIL rebuild: took the passthrough path with mixed sizes"; reb_fail=1; }

# A length cap is a rendition, applied on request — never baked into the archive.
"$WORK/enc-live" --rebuild "$PIECES" --out "$REB/draw/Short.mp4" --max-seconds 1 >/dev/null 2>&1
sprobe=$("$WORK/enc-live" --probe "$REB/draw/Short.mp4")
case "$sprobe" in
  "64x48 1.0"*|"64x48 0.9"*) echo "  ok   rebuild: --max-seconds re-times without touching the pieces ($sprobe)" ;;
  *) echo "  FAIL rebuild: expected about 1s, got $sprobe"; reb_fail=1 ;;
esac
[ -f "$PIECES/2026-07-27 2015.mp4" ] || { echo "  FAIL rebuild: the export ate a piece"; reb_fail=1; }

[ "$reb_fail" = 0 ] || exit 1
echo "All rebuild tests passed."

echo ""
echo "== Sessions are filed into drawings, across evenings (real filesystem) =="
# Filing MOVES a session's only copy into a drawing's folder, so this runs
# against a throwaway videos folder rather than being reasoned about.
LIB="$WORK/lib"; mkdir -p "$LIB/.recording"
lib_fail=0
swiftc -o "$WORK/helper-lib" "${HELPER_SRC[@]}"

# A finished session: a video plus the fingerprint sidecar beside it.
#
# `pattern` picks WHICH drawing this is; the two progress numbers are how much
# ink was on the canvas when the session opened and when it closed. Marks accrue
# in a fixed order per pattern, so opening at exactly the previous session's
# closing count models reopening a saved file — which looks, as it must, almost
# identical to how it was left.
mksession() {  # name title started pattern open_progress close_progress
  python3 - "$LIB/.recording" "$@" <<'PYSESSION'
import json, sys, pathlib
out, name, title, started, pattern, popen, pclose = sys.argv[1:8]
side = 16
def canvas(marks):
    cells = [255] * (side * side)
    rng = int(pattern) * 2654435761 % (2**32)
    for _ in range(int(marks)):
        rng = (rng * 1103515245 + 12345) % (2**31)
        cells[rng % (side * side)] = 30
    return {"cells": cells, "width": 200, "height": 150}
pathlib.Path(f"{out}/{name}.json").write_text(json.dumps({
    "title": title, "startedAt": started, "frames": 40,
    "width": 200, "height": 150,
    "opening": canvas(popen), "closing": canvas(pclose)}))
pathlib.Path(f"{out}/{name}.mp4").write_bytes(b"fake video " + name.encode())
PYSESSION
}
# Piece names are local-time timestamps; pin the zone so the expectations below
# read the same wherever this runs.
file_them() { TZ=UTC SAIPP_SELFTEST_LIBRARY="$LIB" "$@" "$WORK/helper-lib"; }

# Evening one: a new drawing.
mksession "session 2026-07-27 2015" "Sketch" "2026-07-27T20:15:00Z" 7 5 40
out=$(file_them)
echo "$out" | grep -q "filed 2026-07-27 2015.mp4 -> Sketch" \
  && echo "  ok   filing: a new drawing gets its own folder" \
  || { echo "  FAIL filing: $out"; lib_fail=1; }
[ -f "$LIB/Sketch/pieces/2026-07-27 2015.mp4" ] \
  && echo "  ok   filing: the session lands in that drawing's pieces folder" \
  || { echo "  FAIL filing: piece not moved: $(find "$LIB" -name '*.mp4')"; lib_fail=1; }
[ -f "$LIB/.recording/session 2026-07-27 2015.mp4" ] \
  && { echo "  FAIL filing: the session was left in staging too"; lib_fail=1; } \
  || echo "  ok   filing: staging is left clean"

# Evening two: the same file reopened (opening 41 = where evening one closed,
# plus tonight's first stroke) and drawn on further — while the canvas has been
# RENAMED in between.
#
# THE TRAP: match on the title instead of the canvas contents and this lands in
# a second folder called "final v2", which is the bug that started all of this.
mksession "session 2026-07-28 1903" "final v2" "2026-07-28T19:03:00Z" 7 41 60
out=$(file_them)
echo "$out" | grep -q "filed 2026-07-28 1903.mp4 -> Sketch" \
  && echo "  ok   filing: a renamed canvas rejoins the same drawing" \
  || { echo "  FAIL filing: $out"; lib_fail=1; }
echo "$out" | grep -q "drawing Sketch: 2026-07-27 2015.mp4, 2026-07-28 1903.mp4" \
  && echo "  ok   filing: both evenings are in it, in the order drawn" \
  || { echo "  FAIL filing: $out"; lib_fail=1; }

# A genuinely different drawing must NOT be swept into it.
mksession "session 2026-07-29 1000" "Portrait" "2026-07-29T10:00:00Z" 91 5 40
out=$(file_them)
echo "$out" | grep -q "filed 2026-07-29 1000.mp4 -> Portrait" \
  && echo "  ok   filing: an unrelated drawing gets its own folder" \
  || { echo "  FAIL filing: $out"; lib_fail=1; }

# THE TRAP FOR THE PROMPT: a session that opens well past where the drawing was
# left (80 marks against 60) is plausible, not certain — someone may have worked
# on it elsewhere, or this may be a different picture altogether. It must be
# filed as its own drawing AND recorded as a question, never merged silently,
# because a wrong silent merge welds two drawings into one video with nothing on
# screen to say so.
mksession "session 2026-07-30 2100" "Sketch" "2026-07-30T21:00:00Z" 7 80 100
out=$(file_them)
echo "$out" | grep -q "ask:Sketch" \
  && echo "  ok   filing: a plausible continuation asks instead of merging" \
  || { echo "  FAIL filing: expected a question, got: $out"; lib_fail=1; }
echo "$out" | grep -q "drawing Sketch: 2026-07-27 2015.mp4, 2026-07-28 1903.mp4$" \
  && echo "  ok   filing: and is NOT quietly added to the drawing it might belong to" \
  || { echo "  FAIL filing: the pending session was merged anyway: $out"; lib_fail=1; }

# Answering "same drawing" moves it across — on disk, not just in the index.
out=$(file_them env SAIPP_SELFTEST_CONFIRM=same)
echo "$out" | grep -q "confirmed same -> Sketch" \
  && echo "  ok   confirm: answering yes moves the session into the drawing" \
  || { echo "  FAIL confirm: $out"; lib_fail=1; }
[ -f "$LIB/Sketch/pieces/2026-07-30 2100.mp4" ] \
  && echo "  ok   confirm: and the file itself moves with it" \
  || { echo "  FAIL confirm: file not moved: $(find "$LIB" -name '2026-07-30*')"; lib_fail=1; }
[ "$(find "$LIB" -name '2026-07-30 2100.mp4' | wc -l | tr -d ' ')" = "1" ] \
  && echo "  ok   confirm: exactly one copy of it exists afterwards" \
  || { echo "  FAIL confirm: the session was duplicated or lost"; lib_fail=1; }

[ "$lib_fail" = 0 ] || exit 1
echo "All library filing tests passed."

echo ""
echo "== The whole path: draw, quit, draw again tomorrow =="
# Everything above tests one half. This is the seam: the encoder's real output
# filed by the real filing code and rebuilt into a real video. A mismatch
# between what the encoder names its sessions and what filing looks for would
# pass every test above and fail every actual recording.
E2E="$WORK/e2e"; mkdir -p "$E2E/videos/.recording" "$E2E/frames"
e2e_fail=0

# Frames that are actually a PICTURE. mkframes paints each frame a flat colour,
# which has no structure at all — and a canvas with no structure is refused as
# evidence of identity on purpose (two blank canvases match perfectly and mean
# nothing). Here frame i holds i accumulating marks in fixed positions, so
# consecutive frames look nearly identical, which is what reopening a saved
# drawing looks like.
mkart() {  # start end canvas_id name w h dir
  python3 - "$@" <<'PYART'
import struct, sys, pathlib
HDR = struct.Struct("<8sIIIIQQQ64s")
a,b,cid,name,w,h,out = (int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3],16),
                        sys.argv[4], int(sys.argv[5]), int(sys.argv[6]), sys.argv[7])
def frame(n):
    px = bytearray(b"\xff" * (w*h*4))
    rng = 12345
    for _ in range(n):
        rng = (rng * 1103515245 + 12345) % (2**31)
        x0 = rng % max(1, w - 8); y0 = (rng >> 8) % max(1, h - 6)
        for y in range(y0, y0 + 6):
            for x in range(x0, x0 + 8):
                o = (y*w + x) * 4
                px[o:o+4] = b"\x28\x28\x28\xff"
    return bytes(px)
for i in range(a, b+1):
    pathlib.Path(f"{out}/{i:08d}.frame").write_bytes(
        HDR.pack(b"SAITLF2",w,h,w*4,0,i,1000*i,cid,name.encode()) + frame(i))
PYART
}

session() {  # first_frame last_frame stamp
  rm -f "$E2E/videos/.recording"/*
  mkart "$1" "$2" F00D Sketch 64 48 "$E2E/frames"
  "$WORK/enc-live" --frames "$E2E/frames" \
      --out "$E2E/videos/.recording/session $3.mp4" --fps 5 --finalize >/dev/null 2>&1
  TZ=UTC SAIPP_SELFTEST_LIBRARY="$E2E/videos" "$WORK/helper-lib"
}

out1=$(session 1 6 "2026-07-27 2015")
out2=$(session 7 12 "2026-07-28 1903")

echo "$out2" | grep -qE "^drawing [^:]+: .*, .*" \
  && echo "  ok   end-to-end: the second evening joined the first drawing" \
  || { echo "  FAIL end-to-end: two separate drawings:"; echo "$out2"; e2e_fail=1; }

folder=$(echo "$out2" | sed -n 's/^drawing \([^:]*\):.*/\1/p' | head -1)
count=$(ls "$E2E/videos/$folder/pieces"/*.mp4 2>/dev/null | wc -l | tr -d ' ')
[ "$count" = "2" ] && echo "  ok   end-to-end: both sessions are on disk as pieces" \
  || { echo "  FAIL end-to-end: $count piece(s) in $folder"; e2e_fail=1; }

# And the pieces rebuild into one playable video of both evenings: 12 frames at
# 5fps is 2.4 seconds.
"$WORK/enc-live" --rebuild "$E2E/videos/$folder/pieces" \
    --out "$E2E/videos/$folder/$folder.mp4" >/dev/null 2>&1
probe=$("$WORK/enc-live" --probe "$E2E/videos/$folder/$folder.mp4" 2>/dev/null)
[ "$probe" = "64x48 2.40s" ] \
  && echo "  ok   end-to-end: one video holding both evenings ($probe)" \
  || { echo "  FAIL end-to-end: expected 64x48 2.40s, got '$probe'"; e2e_fail=1; }

# Nothing is left in staging, and no raw frames survive: disk stays flat.
[ -z "$(ls -A "$E2E/videos/.recording" 2>/dev/null)" ] \
  && echo "  ok   end-to-end: staging is empty afterwards" \
  || { echo "  FAIL end-to-end: left in staging: $(ls "$E2E/videos/.recording")"; e2e_fail=1; }

[ "$e2e_fail" = 0 ] || exit 1
echo "All end-to-end tests passed."

echo ""
echo "== The Timelapses tab actually lays out =="
# It shipped BLANK: every row built, added and unhidden — and drawn at zero
# size, because a stack view used as a scroll view's documentView is laid out by
# constraints and had been left on autoresizing translation. Nothing in the code
# reads as wrong; only the measured frames say so.
TAB="$WORK/tab"; mkdir -p "$TAB/cfg"
tab_fail=0
echo -n "$E2E/videos" > "$TAB/cfg/timelapse-folder.txt"
cp "$E2E/videos/library.json" "$TAB/cfg/library.json" 2>/dev/null || true
layout=$(SAIPP_CONFIG_DIR="$TAB/cfg" SAIPP_SELFTEST_TABLAYOUT=1 "$WORK/helper-lib" 2>/dev/null)

# THE TRAP: drop the documentView constraints and this reads "stack 0x0" while
# every row is still present and correct.
stack=$(echo "$layout" | sed -n 's/^rows [0-9]* stack //p')
case "$stack" in
  0x0|*x0) echo "  FAIL tab: the drawing list laid out at $stack — the tab is blank"; tab_fail=1 ;;
  "") echo "  FAIL tab: no layout reported"; echo "$layout"; tab_fail=1 ;;
  *) echo "  ok   tab: the drawing list has a real size ($stack)" ;;
esac
echo "$layout" | grep -q "Export length" \
  && echo "  ok   tab: the controls below the list are still on screen" \
  || { echo "  FAIL tab: the export row was pushed off the bottom"; tab_fail=1; }
# The drawing recorded by the end-to-end test above must appear, with its buttons.
echo "$layout" | grep -q "session(s)" \
  && echo "  ok   tab: the drawing from the previous test is listed" \
  || { echo "  FAIL tab: no drawing row:"; echo "$layout"; tab_fail=1; }
echo "$layout" | grep -q "Rebuild" \
  && echo "  ok   tab: its actions are there too" \
  || { echo "  FAIL tab: no action buttons"; tab_fail=1; }
# How long is it? That is the first thing anyone wants to know about a video,
# and frames alone do not answer it.
echo "$layout" | grep -qE "session\(s\).*[0-9]+ frames.*[0-9]+s" \
  && echo "  ok   tab: a drawing says how many frames and how long it runs" \
  || { echo "  FAIL tab: no length on the drawing row:"; echo "$layout" | grep "session(s)"; tab_fail=1; }
# THE TRAP: prettyBytes reports whole megabytes, which is right for a folder of
# raw frames and wrong for one video — line art encodes so small that every row
# read "0 MB" next to a real file.
echo "$layout" | grep -q "0 MB" \
  && { echo "  FAIL tab: a real video is reported as 0 MB"; tab_fail=1; } \
  || echo "  ok   tab: small videos are sized in KB, not rounded to 0 MB"

[ "$tab_fail" = 0 ] || exit 1
echo "All tab layout tests passed."

echo ""
echo "== Videos already in the folder are listed, not just counted =="
# Upgrading brings a folder full of videos made before drawings existed as a
# concept. Announcing "nothing recorded yet" beside them reads as though the
# update threw the lot away.
LOOSE="$WORK/loose"; mkdir -p "$LOOSE/cfg" "$LOOSE/videos"
loose_fail=0
printf '%s' "$LOOSE/videos" > "$LOOSE/cfg/timelapse-folder.txt"
: > "$LOOSE/videos/SAI Timelapse 2026-07-28 1632.mp4"
: > "$LOOSE/videos/SAI Timelapse 2026-07-28 1845.mp4"
# Not videos: an unfinished segment and a fingerprint sidecar. Offering to play
# a segment offers something no player will open.
: > "$LOOSE/videos/SAI Timelapse 2026-07-28 2208.NewCanvas1.000.mp4"
: > "$LOOSE/videos/SAI Timelapse 2026-07-29 1522.NewCanvas1.json"
layout=$(SAIPP_CONFIG_DIR="$LOOSE/cfg" SAIPP_SELFTEST_TABLAYOUT=1 "$WORK/helper-lib" 2>/dev/null)

rows=$(echo "$layout" | grep -c "^ *Play ")
[ "$rows" = "2" ] && echo "  ok   loose: both older videos are listed as rows ($rows)" \
  || { echo "  FAIL loose: expected 2 playable rows, got $rows"; echo "$layout"; loose_fail=1; }
echo "$layout" | grep -q "000" \
  && { echo "  FAIL loose: an unfinished segment was offered as a video"; loose_fail=1; } \
  || echo "  ok   loose: unfinished segments are not offered"
echo "$layout" | grep -q "Nothing recorded yet" \
  && { echo "  FAIL loose: claimed nothing was recorded with videos sitting there"; loose_fail=1; } \
  || echo "  ok   loose: does not claim the folder is empty"
echo "$layout" | grep -q "older video(s)" \
  && echo "  ok   loose: the footer counts them" \
  || { echo "  FAIL loose: footer says: $(echo "$layout" | tail -2)"; loose_fail=1; }
# Loose videos get the same facts as drawings do: a real file, not a mystery.
cp "$E2E/videos"/*/*.mp4 "$LOOSE/videos/A real one.mp4" 2>/dev/null
layout2=$(SAIPP_CONFIG_DIR="$LOOSE/cfg" SAIPP_SELFTEST_TABLAYOUT=1 "$WORK/helper-lib" 2>/dev/null)
echo "$layout2" | grep -qE "^ +[0-9]+s · [0-9]+ (KB|MB)" \
  && echo "  ok   loose: each older video says how long it runs and how big it is" \
  || { echo "  FAIL loose: $(echo "$layout2" | grep -E '·' | head -2)"; loose_fail=1; }

# A genuinely empty folder should still say so.
EMPTY="$WORK/emptylib"; mkdir -p "$EMPTY/cfg" "$EMPTY/videos"
printf '%s' "$EMPTY/videos" > "$EMPTY/cfg/timelapse-folder.txt"
SAIPP_CONFIG_DIR="$EMPTY/cfg" SAIPP_SELFTEST_TABLAYOUT=1 "$WORK/helper-lib" 2>/dev/null \
  | grep -q "Nothing recorded yet" \
  && echo "  ok   loose: an empty folder still says so" \
  || { echo "  FAIL loose: no empty state"; loose_fail=1; }

[ "$loose_fail" = 0 ] || exit 1
echo "All loose video tests passed."

echo ""
echo "== An upgrade does not scatter working files among finished videos =="
# A session marker written by an older version names a path in the VIDEOS
# folder. Honouring it made the new build write segments and fingerprint
# sidecars in there, among somebody's finished videos — seen in the wild.
UPG="$WORK/upgrade"; mkdir -p "$UPG/cfg" "$UPG/videos"
printf '%s' "$UPG/videos" > "$UPG/cfg/timelapse-folder.txt"
printf '%s' "$UPG/videos/SAI Timelapse 2026-07-28 1845.mp4" > "$UPG/cfg/timelapse-session.txt"
base=$(SAIPP_CONFIG_DIR="$UPG/cfg" SAIPP_SELFTEST_SESSIONBASE=1 "$WORK/helper-lib" 2>/dev/null)
case "$base" in
  "$UPG/videos/.recording/"*) echo "  ok   upgrade: a stale session marker is ignored" ;;
  *) echo "  FAIL upgrade: recording would write to '$base'"; exit 1 ;;
esac
echo "All upgrade tests passed."

echo ""
echo "== Changing the videos folder reloads the list, without a restart =="
# Two folders, and the app is pointed at the second while it is running. The
# list must show the second folder's contents immediately — and the index has to
# follow, which is why it lives IN the folder: a single global index went on
# describing drawings that were somewhere else entirely.
SWA="$WORK/folderA"; SWB="$WORK/folderB"
mkdir -p "$SWA/cfg" "$SWA/videos" "$SWB/videos"
sw_fail=0
printf '%s' "$SWA/videos" > "$SWA/cfg/timelapse-folder.txt"
cp "$E2E/videos"/*/*.mp4 "$SWA/videos/In folder A.mp4" 2>/dev/null || : > "$SWA/videos/In folder A.mp4"
: > "$SWB/videos/In folder B.mp4"

out=$(SAIPP_CONFIG_DIR="$SWA/cfg" SAIPP_SELFTEST_TABLAYOUT=1 \
      SAIPP_SELFTEST_FOLDERSWITCH="$SWB/videos" "$WORK/helper-lib" 2>/dev/null)
before=$(echo "$out" | sed -n '1,/after switching/p')
after=$(echo "$out" | sed -n '/after switching/,$p')

echo "$before" | grep -q "In folder A" \
  && echo "  ok   folder: the first folder's video is listed to start with" \
  || { echo "  FAIL folder: folder A's video missing"; echo "$before"; sw_fail=1; }
# THE TRAP: refresh only the Recording tab (as the Choose button used to) and
# the list keeps showing folder A while recording goes to folder B.
echo "$after" | grep -q "In folder B" \
  && echo "  ok   folder: switching folders shows the new folder's videos" \
  || { echo "  FAIL folder: folder B's video never appeared"; echo "$after"; sw_fail=1; }
echo "$after" | grep -q "In folder A" \
  && { echo "  FAIL folder: the old folder's videos are still listed"; sw_fail=1; } \
  || echo "  ok   folder: and stops showing the old folder's"

# The index belongs to the folder it describes, so a folder carried elsewhere
# arrives knowing which sessions belong together.
[ -f "$E2E/videos/.library.json" ] \
  && echo "  ok   folder: the index lives in the videos folder" \
  || { echo "  FAIL folder: no .library.json in the videos folder"; sw_fail=1; }

[ "$sw_fail" = 0 ] || exit 1
echo "All folder switching tests passed."

echo ""
echo "== Hovering a still plays the video =="
# A timelapse is motion, and the last frame of two drawings can look much alike.
# The tracking area is AppKit's business; that a row is wired to a player, and
# lets go of it again, is ours — a list of thirty drawings must not hold thirty
# decoders open for something nobody is looking at.
HOV="$WORK/hover"; mkdir -p "$HOV/cfg" "$HOV/videos"
hov_fail=0
printf '%s' "$HOV/videos" > "$HOV/cfg/timelapse-folder.txt"
cp "$E2E/videos"/*/*.mp4 "$HOV/videos/Something.mp4" 2>/dev/null
cp "$E2E/videos"/*/*.mp4 "$HOV/videos/Another one.mp4" 2>/dev/null
out=$(SAIPP_CONFIG_DIR="$HOV/cfg" SAIPP_SELFTEST_TABLAYOUT=1 SAIPP_SELFTEST_HOVER=1 \
      "$WORK/helper-lib" 2>/dev/null)
echo "$out" | grep -q "hoverable 2" \
  && echo "  ok   hover: each video's still is hoverable" \
  || { echo "  FAIL hover: $(echo "$out" | grep hover)"; hov_fail=1; }
echo "$out" | grep -q "hover begin previewing=true" \
  && echo "  ok   hover: pointing at it starts playback" \
  || { echo "  FAIL hover: playback never started"; hov_fail=1; }
echo "$out" | grep -q "hover end previewing=false" \
  && echo "  ok   hover: moving away tears the player down again" \
  || { echo "  FAIL hover: the player was left running"; hov_fail=1; }

# THE TRAP: a CALayer is not clipped by its superlayer unless told to be, so an
# AVPlayerLayer draws the video at its own size straight over the rows below —
# it covered half the tab. The still must simply become a video, in place.
echo "$out" | grep -q "inside=true" \
  && echo "  ok   hover: the video stays inside the still's box" \
  || { echo "  FAIL hover: $(echo "$out" | grep 'hover box')"; hov_fail=1; }
echo "$out" | grep -q "layerFits=true" \
  && echo "  ok   hover: and is sized to it, not to the video" \
  || { echo "  FAIL hover: $(echo "$out" | grep 'hover box')"; hov_fail=1; }
echo "$out" | grep -q "clips=true" \
  && echo "  ok   hover: with clipping on, so nothing can escape it" \
  || { echo "  FAIL hover: the box does not clip"; hov_fail=1; }

# THE OTHER TRAP: a pointer crossing three rows in a second leaves three videos
# decoding behind the one being looked at — invisible, but audible in the fans.
echo "$out" | grep -q "hover concurrent 1 of 2" \
  && echo "  ok   hover: starting one preview stops the last" \
  || { echo "  FAIL hover: $(echo "$out" | grep concurrent)"; hov_fail=1; }

[ "$hov_fail" = 0 ] || exit 1
echo "All hover tests passed."
