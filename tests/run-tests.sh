#!/bin/bash
# Build + run all unit tests (native, no tablet/Wine/mingw needed).
# Usage: bash tests/run-tests.sh
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
# Every --watch encoder a test starts is listed here and stopped on the way out,
# pass or fail, so a failing run never leaves one behind. A failing run of the
# orphan tests is exactly the case where one would otherwise outlive the script.
WATCHERS=""
# (`|| true`: set -e applies inside the trap too, and most of these have already
# exited, so a bare failing kill would abort the trap before the rm and turn a
# passing run into exit status 1.)
# A test below leaves one STOPPED (SIGSTOP), and a stopped process holds a SIGTERM
# pending forever, so each one is also continued.
# The quit tests' fake probes can ignore SIGTERM, so they are SIGKILLed by path.
trap 'for p in $WATCHERS; do kill -TERM "$p" 2>/dev/null || true; kill -CONT "$p" 2>/dev/null || true; done; pkill -KILL -f "$WORK/quit/" 2>/dev/null || true; rm -rf "$WORK"' EXIT

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
echo "== Swift core (PenFeelCore.swift) =="
# The pen feel presets and the three custom profiles the user can save.
swiftc -o "$WORK/penfeel-tests" "$REPO/wacom-helper/PenFeelCore.swift" "$REPO/tests/PenFeelTests.swift"
"$WORK/penfeel-tests"

echo ""
echo "== Swift AppKit (PopupMenuSync.swift) =="
# The pen feel dropdown on a real NSPopUpButton, offscreen (no window, no
# clicks): a pick made while the 1 s refresh runs must not be dropped.
swiftc -o "$WORK/popupmenu-tests" "$REPO/wacom-helper/PenFeelCore.swift" \
  "$REPO/wacom-helper/PopupMenuSync.swift" "$REPO/tests/PopupMenuTests.swift"
"$WORK/popupmenu-tests"

echo ""
echo "== Swift core (BridgeCheck.swift) =="
# Is the bridge alive INSIDE SAI? Everything else the app checks is on the mac
# side, and #29 was a prefix where all of that passed while Wine loaded its own
# wintab32. The registry parse below is the check that would have caught it.
swiftc -o "$WORK/bridge-tests" "$REPO/wacom-helper/BridgeCheck.swift" "$REPO/tests/BridgeTests.swift"
"$WORK/bridge-tests"

echo ""
echo "== Swift core (ReportCore.swift) =="
swiftc -o "$WORK/report-tests" "$REPO/wacom-helper/ReportCore.swift" "$REPO/tests/ReportTests.swift"
"$WORK/report-tests"

echo ""
echo "== Swift core (UpdateCore.swift) =="
# The app replaces itself with a file from the internet. What makes that safe is
# three deterministic answers, and each of them has been wrong once already.
swiftc -o "$WORK/update-tests" "$REPO/wacom-helper/UpdateCore.swift" "$REPO/tests/UpdateTests.swift"
"$WORK/update-tests"

echo ""
echo "== Swift core (KeysCore.swift) =="
# Which Mac key sends Alt. For years none did (issue #36): ⌘ was mapped to Ctrl,
# and that silently took away the only key Wine sends as Alt.
swiftc -o "$WORK/keys-tests" "$REPO/wacom-helper/KeysCore.swift" "$REPO/tests/KeysTests.swift"
"$WORK/keys-tests"

echo ""
echo "== Swift core (DisplayCore.swift) =="
# Sharp text on Retina (#39). Turning it off must give back the DPI from
# before; a second "on" must not remember our own 200% as the person's choice.
swiftc -o "$WORK/display-tests" "$REPO/wacom-helper/DisplayCore.swift" "$REPO/tests/DisplayTests.swift"
"$WORK/display-tests"

echo ""
echo "== Swift core (WinePatchCore.swift) =="
# Swapping Wine's Mac driver (issue #39). The backup must only ever hold the
# original, and no Wine but the exact known build may be touched.
swiftc -o "$WORK/winepatch-tests" "$REPO/wacom-helper/WinePatchCore.swift" "$REPO/wacom-helper/WineStatusCore.swift" "$REPO/tests/WinePatchTests.swift"
"$WORK/winepatch-tests"

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
echo "== Every source file is in a build manifest =="
# The list of what each binary is made of used to be written out in three places
# — make-app.sh, this file, and the CI workflow. A release went red when two of
# them still said the helper was main.swift plus PressureCore.swift, which it had
# stopped being when the library tab arrived. There is one list now, and this
# checks it against what is actually on disk: adding a source file without
# listing it is the exact mistake that broke the build, and it fails here rather
# than in CI ten minutes later.
man_fail=0
for f in "$REPO"/wacom-helper/*.swift; do
  grep -q "wacom-helper/$(basename "$f")" "$REPO/wacom-helper/sources.txt" \
    || { echo "  FAIL manifest: $(basename "$f") is not in wacom-helper/sources.txt"; man_fail=1; }
done
for f in "$REPO"/timelapse-encoder/*.swift; do
  b=$(basename "$f")
  # LibraryCore is shared: the helper lists it too, which is the point of it
  # being one file rather than two copies.
  grep -q "timelapse-encoder/$b" "$REPO/timelapse-encoder/sources.txt" \
    || { echo "  FAIL manifest: $b is not in timelapse-encoder/sources.txt"; man_fail=1; }
done
# And every listed file must exist, or the build breaks with a worse message.
for f in $(bash "$REPO/tools/sources.sh" helper) $(bash "$REPO/tools/sources.sh" encoder); do
  [ -f "$f" ] || { echo "  FAIL manifest: $f is listed but missing"; man_fail=1; }
done
[ "$man_fail" = 0 ] || exit 1
echo "  ok   manifest: every helper and encoder source is listed"
echo "  ok   manifest: every listed source exists"
echo "All manifest tests passed."

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

# What the helper is built from lives in wacom-helper/sources.txt, read here
# exactly as make-app.sh and CI read it.
IFS=$'\n' read -r -d '' -a HELPER_SRC < <(bash "$REPO/tools/sources.sh" helper && printf '\0')
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
echo "== An update we would install, and the ones we would not (real filesystem) =="
# The app can now replace itself. That makes "which bundle do we accept?" a
# security question, not a convenience one: whatever comes down the wire gets to
# become the app holding the Input Monitoring grant. Everything except the
# download runs here against real bundles on a real disk.
UPDW="$WORK/update"; mkdir -p "$UPDW"
mkapp() {  # dir version bundleid -> prints the zip path
  local d="$1" app
  app="$d/SAI Pen Pressure.app"
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>stub</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleShortVersionString</key><string>$2</string>
</dict></plist>
PLIST
  printf '#!/bin/bash\necho stub\n' > "$app/Contents/MacOS/stub"
  chmod +x "$app/Contents/MacOS/stub"
  codesign -s - --force "$app" >/dev/null 2>&1
  ( cd "$d" && ditto -c -k --sequesterRsrc --keepParent "SAI Pen Pressure.app" "app.zip" )
  echo "$d/app.zip"
}
ufail=0
uwant() { case "$2" in *"$3"*) echo "  ok   $1";; *) echo "  FAIL $1"; echo "$2" | sed 's/^/        /'; ufail=1;; esac; }

mkdir -p "$UPDW/good"
GOODZIP=$(mkapp "$UPDW/good" "9.9.9" "app.saipenpressure.mac")
DEST="$UPDW/installed/SAI Pen Pressure.app"; mkdir -p "$UPDW/installed"
out=$(SAIPP_CONFIG_DIR="$UPDW/cfg" SAIPP_SELFTEST_UPDATE_ZIP="$GOODZIP" \
      SAIPP_SELFTEST_UPDATE_FROM="0.3.3" SAIPP_SELFTEST_UPDATE_DEST="$DEST" "$WORK/helper-upd")
uwant "update: a newer build of ours unpacks"        "$out" "unpack=ok version=9.9.9"
uwant "update: and is accepted"                      "$out" "verify=ok"
uwant "update: with its signature intact"            "$out" "signature=ok"
uwant "update: the swap is handed off"               "$out" "swapStarted=true"
# The swap waits for the app to quit, so it lands a moment after we do.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$DEST/Contents/Info.plist" ] && break
  osascript -e 'delay 0.5' >/dev/null 2>&1 || true
done
got=$(defaults read "$DEST/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
if [ "$got" = "9.9.9" ]; then echo "  ok   update: the app on disk is the new one"
else echo "  FAIL update: the app on disk is '$got', wanted 9.9.9"; ufail=1; fi


mkdir -p "$UPDW/older"
OLDZIP=$(mkapp "$UPDW/older" "0.1.0" "app.saipenpressure.mac")
out=$(SAIPP_CONFIG_DIR="$UPDW/cfg" SAIPP_SELFTEST_UPDATE_ZIP="$OLDZIP" SAIPP_SELFTEST_UPDATE_FROM="0.3.3" "$WORK/helper-upd")
uwant "update: an older build is refused" "$out" "not newer"

# A bundle that arrived damaged must be caught BEFORE it replaces a working app.
mkdir -p "$UPDW/broken"
BROKENZIP=$(mkapp "$UPDW/broken" "9.9.9" "app.saipenpressure.mac")
rm -f "$BROKENZIP"
printf 'tampered\n' >> "$UPDW/broken/SAI Pen Pressure.app/Contents/MacOS/stub"
( cd "$UPDW/broken" && ditto -c -k --sequesterRsrc --keepParent "SAI Pen Pressure.app" "app.zip" )
out=$(SAIPP_CONFIG_DIR="$UPDW/cfg" SAIPP_SELFTEST_UPDATE_ZIP="$UPDW/broken/app.zip" SAIPP_SELFTEST_UPDATE_FROM="0.3.3" "$WORK/helper-upd")
uwant "update: a tampered bundle is reported as damaged" "$out" "signature=damaged"

# A failed swap must not cost someone their working app. The copy used to
# happen AFTER the installed bundle was deleted, so a ditto that failed for any
# reason left the machine with no app and the updater already exited. Here the
# copy is pointed at a source that does not exist, which is the cheapest way to
# make that step fail on demand.
mkdir -p "$UPDW/survive"
SURVZIP=$(mkapp "$UPDW/survive" "9.9.9" "app.saipenpressure.mac")
SDEST="$UPDW/survive-installed/SAI Pen Pressure.app"
mkdir -p "$SDEST/Contents"
printf 'ORIGINAL' > "$SDEST/Contents/marker.txt"
out=$(SAIPP_CONFIG_DIR="$UPDW/cfg" SAIPP_SELFTEST_UPDATE_ZIP="$SURVZIP" \
      SAIPP_SELFTEST_UPDATE_FROM="0.3.3" SAIPP_SELFTEST_UPDATE_DEST="$SDEST" \
      SAIPP_SELFTEST_UPDATE_BREAK=1 "$WORK/helper-upd")
uwant "update: a swap that cannot copy still starts" "$out" "swapStarted=true"
# The swap waits for the helper to quit, so give it a moment to do its worst.
for _ in 1 2 3 4 5 6; do
  [ -e "$SDEST/Contents/marker.txt" ] || break
  osascript -e 'delay 0.5' >/dev/null 2>&1 || true
done
if [ "$(cat "$SDEST/Contents/marker.txt" 2>/dev/null)" = "ORIGINAL" ]; then
  echo "  ok   update: a failed swap leaves the installed app untouched"
else
  echo "  FAIL update: a failed swap destroyed the installed app"; ufail=1
fi
# And it must not leave its scratch bundles lying beside the app.
if [ -e "$SDEST.update-staged" ] || [ -e "$SDEST.update-previous" ]; then
  echo "  FAIL update: a failed swap left staging bundles behind"; ufail=1
else
  echo "  ok   update: and cleans up after itself"
fi

# GitHub sometimes answers the update check or the download with 503 for a few
# seconds. That used to end the check silently and fail "Update now" on the
# spot. Here a real local server gives those answers and the real request code
# (fetchWithRetry) is run against it, with the waits shortened.
FSRV="$UPDW/fetch"; mkdir -p "$FSRV"
python3 - "$FSRV" <<'PY' &
import http.server, sys, os, collections
d = sys.argv[1]
hits = collections.Counter()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        hits[self.path] += 1
        n = hits[self.path]
        with open(os.path.join(d, "hits" + self.path.replace("/", "-")), "w") as f: f.write(str(n))
        if   self.path == "/flaky":   code = 503 if n <= 2 else 200   # two bad answers, then the file
        elif self.path == "/down":    code = 503                      # never recovers
        elif self.path == "/missing": code = 404
        elif self.path == "/limited": code = 403
        else:                         code = 200
        body = b"HELLO" if code == 200 else b"nope"
        self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(d, "port.tmp"), "w") as f: f.write(str(s.server_address[1]))
os.rename(os.path.join(d, "port.tmp"), os.path.join(d, "port"))
s.serve_forever()
PY
FSRV_PID=$!
WATCHERS="${WATCHERS:-} $FSRV_PID"   # the EXIT trap at the top stops it if we fail early
ucheck() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; ufail=1; fi; }
for _ in $(seq 1 50); do [ -f "$FSRV/port" ] && break; osascript -e 'delay 0.1' >/dev/null 2>&1 || true; done
FPORT="$(cat "$FSRV/port" 2>/dev/null || true)"
if [ -z "$FPORT" ]; then echo "  FAIL fetch: the local test server did not start"; exit 1; fi
fetch() { SAIPP_CONFIG_DIR="$UPDW/cfg" SAIPP_SELFTEST_FETCH_URL="http://127.0.0.1:$FPORT/$1" "$WORK/helper-upd"; }

out=$(fetch flaky)
uwant "fetch: two 503s and then the file: it arrives"      "$out" "status=200 attempts=3"
uwant "fetch: and it is the file, not an error page"        "$out" "body=HELLO"
uwant "fetch: the caller is told about each new try"        "$out" "retries=2"
out=$(fetch down)
uwant "fetch: a server that stays down is given up on after 4 tries" "$out" "status=503 attempts=4"
uwant "fetch: with nothing passed off as the file"          "$out" "body="$'\n'
uwant "fetch: and words a person can read"                  "$out" "says=GitHub is having trouble right now (error 503)"
ucheck "fetch: exactly 4 requests reached the server, not more" "$(cat "$FSRV/hits-down")" "4"
out=$(fetch missing)
uwant "fetch: a 404 is not tried again"                     "$out" "status=404 attempts=1"
out=$(fetch limited)
uwant "fetch: 'too many requests' is not hammered"          "$out" "status=403 attempts=1"
ucheck "fetch: one request only for a 403"                   "$(cat "$FSRV/hits-limited")" "1"
out=$(fetch fine)
uwant "fetch: a good answer needs one try"                  "$out" "status=200 attempts=1 retries=0 body=HELLO"
kill "$FSRV_PID" 2>/dev/null || true
wait "$FSRV_PID" 2>/dev/null || true
# Nobody listening at all: no answer, tried again, then given up on.
out=$(fetch gone)
uwant "fetch: no answer at all is tried 4 times"            "$out" "status=none attempts=4"
uwant "fetch: and points at the connection"                 "$out" "says=no answer from GitHub"

[ "$ufail" = 0 ] || exit 1
echo "All update tests passed."

echo "== The command-line launcher restores the bridge too =="
# install.sh wrote the DllOverrides key once, at install time, and the launcher
# it generates started SAI without ever looking at it again. That one-shot is
# precisely what #29 was: a prefix that lost the key had nothing to put it back
# while every other check stayed green. Both are text, so both are checked as
# text — and the ORDER matters, because wineserver rewrites user.reg when it
# exits, so a repair made after SAI starts is thrown away.
TMPL="$WORK/launcher.tmpl"
awk '/^cat > "\$LAUNCHER"/,/^EOF$/' "$REPO/install.sh" > "$TMPL"
lfail=0
regln=$(grep -n 'reg add' "$TMPL" | head -1 | cut -d: -f1)
sailn=$(grep -n 'sai2.exe' "$TMPL" | head -1 | cut -d: -f1)
if [ -n "$regln" ]; then echo "  ok   launcher: re-asserts the wintab32 override"
else echo "  FAIL launcher: never touches the wintab32 override"; lfail=1; fi
if [ -n "$regln" ] && [ -n "$sailn" ] && [ "$regln" -lt "$sailn" ]; then
  echo "  ok   launcher: does it BEFORE starting SAI"
else echo "  FAIL launcher: the override is not restored before SAI starts"; lfail=1; fi
if grep -q 'reg query' "$REPO/install.sh"; then echo "  ok   install.sh: checks that its own write took"
else echo "  FAIL install.sh: writes the override without checking"; lfail=1; fi

# Reading the template is not the same as running it. Generate the launcher the
# way install.sh does, hand it a `wine` that only records what it was asked to
# do, and watch the order it actually happens in — escaping inside the heredoc
# is easy to get wrong in a way no amount of reading catches.
GEN="$WORK/gen"; mkdir -p "$GEN/prefix/drive_c/SAI2"
export GEN_LOG="$GEN/wine-calls.txt"; : > "$GEN_LOG"
cat > "$GEN/wine" <<'WINESTUB'
#!/bin/bash
echo "$@" >> "$GEN_LOG"
WINESTUB
printf '#!/bin/bash\nexit 0\n' > "$GEN/helper"
chmod +x "$GEN/wine" "$GEN/helper"
(
  PREFIX="$GEN/prefix"
  PREFIX_SAI="$PREFIX/drive_c/SAI2"
  PRESSURE_FILE="$PREFIX/drive_c/wt_pressure.txt"
  HELPER="$GEN/helper"
  WINE="$GEN/wine"
  LAUNCHER="$GEN/launch.command"
  eval "$(cat "$TMPL")"
)
chmod +x "$GEN/launch.command"
GEN_LOG="$GEN_LOG" bash "$GEN/launch.command" >/dev/null 2>&1
reg_line=$(grep -n "reg add" "$GEN_LOG" | head -1 | cut -d: -f1)
sai_line=$(grep -n "sai2.exe" "$GEN_LOG" | head -1 | cut -d: -f1)
if grep -q 'reg add HKCU\\Software\\Wine\\DllOverrides /v wintab32 /t REG_SZ /d native,builtin /f' "$GEN_LOG"
then echo "  ok   launcher: asks wine for exactly the override we mean"
else echo "  FAIL launcher: the reg add came out wrong"; sed 's/^/        /' "$GEN_LOG"; lfail=1; fi
if [ -n "$reg_line" ] && [ -n "$sai_line" ] && [ "$reg_line" -lt "$sai_line" ]; then
  echo "  ok   launcher: and does it before SAI is started, when it still counts"
else echo "  FAIL launcher: wrong order at runtime"; sed 's/^/        /' "$GEN_LOG"; lfail=1; fi
if [ -f "$GEN/prefix/helper.log" ]; then echo "  ok   launcher: still starts the pressure helper"
else echo "  FAIL launcher: the helper never ran"; lfail=1; fi
[ "$lfail" = 0 ] || exit 1
echo "All launcher tests passed."

echo "== A copied report hides the account name by default (real filesystem) =="
# The redaction is only a safeguard if it is ON for someone who never went
# looking for the setting, so the DEFAULT is what matters here. A regression
# that flipped it would publish login names into public issues and break
# nothing else.
RPTW="$WORK/report"; mkdir -p "$RPTW"
rfail=0
rwant() { case "$2" in *"$3"*) echo "  ok   $1";; *) echo "  FAIL $1"; echo "$2" | sed 's/^/        /'; rfail=1;; esac; }
out=$(SAIPP_CONFIG_DIR="$RPTW/cfg" SAIPP_SELFTEST_REPORT=1 "$WORK/helper-upd")
rwant "report: hiding the user name is ON out of the box" "$out" "redactDefault=true"
rwant "report: and a path in the report reads as ~"       "$out" "sample=Prefix: ~/SAI2-pressure"
rwant "report: the switch can be turned off"              "$out" "afterOff=false"
rwant "report: and back on"                               "$out" "afterOn=true"
case "$out" in
  *"$HOME"*) echo "  FAIL report: the sample still contains the real home path"; rfail=1;;
  *) echo "  ok   report: the real home path appears nowhere in the output";;
esac
[ "$rfail" = 0 ] || exit 1
echo "All report tests passed."

echo ""
echo "== The bridge check tells the truth about a prefix (real filesystem) =="
# The check that #29 was missing. Wine loads its OWN wintab32 unless the prefix
# says otherwise, so "our DLL is in place" and "SAI will use our DLL" are two
# different facts — and the app used to state only the first. Each case below is
# a prefix shape a real user has been in, asserted against the same binary the
# app ships. (Reuses the helper built for the update tests above.)
BR="$WORK/bridge"; mkdir -p "$BR/prefix/drive_c"
bridge() { SAI_PREFIX="$BR/prefix" SAIPP_CONFIG_DIR="$BR/cfg" SAIPP_SELFTEST_BRIDGE=1 "$WORK/helper-upd"; }
bfail=0
want() {  # name haystack needle
  case "$2" in *"$3"*) echo "  ok   $1";; *) echo "  FAIL $1"; echo "$2" | sed 's/^/        /'; bfail=1;; esac
}

# A machine that has never been set up is not a broken machine. The first build
# of this row told a fresh install its DLL "isn't the one shipped with this app",
# which is both true and useless — nothing is installed yet.
out=$(bridge)
want "bridge: an empty prefix is pending, not faulty" "$out" "Installed with SAI when you press Launch"

mkdir -p "$BR/prefix/drive_c/SAI2" "$BR/prefix/drive_c/windows/system32"
printf 'EXE' > "$BR/prefix/drive_c/SAI2/sai2.exe"
printf 'DLL' > "$BR/prefix/drive_c/windows/system32/wintab32.dll"
out=$(bridge)
want "bridge: SAI installed but no registry -> not installed" "$out" "installedOK=false"

# The #29 shape: the file is there and correct, the registry sends Wine to its
# own built-in DLL, and every other check in the app passes.
cat > "$BR/prefix/user.reg" <<'REG'
WINE REGISTRY Version 2

[Software\\Wine\\DllOverrides] 1757000001
"wintab32"="builtin,native"
REG
out=$(bridge)
want "bridge: builtin-first override is reported as NOT installed" "$out" "installedOK=false"
want "bridge: and says so in words the user can act on"           "$out" "own wintab32"

sed -i '' 's/builtin,native/native,builtin/' "$BR/prefix/user.reg"
out=$(bridge)
want "bridge: repaired override reads as installed" "$out" "installedOK=true"
case "$out" in
  *saiRunning=false*) want "bridge: with nothing to report until SAI runs" "$out" "While SAI runs";;
  *) echo "  skip bridge: 'nothing to report yet' (SAI is open on this machine)";;
esac

# What the DLL says from inside SAI once it IS running.
printf 'v=1\nbuild=test build\nopen=1\nrecv=100\nposted=90\nfetched=88\npmax=4095\n' \
  > "$BR/prefix/drive_c/wt_status.txt"
out=$(bridge)
want "bridge: a live status file is read as working" "$out" "verdict=working"
want "bridge: and reports what SAI actually drew"    "$out" "88 points"

# Loaded, but SAI was never told to use WinTab — a different fix entirely, and
# one nobody could distinguish from the above before.
printf 'v=1\nbuild=test build\nopen=0\nrecv=0\nposted=0\nfetched=0\npmax=1023\n' \
  > "$BR/prefix/drive_c/wt_status.txt"
out=$(bridge)
want "bridge: loaded but no context is its own diagnosis" "$out" "verdict=noContext"
want "bridge: which points at SAI's own setting"          "$out" "Use WinTab API"

# A status file left over from yesterday must not read as a live bridge.
# Two of these cases assume SAI is NOT on screen: with SAI up and the far side
# silent the app is supposed to say so instead — that IS #29 — so they are
# skipped rather than failed when the machine running the tests has SAI open.
touch -t 202001010000 "$BR/prefix/drive_c/wt_status.txt"
out=$(bridge)
want "bridge: a stale status file is not evidence of a live bridge" "$out" "verdict=notLoaded"
case "$out" in
  *saiRunning=false*) want "bridge: it falls back to what can be checked without SAI" "$out" "While SAI runs";;
  *) echo "  skip bridge: 'falls back without SAI' (SAI is open on this machine)";;
esac

# An install that CANNOT write the override has to say so (#34). Before the fix
# installBridge returned nothing and verified nothing, so a prefix could come out
# of setup with our DLL in place, no override, and no trace anywhere — which is
# what #29 turned out to be. Pointing it at something that isn't wine is the
# cheapest way to make the write fail on purpose.
BR2="$WORK/bridge-install"; mkdir -p "$BR2/prefix/drive_c"
out=$(SAI_PREFIX="$BR2/prefix" SAIPP_CONFIG_DIR="$BR2/cfg" \
      SAIPP_SELFTEST_BRIDGE=install SAIPP_SELFTEST_WINE="$WORK/not-wine" "$WORK/helper-upd")
want "bridge: an install that can't write the override reports failure" "$out" "installBridge=false"
want "bridge: and leaves no override behind to be mistaken for one"     "$out" "override=-"

[ "$bfail" = 0 ] || exit 1
echo "All bridge check tests passed."

echo ""
echo "== Live encoding accumulates instead of overwriting =="
# --watch used to open a fresh AVAssetWriter on every poll, and a new writer
# truncates its output file — so each pass silently threw away everything
# encoded before it. Frames are deleted once consumed, so that lost footage for
# good. This checks the writers stay open across polls.
LIVE="$WORK/live"; mkdir -p "$LIVE/frames"
IFS=$'\n' read -r -d '' -a ENCODER_SRC < <(bash "$REPO/tools/sources.sh" encoder && printf '\0')
swiftc -O -o "$WORK/enc-live" "${ENCODER_SRC[@]}"

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
echo "== A watcher never outlives the app that started it (real filesystem) =="
# The frames folder is SHARED by every session, and a watcher deletes each frame
# it encodes. On 2026-11-06 the app quit through a bare exit(0), which skipped
# stopping its watcher. macOS handed the watcher to launchd, and from 17:16 to
# 19:40 it took every later session's frames into "session 2026-11-06 1716...",
# while the real session's video stayed at 0 bytes. See WatchGuard.swift.
#
# The "app" below is a throwaway bash that starts the watcher as its child and
# waits. SIGKILLing it is exactly what exit(), a crash or a force quit look like
# from the watcher's side: its parent is simply gone, with no word sent.
OWN="$WORK/own"; own_fail=0
start_app() {  # encoder frames out log -> sets APP_PID (the "app") and ENC_PID (its watcher)
  rm -f "$WORK/enc.pid"
  bash -c '"$1" --frames "$2" --out "$3" --fps 5 --watch > "$4" 2>&1 & echo $! > "$5"; wait' \
       _ "$1" "$2" "$3" "$4" "$WORK/enc.pid" > /dev/null 2>&1 &
  APP_PID=$!
  wait_until 5 test -s "$WORK/enc.pid" || { echo "  FAIL own: the watcher did not start"; exit 1; }
  ENC_PID=$(cat "$WORK/enc.pid"); WATCHERS="$WATCHERS $ENC_PID"
}
quit_app() {  # how the app ends doesn't matter to the watcher: it just vanishes
  kill -KILL "$APP_PID"; wait "$APP_PID" 2>/dev/null || true
}
wait_until() {  # seconds command... -> succeeds as soon as the command does
  local end=$((SECONDS + $1)); shift
  until "$@"; do [ "$SECONDS" -ge "$end" ] && return 1; sleep 0.2; done
}
gone() {  # exited. A child of this script that has exited but not been reaped
          # yet is a zombie, which kill -0 still answers for, so that counts too.
  ! kill -0 "$1" 2>/dev/null || [ "$(ps -o stat= -p "$1" 2>/dev/null | cut -c1)" = Z ]
}
stop_watcher() {  # pid -> SIGTERM, as the app stops it; FAILs (status 1) rather than hanging
  # Not SIGINT: bash starts background jobs with SIGINT ignored, so one sent in
  # the few milliseconds before the watcher installs its handlers is dropped.
  # SIGTERM in that window simply kills it, as it does when the app sends it.
  kill -TERM "$1" 2>/dev/null || true
  if ! wait_until 10 gone "$1"; then
    echo "  FAIL watcher $1 did not stop on SIGTERM"; kill -KILL "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true; return 1
  fi
  wait "$1" 2>/dev/null || true
}
no_frames() { [ -z "$(ls -A "$1" 2>/dev/null)" ]; }
probe_of()  { "$WORK/enc-live" --probe "$1" 2>/dev/null || echo "no video"; }

# --- 1. the app goes: its watcher closes its video, and takes nothing more ---
P1="$OWN/parentless"; mkdir -p "$P1/frames" "$P1/rec"
mkframes 1 3 AAAA Sketch 64 48 "$P1/frames"
start_app "$WORK/enc-live" "$P1/frames" "$P1/rec/session 1716.mp4" "$P1/old.log"
wait_until 10 no_frames "$P1/frames" \
  || { echo "  FAIL own: the watcher never read its own session's frames"; cat "$P1/old.log"; exit 1; }
quit_app
# THE TRAP: delete the parentIsGone() check in main.swift's watch loop and this
# goes red. The watcher carries on as a child of launchd, and the next two
# checks go red with it, because it takes the next session's frames.
wait_until 5 gone "$ENC_PID" \
  && echo "  ok   own: a watcher stops once the app that started it has gone" \
  || { echo "  FAIL own: the watcher outlived its app (pid $ENC_PID, parent now $(ps -o ppid= -p "$ENC_PID"))"; own_fail=1; }
p=$(probe_of "$P1/rec/session 1716.Sketch.000.mp4")
[ "$p" = "64x48 0.60s" ] && echo "  ok   own: it closed its own video first, all 3 frames playable ($p)" \
  || { echo "  FAIL own: the old session's video is '$p', want 64x48 0.60s"; own_fail=1; }
grep -q "the app that started this watcher has gone" "$P1/old.log" \
  && echo "  ok   own: and it says why it stopped" \
  || { echo "  FAIL own: no reason in the log:"; cat "$P1/old.log"; own_fail=1; }

# The next session starts drawing before its own watcher is up.
mkframes 4 8 BBBB NewCanvas1 64 48 "$P1/frames"
sleep 2.5                                   # two polls of anything still there
left=$(ls "$P1/frames" | wc -l | tr -d ' ')
[ "$left" = 5 ] && echo "  ok   own: the next session's frames wait for the next session's watcher" \
  || { echo "  FAIL own: $left of 5 new frames left; something else took them"; own_fail=1; }
ls "$P1/rec" | grep -q "^session 1716.NewCanvas1" \
  && { echo "  FAIL own: the new canvas was recorded into the OLD session"; ls "$P1/rec"; own_fail=1; } \
  || echo "  ok   own: nothing of the new canvas lands in the old session"
"$WORK/enc-live" --frames "$P1/frames" --out "$P1/rec/session 1939.mp4" --fps 5 --watch > "$P1/new.log" 2>&1 &
NEW=$!; WATCHERS="$WATCHERS $NEW"
wait_until 10 no_frames "$P1/frames" || true
stop_watcher "$NEW" || own_fail=1
p=$(probe_of "$P1/rec/session 1939.NewCanvas1.000.mp4")
[ "$p" = "64x48 1.00s" ] && echo "  ok   own: the new session's video holds all 5 of its frames ($p)" \
  || { echo "  FAIL own: the new session's video is '$p', want 64x48 1.00s"; own_fail=1; }

# --- 2. an orphan from 0.3.6 is stopped before the new session reads a frame -
# 0.3.6 has no parent check, so an orphan it left will never stop by itself:
# the one on 2026-11-06 ran for hours. Upgrading does not end it either. So a new
# watcher has to stop it, AND wait until it has closed its video, before reading.
# The stand-in is the real encoder with PreFixWatchGuard.swift linked in place
# of WatchGuard.swift, under the shipped name, as an installed copy would be.
mkdir -p "$WORK/v036"
IFS=$'\n' read -r -d '' -a PREFIX_SRC < <(bash "$REPO/tools/sources.sh" encoder \
                                          | grep -v '/WatchGuard\.swift$' && printf '\0')
swiftc -O -o "$WORK/v036/sai-timelapse-encoder" "${PREFIX_SRC[@]}" \
       "$REPO/tests/PreFixWatchGuard.swift" 2>/dev/null
P2="$OWN/orphan"; mkdir -p "$P2/frames" "$P2/rec"
mkframes 1 3 AAAA Sketch 64 48 "$P2/frames"
start_app "$WORK/v036/sai-timelapse-encoder" "$P2/frames" "$P2/rec/session 1716.mp4" "$P2/old.log"
wait_until 10 no_frames "$P2/frames" \
  || { echo "  FAIL orphan: the stand-in never read its frames"; cat "$P2/old.log"; exit 1; }
quit_app; OLD=$ENC_PID
sleep 1.5
# The stand-in has to reproduce the bug, or everything after this proves nothing.
if ! gone "$OLD" && [ "$(ps -o ppid= -p "$OLD" | tr -d ' ')" = 1 ]; then
  echo "  ok   orphan: the 0.3.6 stand-in really is left running under launchd"
else
  echo "  FAIL orphan: the stand-in did not stay behind as an orphan; this test is void"; exit 1
fi
"$WORK/enc-live" --frames "$P2/frames" --out "$P2/rec/session 1939.mp4" --fps 5 --watch > "$P2/new.log" 2>&1 &
NEW=$!; WATCHERS="$WATCHERS $NEW"
# THE TRAP: delete the stopOrphanedWatchers() call in main.swift and this goes
# red. The orphan carries on, and the two watchers race for every new frame.
wait_until 10 gone "$OLD" \
  && echo "  ok   orphan: a new watcher stops the orphan on its folder" \
  || { echo "  FAIL orphan: the orphan (pid $OLD) is still running beside the new watcher"; own_fail=1; }
p=$(probe_of "$P2/rec/session 1716.Sketch.000.mp4")
[ "$p" = "64x48 0.60s" ] && echo "  ok   orphan: which closed its own video first, all 3 frames playable ($p)" \
  || { echo "  FAIL orphan: the orphan's video is '$p', want 64x48 0.60s. Its folder and log:";
       ls -l "$P2/rec"; cat "$P2/old.log"; own_fail=1; }
mkframes 4 8 BBBB NewCanvas1 64 48 "$P2/frames"
wait_until 10 no_frames "$P2/frames" || true
stop_watcher "$NEW" || own_fail=1
p=$(probe_of "$P2/rec/session 1939.NewCanvas1.000.mp4")
[ "$p" = "64x48 1.00s" ] && echo "  ok   orphan: the new session's video holds all 5 of its frames ($p)" \
  || { echo "  FAIL orphan: the new session's video is '$p', want 64x48 1.00s"; own_fail=1; }
ls "$P2/rec" | grep -q "^session 1716.NewCanvas1" \
  && { echo "  FAIL orphan: the orphan recorded the new canvas"; ls "$P2/rec"; own_fail=1; } \
  || echo "  ok   orphan: and none of them land in the orphan's session"
grep -q "stopping an orphaned watcher on this folder (pid $OLD)" "$P2/new.log" \
  && echo "  ok   orphan: the new watcher says which process it stopped" \
  || { echo "  FAIL orphan: nothing in the log:"; cat "$P2/new.log"; own_fail=1; }

# --- 2b. a watcher still waiting for an orphan can still be stopped --------
# THE TRAP: the new watcher WAITS for the orphan to close its video. If its
# Ctrl-C/SIGTERM handlers are installed only after that wait (they once were),
# a stop sent during it is lost: bash starts background jobs with SIGINT
# ignored, so the watcher sat there and the script hung. The orphan here is
# frozen with SIGSTOP, so the wait is guaranteed to be in progress.
#
# The frozen orphan has an EMPTY folder, so it holds no open video while it is
# frozen. It used to have frames, and the check ended with "its video is whole".
# On GitHub's macOS runner that failed once (2026-11-11, main 7b9ca10): the
# orphan woke, exited, and left no playable video. It never failed here, not in
# 45 repeats with every core busy or a 10 s freeze, so why is not known. Freezing
# a process in the middle of a video encoder is a test device, not something
# that happens to a real orphan, and "an orphan closes its own video when a new
# watcher stops it" is checked in section 2 above without freezing anything.
# So this section checks only what it is for, and nothing that needs an encoder
# to survive SIGSTOP. Do not give the frozen orphan frames again.
P2B="$OWN/stalled"; mkdir -p "$P2B/frames" "$P2B/rec"
start_app "$WORK/v036/sai-timelapse-encoder" "$P2B/frames" "$P2B/rec/session 1716.mp4" "$P2B/old.log"
quit_app; STALLED=$ENC_PID
# The new watcher only stops processes whose parent is launchd (pid 1). If this
# stand-in is not one yet, nothing below means anything.
wait_until 5 test "$(ps -o ppid= -p "$STALLED" 2>/dev/null | tr -d ' ')" = 1 \
  || { echo "  FAIL stalled: the stand-in did not stay behind as an orphan; this test is void"; exit 1; }
kill -STOP "$STALLED"
"$WORK/enc-live" --frames "$P2B/frames" --out "$P2B/rec/session 1939.mp4" --fps 5 --watch > "$P2B/new.log" 2>&1 &
NEW=$!; WATCHERS="$WATCHERS $NEW"
sleep 1.5                                   # it has signalled the orphan and is waiting
gone "$NEW" && { echo "  FAIL stalled: the new watcher did not wait for the orphan"; own_fail=1; }
kill -INT "$NEW" 2>/dev/null || true
wait_until 3 gone "$NEW" \
  && echo "  ok   stalled: a watcher waiting for an orphan still stops on Ctrl-C" \
  || { echo "  FAIL stalled: Ctrl-C was lost while it waited for the orphan"; own_fail=1;
       kill -KILL "$NEW" 2>/dev/null || true; }
wait "$NEW" 2>/dev/null || true
# It was waiting for THIS orphan, not merely slow to start: it says so on the way.
grep -q "stopping an orphaned watcher on this folder (pid $STALLED)" "$P2B/new.log" \
  && echo "  ok   stalled: and what it was waiting for was the frozen orphan" \
  || { echo "  FAIL stalled: the new watcher never asked the orphan to stop; its log:";
       cat "$P2B/new.log"; own_fail=1; }
# Let the orphan go: the SIGTERM it was sent is still pending, and it must still
# act on it once it runs again.
kill -CONT "$STALLED"
wait_until 10 gone "$STALLED" \
  && echo "  ok   stalled: the orphan acts on the stop it was sent once it runs again" \
  || { echo "  FAIL stalled: the orphan (pid $STALLED) is still running"; own_fail=1;
       kill -KILL "$STALLED" 2>/dev/null || true; }

# --- 3. and nobody else's ---------------------------------------------------
# A wrong "this is an orphan on my folder" sends SIGTERM to somebody else's
# process. A watcher whose app is still running is that app's own, and an orphan
# on another folder is stealing from nobody here.
P3="$OWN/others"; mkdir -p "$P3/frames" "$P3/elsewhere" "$P3/rec"
start_app "$WORK/v036/sai-timelapse-encoder" "$P3/frames" "$P3/rec/live.mp4" "$P3/live.log"
LIVE_APP=$APP_PID; LIVE=$ENC_PID
start_app "$WORK/v036/sai-timelapse-encoder" "$P3/elsewhere" "$P3/rec/other.mp4" "$P3/other.log"
quit_app; OTHER=$ENC_PID
sleep 1
"$WORK/enc-live" --frames "$P3/frames" --out "$P3/rec/new.mp4" --fps 5 --watch > "$P3/new.log" 2>&1 &
NEW=$!; WATCHERS="$WATCHERS $NEW"
sleep 2
gone "$LIVE" && { echo "  FAIL others: stopped a watcher whose app is still running"; own_fail=1; } \
  || echo "  ok   others: a watcher whose app is still running is left alone"
gone "$OTHER" && { echo "  FAIL others: stopped an orphan on a different folder"; own_fail=1; } \
  || echo "  ok   others: an orphan on a different folder is left alone"
stop_watcher "$NEW" || own_fail=1
kill -TERM "$LIVE" "$OTHER" 2>/dev/null || true
wait_until 5 gone "$LIVE" || true; wait_until 5 gone "$OTHER" || true
wait "$LIVE_APP" 2>/dev/null || true

[ "$own_fail" = 0 ] || exit 1
echo "All watcher lifetime tests passed."

echo ""
echo "== Every exit from the running app ends the recording first =="
# THE TRAP: exit() is not Quit. It skips applicationWillTerminate, and a bare
# exit(0) in pollUntilSAICloses is how the orphan above came about. The encoder
# now stops by itself when the app vanishes, but only endRecordingAndExit() also
# FINISHES the session; skip it and the next launch writes into a half-open one.
# The app cannot be launched here, so this reads the source: no exit() anywhere
# in the running app except the one inside endRecordingAndExit.
#   * main.swift above `final class SetupController` is command-line modes that
#     run instead of the app, so only the part from there on is checked;
#   * a developer hook (SAIPP_TEST_*) may exit within a few lines of its check.
bare=$(awk '
  FNR == 1 { app = (FILENAME !~ /\/main\.swift$/); inside = 0; hook = -100 }
  FILENAME ~ /\/main\.swift$/ && /^final class SetupController/ { app = 1 }
  /SAIPP_TEST_/ { hook = FNR }
  /^func endRecordingAndExit/ { inside = 1 }
  inside { if (/^}/) inside = 0; next }
  app && FNR - hook > 4 && /(^|[^A-Za-z0-9_])_?exit\(/ && $0 !~ /^[[:space:]]*\/\// {
    n = split(FILENAME, parts, "/"); print "    " parts[n] ":" FNR ": " $0
  }' "$REPO"/wacom-helper/*.swift)
if [ -z "$bare" ]; then
  echo "  ok   exits: every exit from the running app goes through endRecordingAndExit"
else
  echo "  FAIL exits: a bare exit() in the running app skips ending the recording:"
  echo "$bare"; exit 1
fi
# And the exit that actually left the orphan behind is one of them.
awk '/^func pollUntilSAICloses/,/^}/' "$REPO/wacom-helper/SAIProcess.swift" \
  | grep -q "endRecordingAndExit(" \
  && echo "  ok   exits: quitting because SAI closed is one of them" \
  || { echo "  FAIL exits: pollUntilSAICloses no longer ends the recording"; exit 1; }
echo "All exit tests passed."

echo ""
echo "== Nothing the app started outlives it (real processes) =="
# macOS does not end a child when its parent exits. On 2026-11-11 a Test pen
# probe (wtprobe.exe) left running inside Wine after the app had gone held the
# pen port, and SAI read the pen from a file and missed quick strokes. The probe
# was stopped by Stop Test and before Launch, and by NOTHING on the way out:
# not by Quit (applicationWillTerminate), not when SAI closed
# (endRecordingAndExit), not on a kill or a closed terminal (no signal handling).
#
# The "app" here is tests/QuitStandIn.swift, built from the app's own
# ChildCleanup.swift and BridgeCheck.swift. Its "probe" is tests/fake_wtprobe.c:
# same name, and like the leftover it does not end when its pipe closes.
# "stubborn" ones also ignore SIGTERM, as the Windows program behind the wine
# loader can. ps decides every answer. Only fakes under $WORK/quit are touched.
QD="$WORK/quit"; mkdir -p "$QD"; quit_fail=0
cc -Wall -Wextra -Werror -o "$QD/wtprobe.exe" "$REPO/tests/fake_wtprobe.c"
swiftc -o "$WORK/quit-standin" "$REPO/wacom-helper/ChildCleanup.swift" \
  "$REPO/wacom-helper/BridgeCheck.swift" "$REPO/tests/QuitStandIn.swift"
alive() {  # running, and not a zombie waiting to be reaped
  local st; st=$(ps -o stat= -p "$1" 2>/dev/null | cut -c1)
  [ -n "$st" ] && [ "$st" != Z ]
}
probe_pid() {  # pid file -> the fake probe's pid, once the stand-in has written it
  wait_until 5 test -s "$1" || { echo "  FAIL quit: the stand-in never started its probe"; exit 1; }
  cat "$1"
}
# Is the probe still there a moment after the app has gone? 1.5 s is longer
# than any probe takes to end on its own pipe check (one tick, 100 ms).
outlived() { sleep 1.5; alive "$1"; }

# --- 0. the controls: without cleanup, the fake really does outlive the app ---
# Without these, every "gone" below could be passing because the fake ends by
# itself, and the tests would prove nothing.
rm -f "$QD/pid"; "$WORK/quit-standin" bare-exit "$QD" 60 polite "$QD/pid" > /dev/null
pid=$(probe_pid "$QD/pid")
if outlived "$pid"; then
  echo "  ok   control: a bare exit leaves the probe running (parent now $(ps -o ppid= -p "$pid" | tr -d ' '))"
else
  echo "  FAIL control: the fake probe ended with its app, so these tests prove nothing"; quit_fail=1
fi
kill -KILL "$pid" 2>/dev/null || true
rm -f "$QD/pid"; "$WORK/quit-standin" no-handler "$QD" 60 polite "$QD/pid" > /dev/null &
app=$!; pid=$(probe_pid "$QD/pid"); kill -TERM "$app"; wait "$app" 2>/dev/null || true
if outlived "$pid"; then
  echo "  ok   control: SIGTERM with no handler ends the app and leaves the probe"
else
  echo "  FAIL control: the probe ended with an unhandled SIGTERM, so the signal tests prove nothing"; quit_fail=1
fi
kill -KILL "$pid" 2>/dev/null || true

# --- 1. Quit and every exit through endRecordingAndExit ---
# THE TRAP: ChildCleanup.stop must be synchronous. BridgeProbeStream.stop()
# schedules its SIGKILL two seconds later, and the app has exited by then. Make
# stop() return right after the SIGTERM, or drop its SIGKILL, and "stubborn"
# goes red.
for kind in polite stubborn; do
  rm -f "$QD/pid"
  res=$("$WORK/quit-standin" quit "$QD" 60 "$kind" "$QD/pid")
  pid=$(probe_pid "$QD/pid")
  if outlived "$pid"; then
    echo "  FAIL quit: a $kind probe outlived the app ($res; pid $pid, parent now $(ps -o ppid= -p "$pid" | tr -d ' '))"
    quit_fail=1; kill -KILL "$pid" 2>/dev/null || true
  else
    echo "  ok   quit: a $kind probe is gone once the app has exited ($res)"
  fi
done

# THE TRAP: the cleanup must never stop the app itself. A command line that
# only MENTIONS a probe's path matches as a probe, and this stand-in's does here
# (the extra argument). Drop the getpid() filter in ChildCleanup.stop and the
# stand-in SIGTERMs itself mid-cleanup: status 143, and the probe may be left.
rm -f "$QD/pid"; st=0
res=$("$WORK/quit-standin" quit "$QD" 60 polite "$QD/pid" "$QD/wtprobe.exe") || st=$?
pid=$(probe_pid "$QD/pid")
if outlived "$pid"; then
  echo "  FAIL quit: the probe outlived an app whose command line mentions it (status $st, $res)"
  quit_fail=1; kill -KILL "$pid" 2>/dev/null || true
elif [ "$st" != 0 ] || [ "$res" != "cleanup: found 1, left 0" ]; then
  echo "  FAIL quit: the cleanup stopped the app itself (status $st, '$res')"; quit_fail=1
else
  echo "  ok   quit: the cleanup never stops the app itself"
fi

# --- 2. a signal: kill, killall, a closed terminal ---
# THE TRAP: remove the signal() line in ChildCleanup.exitCleanlyOnSignals and
# the default action ends the app before the dispatch source can run, which is
# the no-handler control above. Every one of these goes red.
for sig in TERM INT HUP; do
  rm -f "$QD/pid"
  "$WORK/quit-standin" signals "$QD" 60 stubborn "$QD/pid" > "$QD/sig.log" &
  app=$!; pid=$(probe_pid "$QD/pid")
  kill -"$sig" "$app"
  if ! wait_until 5 gone "$app"; then
    echo "  FAIL signal: SIG$sig did not end the app"; quit_fail=1; kill -KILL "$app" 2>/dev/null || true
  fi
  st=0; wait "$app" 2>/dev/null || st=$?   # (|| keeps set -e from ending the run here)
  if outlived "$pid"; then
    echo "  FAIL signal: SIG$sig left the probe running (app status $st: $(cat "$QD/sig.log"))"
    quit_fail=1; kill -KILL "$pid" 2>/dev/null || true
  elif [ "$st" != 0 ] || ! grep -q "cleanup: found 1, left 0" "$QD/sig.log"; then
    # Status 0 and the cleanup line: the app exited through its own cleanup,
    # rather than being killed by the signal while the probe died some other way.
    echo "  FAIL signal: SIG$sig did not go through the cleanup (status $st: $(cat "$QD/sig.log"))"; quit_fail=1
  else
    echo "  ok   signal: SIG$sig stops the probe, then exits cleanly"
  fi
done

# --- 3. a quit with nothing to stop stays quick ---
res=$("$WORK/quit-standin" nothing)
ms=${res##*ms=}
case "$res" in
  "found=0 left=0 "*) [ "$ms" -lt 1000 ] && echo "  ok   quit: with nothing running the cleanup costs ${ms} ms" \
                       || { echo "  FAIL quit: the cleanup took ${ms} ms with nothing to stop"; quit_fail=1; } ;;
  *) echo "  FAIL quit: the cleanup found something that is not ours: $res"; quit_fail=1 ;;
esac

# --- 4. the app wires it to every way out ---
# The app cannot be launched here, so this reads the source. THE TRAP each line
# guards: a way out that does not call stopChildrenBeforeExit leaves the probe.
fn() { awk -v f="$1" '$0 ~ f, /^(    )?}/' "$2"; }
fn "func applicationWillTerminate" "$REPO/wacom-helper/main.swift" | grep -q "stopChildrenBeforeExit()" \
  && echo "  ok   wired: Quit (applicationWillTerminate) stops the children" \
  || { echo "  FAIL wired: applicationWillTerminate does not call stopChildrenBeforeExit"; quit_fail=1; }
fn "^func endRecordingAndExit" "$REPO/wacom-helper/SAIProcess.swift" | grep -q "stopChildrenBeforeExit()" \
  && echo "  ok   wired: endRecordingAndExit (SAI closed, relaunch, signals) stops the children" \
  || { echo "  FAIL wired: endRecordingAndExit does not call stopChildrenBeforeExit"; quit_fail=1; }
body=$(fn "^func stopChildrenBeforeExit" "$REPO/wacom-helper/SAIProcess.swift" | grep -v '^ *//')
order=$(printf '%s\n' "$body" | grep -oE "stopLiveEncoder\(\)|probeStream\.stop\(\)|stopStrayProbes\(" | tr '\n' ' ')
# probeStream.stop() BEFORE stopStrayProbes: it clears `wanted`, and the stream
# otherwise starts a new probe two seconds after the old one is killed.
[ "$order" = "stopLiveEncoder() probeStream.stop() stopStrayProbes( " ] \
  && echo "  ok   wired: it stops the encoder, the probe stream, then any probe left" \
  || { echo "  FAIL wired: stopChildrenBeforeExit calls '$order'"; quit_fail=1; }
awk '/ChildCleanup\.exitCleanlyOnSignals/ { s = NR } /^nsApp\.run\(\)/ { r = NR } END { exit !(s && r && s < r) }' \
  "$REPO/wacom-helper/main.swift" \
  && grep -q "exitCleanlyOnSignals { endRecordingAndExit() }" "$REPO/wacom-helper/main.swift" \
  && echo "  ok   wired: signals reach endRecordingAndExit, installed before the app runs" \
  || { echo "  FAIL wired: the app does not route SIGTERM/SIGINT/SIGHUP to endRecordingAndExit"; quit_fail=1; }
[ "$quit_fail" = 0 ] || exit 1
echo "All quit tests passed."

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

# THE TRAP: --finalize puts the leftover frames in a NEW segment, and creating a
# segment deletes whatever is at its path. It used to number from .000 like the
# watcher, so it deleted the watcher's segment and kept only the 3 leftovers.
# The sidecar above still said 9 frames, so only the VIDEO's length catches it:
# all 9 frames at 5fps is 1.80s, the leftovers alone 0.60s. Make
# LiveWriter.append count from 0 again and this goes red.
p=$("$WORK/enc-live" --probe "$REB/out/session.Sketch.mp4" 2>/dev/null || echo "no video")
[ "$p" = "64x48 1.80s" ] \
  && echo "  ok   session: the finished video holds both runs, all 9 frames ($p)" \
  || { echo "  FAIL session: the finished video is '$p', want 64x48 1.80s (0.60s: --finalize replaced the watcher's segment)"; reb_fail=1; }

# The same trap one step earlier: a watcher restarted on the same session (the
# app brings back one that died, and a relaunched app keeps the session) used to
# start at .000 again and delete the first run's video before --finalize ran.
RST="$REB/restarted"; mkdir -p "$RST/frames" "$RST/out"
restart_run() {  # first last
  mkframes "$1" "$2" CAFE Sketch 64 48 "$RST/frames"
  "$WORK/enc-live" --frames "$RST/frames" --out "$RST/out/session.mp4" --fps 5 --watch \
      >> "$RST/log" 2>&1 &
  local pid=$!; WATCHERS="$WATCHERS $pid"
  wait_until 10 no_frames "$RST/frames" || { echo "  FAIL restart: frames $1-$2 were not read"; reb_fail=1; }
  stop_watcher "$pid" || reb_fail=1
}
restart_run 1 3
restart_run 4 7
p0=$(probe_of "$RST/out/session.Sketch.000.mp4"); p1=$(probe_of "$RST/out/session.Sketch.001.mp4")
[ "$p0" = "64x48 0.60s" ] && [ "$p1" = "64x48 0.80s" ] \
  && echo "  ok   restart: the second run starts .001 and the first run's .000 is untouched" \
  || { echo "  FAIL restart: .000 is '$p0' (want 0.60s), .001 is '$p1' (want 0.80s)"; ls "$RST/out"; reb_fail=1; }
"$WORK/enc-live" --frames "$RST/frames" --out "$RST/out/session.mp4" --fps 5 --finalize >> "$RST/log" 2>&1 \
  || { echo "  FAIL restart: --finalize failed"; cat "$RST/log"; reb_fail=1; }
p=$(probe_of "$RST/out/session.Sketch.mp4")
[ "$p" = "64x48 1.40s" ] && echo "  ok   restart: and the finished video holds both runs in order ($p)" \
  || { echo "  FAIL restart: the finished video is '$p', want 64x48 1.40s"; reb_fail=1; }

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
  python3 - "${SESSION_DIR:-$LIB/.recording}" "$@" <<'PYSESSION'
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
[ -f "$LIB/Sketch $(TZ=UTC date -r 1785103200 '+%Y-%m-%d %H%M' 2>/dev/null)/pieces/2026-07-27 2015.mp4" ] || [ -n "$(find "$LIB" -path '*/pieces/2026-07-27 2015.mp4')" ] \
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
echo "$out" | grep -q "2026-07-27 2015.mp4, 2026-07-28 1903.mp4" \
  && echo "  ok   filing: both evenings are in it, in the order drawn" \
  || { echo "  FAIL filing: $out"; lib_fail=1; }

# Saving an untitled drawing renames the canvas. It is the same drawing, so it
# must stay ONE folder — and stop being labelled with SAI's default name, which
# is what the folder was created with. The folder never changes (files would have
# to move); the label follows the canvas.
echo "$out" | grep -qE "^drawing Sketch [0-9-]+ [0-9]+ .final v2.:" \
  && echo "  ok   filing: a renamed canvas relabels its drawing instead of adding one" \
  || { echo "  FAIL filing: label not updated: $out"; lib_fail=1; }
[ "$(echo "$out" | grep -c '^drawing ')" = "1" ] \
  && echo "  ok   filing: and there is still exactly one drawing" \
  || { echo "  FAIL filing: more than one drawing after a rename: $out"; lib_fail=1; }

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
echo "$out" | grep -qE ": 2026-07-27 2015.mp4, 2026-07-28 1903.mp4$" \
  && echo "  ok   filing: and is NOT quietly added to the drawing it might belong to" \
  || { echo "  FAIL filing: the pending session was merged anyway: $out"; lib_fail=1; }

# Answering "same drawing" moves it across — on disk, not just in the index.
out=$(file_them env SAIPP_SELFTEST_CONFIRM=same)
echo "$out" | grep -q "confirmed same -> Sketch" \
  && echo "  ok   confirm: answering yes moves the session into the drawing" \
  || { echo "  FAIL confirm: $out"; lib_fail=1; }
[ -n "$(find "$LIB" -path '*/pieces/2026-07-30 2100.mp4')" ] \
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

folder=$(echo "$out2" | sed -n 's/^drawing \(.*\) \[.*/\1/p' | head -1)
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
echo "$layout" | grep -qE "[0-9]+ sessions? · " \
  && echo "  ok   tab: the drawing from the previous test is listed" \
  || { echo "  FAIL tab: no drawing row:"; echo "$layout"; tab_fail=1; }
echo "$layout" | grep -q "popup\[More|Rename…|Sessions…|Rebuild video||Delete…\]" \
  && echo "  ok   tab: its actions are there too (Play, Export, and the More menu)" \
  || { echo "  FAIL tab: no action buttons"; tab_fail=1; }
# How long is it? That is the first thing anyone wants to know about a video,
# and frames alone do not answer it.
echo "$layout" | grep -qE "[0-9]+ sessions? · [0-9]+ frames? · [0-9]+s" \
  && echo "  ok   tab: a drawing says how many frames and how long it runs" \
  || { echo "  FAIL tab: no length on the drawing row:"; echo "$layout" | grep "session"; tab_fail=1; }
# THE TRAP: prettyBytes reports whole megabytes, which is right for a folder of
# raw frames and wrong for one video — line art encodes so small that every row
# read "0 MB" next to a real file.
# Counts are spelled out: "1 session", never "1 session(s)".
echo "$layout" | grep -q "(s)" \
  && { echo "  FAIL tab: a count still reads \"(s)\":"; echo "$layout" | grep "(s)"; tab_fail=1; } \
  || echo "  ok   tab: counts say 1 session / 2 sessions, not session(s)"
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

# Counted by the app, not by grepping its view dump: an NSButton has an inner
# view carrying the same title on some macOS versions, so counting rows by their
# button text read 2 locally and 4 on CI.
echo "$layout" | grep -q "rows drawings=0 loose=2" \
  && echo "  ok   loose: both older videos are listed as rows" \
  || { echo "  FAIL loose: $(echo "$layout" | grep '^rows ')"; echo "$layout"; loose_fail=1; }
echo "$layout" | grep -q "000" \
  && { echo "  FAIL loose: an unfinished segment was offered as a video"; loose_fail=1; } \
  || echo "  ok   loose: unfinished segments are not offered"
echo "$layout" | grep -q "Nothing recorded yet" \
  && { echo "  FAIL loose: claimed nothing was recorded with videos sitting there"; loose_fail=1; } \
  || echo "  ok   loose: does not claim the folder is empty"
echo "$layout" | grep -qE "^ *[0-9]+ older videos?( ·| [0-9]+x[0-9]+$)" \
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

echo ""
echo "== A damaged library index does not take the drawings with it =="
# The index is the only record of which sessions belong to which drawing. It
# used to be read with `try?` and ignored on failure — so one truncated write
# (a full disk, a power cut mid-save) left an empty library in memory, and the
# next save wrote that emptiness over the file. The videos survived; knowing
# what they were did not.
BRK="$WORK/broken"; mkdir -p "$BRK/Sketch/pieces" "$BRK/Portrait/pieces"
brk_fail=0
: > "$BRK/Sketch/pieces/2026-07-27 2015.mp4"
: > "$BRK/Sketch/pieces/2026-07-28 1903.mp4"
: > "$BRK/Portrait/pieces/2026-07-29 1000.mp4"
printf '{"drawings":[{"id":"d1","title":"Sk' > "$BRK/.library.json"     # cut off mid-write
out=$(SAIPP_SELFTEST_LIBRARY="$BRK" "$WORK/helper-lib" 2>&1)

echo "$out" | grep -q "recovered from a broken index" \
  && echo "  ok   broken: the damage is noticed rather than ignored" \
  || { echo "  FAIL broken: $out"; brk_fail=1; }
# THE TRAP: delete the recovery and both of these go red — the drawings vanish
# while their videos sit there ungrouped.
echo "$out" | grep -q "2026-07-27 2015.mp4, 2026-07-28 1903.mp4" \
  && echo "  ok   broken: a drawing's sessions are recovered from its folder" \
  || { echo "  FAIL broken: Sketch not recovered: $out"; brk_fail=1; }
echo "$out" | grep -q "drawing Portrait [[]Portrait[]]: 2026-07-29 1000.mp4" \
  && echo "  ok   broken: and so is every other drawing" \
  || { echo "  FAIL broken: Portrait not recovered"; brk_fail=1; }
# The unreadable file is evidence: never quietly replaced.
[ -f "$BRK/.library.json.broken" ] \
  && echo "  ok   broken: the unreadable index is kept, not overwritten" \
  || { echo "  FAIL broken: the damaged index was destroyed"; brk_fail=1; }
grep -q "Sk" "$BRK/.library.json.broken" 2>/dev/null \
  && echo "  ok   broken: kept intact, exactly as it was found" \
  || { echo "  FAIL broken: the kept copy is not the original"; brk_fail=1; }
# And the rewritten index is usable: reading it again must be quiet.
out2=$(SAIPP_SELFTEST_LIBRARY="$BRK" "$WORK/helper-lib" 2>&1)
echo "$out2" | grep -q "recovered from a broken index" \
  && { echo "  FAIL broken: the recovered index is unreadable too"; brk_fail=1; } \
  || echo "  ok   broken: the rebuilt index reads back cleanly"

# A recovered drawing has no fingerprints, and must NOT therefore match
# everything: a canvas of nothing is not a canvas. It stops matching until it is
# drawn on again, which is the right thing to lose.
mkdir -p "$BRK/.recording"
SESSION_DIR="$BRK/.recording" mksession "session 2026-07-30 2100" "Whatever" "2026-07-30T21:00:00Z" 55 5 40
out3=$(TZ=UTC SAIPP_SELFTEST_LIBRARY="$BRK" "$WORK/helper-lib" 2>&1)
echo "$out3" | grep -q "filed 2026-07-30 2100.mp4 -> Whatever" \
  && echo "  ok   broken: a new session is not swept into a recovered drawing" \
  || { echo "  FAIL broken: $out3"; brk_fail=1; }

[ "$brk_fail" = 0 ] || exit 1
echo "All damaged index tests passed."

echo ""
echo "== The licence survives everything (real filesystem) =="
# The certificate is the only file this app touches that nobody can recreate,
# and every call on its path is a silent `try?`. performSetup(.rebuild) deletes
# the entire prefix and trusts that the stash was filled first, so these drive
# that exact sequence — adopt, delete the prefix, restore — without Wine.
LIC="$WORK/lic"
lic_fail=0
lic_run() {  # prefix cfg step [arg]
  SAI_PREFIX="$1" SAIPP_CONFIG_DIR="$2" SAIPP_SELFTEST_LICENSE="$3" "$WORK/helper-lib" ${4:+"$4"}
}

# 1. A certificate that exists ONLY inside the prefix, never adopted. The prefix
#    is about to be deleted; if it is not rescued first it is gone for good.
R1="$LIC/r1"; mkdir -p "$R1/prefix/drive_c/SAI2/settings" "$R1/cfg"
printf 'MY-LICENCE' > "$R1/prefix/drive_c/SAI2/sai-123456.slc"
out=$(lic_run "$R1/prefix" "$R1/cfg" rebuild)
echo "$out" | grep -q "prefix SAI2/sai-123456.slc" \
  && echo "  ok   licence: survives a rebuild that deletes the whole prefix" \
  || { echo "  FAIL licence: lost in a rebuild: $out"; lic_fail=1; }
# SAI reads it from two places depending on the build; one is not enough.
echo "$out" | grep -q "prefix settings/sai-123456.slc" \
  && echo "  ok   licence: restored to both places SAI reads from" \
  || { echo "  FAIL licence: only one location: $out"; lic_fail=1; }
[ "$(cat "$R1/prefix/drive_c/SAI2/sai-123456.slc")" = "MY-LICENCE" ] \
  && echo "  ok   licence: and it is the same file, not an empty one" \
  || { echo "  FAIL licence: contents changed"; lic_fail=1; }

# 2. THE TRAP: restoring from the stash used to EMPTY the stash. installLicenseFile
#    ends by refreshing the stash copy — remove, then copy src over it — and when
#    restoring, src IS that copy, so the remove deleted the source and the copy
#    silently failed. The licence survived that rebuild, having just been written
#    into the prefix, but the copy the uninstall dialog promises to be holding
#    was gone; the NEXT rebuild had nothing to fall back on.
R2="$LIC/r2"; mkdir -p "$R2/prefix/drive_c/SAI2" "$R2/cfg/license"
printf 'MY-LICENCE' > "$R2/cfg/license/sai-123456.slc"
out=$(lic_run "$R2/prefix" "$R2/cfg" restore)
echo "$out" | grep -q "stash sai-123456.slc" \
  && echo "  ok   licence: a restore leaves the stash intact for the next one" \
  || { echo "  FAIL licence: the restore emptied the stash: $out"; lic_fail=1; }
# Twice, because the point is that it can be done again.
out=$(lic_run "$R2/prefix" "$R2/cfg" restore)
echo "$out" | grep -q "stash sai-123456.slc" \
  && echo "  ok   licence: and still after a second restore" \
  || { echo "  FAIL licence: the stash did not survive twice"; lic_fail=1; }

# 3. Two rebuilds in a row. The second has no prefix copy to adopt, so it is the
#    stash or nothing.
R3="$LIC/r3"; mkdir -p "$R3/prefix/drive_c/SAI2" "$R3/cfg"
printf 'MY-LICENCE' > "$R3/prefix/drive_c/SAI2/sai-123456.slc"
lic_run "$R3/prefix" "$R3/cfg" rebuild > /dev/null
out=$(lic_run "$R3/prefix" "$R3/cfg" rebuild)
echo "$out" | grep -q "prefix SAI2/sai-123456.slc" \
  && echo "  ok   licence: survives a second rebuild, from the stash alone" \
  || { echo "  FAIL licence: lost on the second rebuild: $out"; lic_fail=1; }

# 4. Adopting one that is simply sitting in the SAI folder somebody picked.
R4="$LIC/r4"; mkdir -p "$R4/prefix/drive_c/SAI2" "$R4/cfg" "$R4/source/settings"
printf 'MY-LICENCE' > "$R4/source/settings/sai-999.slc"
out=$(lic_run "$R4/prefix" "$R4/cfg" adopt-source "$R4/source")
echo "$out" | grep -q "adopted sai-999.slc" \
  && echo "  ok   licence: one already in the chosen SAI folder is adopted" \
  || { echo "  FAIL licence: not adopted: $out"; lic_fail=1; }
echo "$out" | grep -q "stash sai-999.slc" \
  && echo "  ok   licence: and reaches the stash, so a rebuild keeps it" \
  || { echo "  FAIL licence: never stashed: $out"; lic_fail=1; }
[ -f "$R4/source/settings/sai-999.slc" ] \
  && echo "  ok   licence: the user's own copy is left where it was" \
  || { echo "  FAIL licence: adopting MOVED the user's file"; lic_fail=1; }

# 5. An unwritable destination must be reported, not claimed as success — the
#    difference between "your licence is installed" and losing it quietly.
R5="$LIC/r5"; mkdir -p "$R5/prefix/drive_c" "$R5/cfg" "$R5/src"
printf 'MY-LICENCE' > "$R5/src/sai-1.slc"
# The SAI folder ITSELF must be unwritable — making its parent read-only proves
# nothing when the folder already exists and is writable.
mkdir -p "$R5/prefix/drive_c/SAI2"; chmod 500 "$R5/prefix/drive_c/SAI2"
out=$(lic_run "$R5/prefix" "$R5/cfg" install "$R5/src/sai-1.slc")
chmod 700 "$R5/prefix/drive_c/SAI2"
echo "$out" | grep -q "installed=false" \
  && echo "  ok   licence: an unwritable prefix is reported as a failure" \
  || { echo "  FAIL licence: claimed success on a read-only prefix: $out"; lic_fail=1; }

[ "$lic_fail" = 0 ] || exit 1
echo "All licence tests passed."

echo ""
echo "== Uninstall removes the installation and nothing else =="
# The most destructive path in the app, and its dialog makes promises only this
# code can keep: "KEPT (yours, never touched)". Wine removal is never exercised
# — the real thing moves Wine Staging to the Trash, and a test that did that
# would reach outside its throwaway folders.
UNI="$WORK/uninstall"
uni_fail=0
setup_uninstall() {  # dir
  rm -rf "$1"; mkdir -p "$1/prefix/drive_c/SAI2" "$1/cfg/license" "$1/cfg/bin" \
                        "$1/mySAI" "$1/videos/Sketch/pieces"
  printf 'WINE-STUFF'  > "$1/prefix/drive_c/SAI2/sai2.exe"
  printf 'MY-LICENCE'  > "$1/cfg/license/sai-123456.slc"
  printf 'path'        > "$1/cfg/config.txt"
  printf '1'           > "$1/cfg/devmode.txt"
  printf 'MY-OWN-SAI'  > "$1/mySAI/sai2.exe"
  printf 'MY-ART'      > "$1/videos/Sketch/pieces/2026-07-27 2015.mp4"
  printf 'FINISHED'    > "$1/videos/Sketch/Sketch.mp4"
  printf '{"drawings":[]}' > "$1/videos/.library.json"
  printf '%s' "$1/videos" > "$1/cfg/timelapse-folder.txt"
}
uni_run() {  # dir mode
  SAI_PREFIX="$1/prefix" SAIPP_CONFIG_DIR="$1/cfg" SAIPP_SELFTEST_UNINSTALL="$2" "$WORK/helper-lib"
}

# --- keeping the licence ----------------------------------------------------
setup_uninstall "$UNI"
out=$(uni_run "$UNI" keep)
echo "$out" | grep -q "prefix exists=false" \
  && echo "  ok   uninstall: the Wine prefix is removed" \
  || { echo "  FAIL uninstall: prefix survived"; uni_fail=1; }
echo "$out" | grep -q "config.txt exists=false" \
  && echo "  ok   uninstall: the saved settings are removed" \
  || { echo "  FAIL uninstall: settings survived"; uni_fail=1; }
echo "$out" | grep -q "stash sai-123456.slc" \
  && echo "  ok   uninstall: 'Keep license' keeps the licence" \
  || { echo "  FAIL uninstall: the licence was deleted despite Keep: $out"; uni_fail=1; }

# THE PROMISE IN THE DIALOG: the user's own SAI folder is never touched.
[ "$(cat "$UNI/mySAI/sai2.exe")" = "MY-OWN-SAI" ] \
  && echo "  ok   uninstall: the user's own SAI folder is untouched" \
  || { echo "  FAIL uninstall: the user's SAI folder was damaged"; uni_fail=1; }

# THE TRAP: videos are the user's work, they live outside our folders, and the
# index saying which sessions belong together lives in there with them. Add the
# videos folder to the removal list and all three of these go red.
[ "$(cat "$UNI/videos/Sketch/pieces/2026-07-27 2015.mp4")" = "MY-ART" ] \
  && echo "  ok   uninstall: recorded sessions are untouched" \
  || { echo "  FAIL uninstall: a recorded session was deleted"; uni_fail=1; }
[ "$(cat "$UNI/videos/Sketch/Sketch.mp4")" = "FINISHED" ] \
  && echo "  ok   uninstall: finished videos are untouched" \
  || { echo "  FAIL uninstall: a finished video was deleted"; uni_fail=1; }
echo "$out" | grep -q "index exists=true" \
  && echo "  ok   uninstall: and the library index with them" \
  || { echo "  FAIL uninstall: the library index was deleted"; uni_fail=1; }

# --- dropping the licence ---------------------------------------------------
setup_uninstall "$UNI"
out=$(uni_run "$UNI" drop)
echo "$out" | grep -qE "^stash +$" \
  && echo "  ok   uninstall: 'Delete it too' does delete the licence" \
  || { echo "  FAIL uninstall: the licence survived a deliberate delete: $out"; uni_fail=1; }
[ "$(cat "$UNI/mySAI/sai2.exe")" = "MY-OWN-SAI" ] \
  && echo "  ok   uninstall: and still nothing of the user's is touched" \
  || { echo "  FAIL uninstall: the user's SAI folder was damaged"; uni_fail=1; }

[ "$uni_fail" = 0 ] || exit 1
echo "All uninstall tests passed."
