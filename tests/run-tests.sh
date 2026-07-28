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
