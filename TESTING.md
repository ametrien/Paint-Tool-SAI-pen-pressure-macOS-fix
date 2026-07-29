# Testing

Most of this project can't be tested automatically — it needs a real tablet, Wine, and SAI on
screen. So testing is two parts: **automated build checks** (CI, below) and a **manual
checklist** you run with hardware before a release or when reviewing a PR that touches drawing
behaviour.

## Automated

### Unit tests (no hardware needed)

The tricky, bug-prone logic — coordinate mapping (y-flip, fixed point, multi-monitor),
packet conflation, sample parsing (torn reads), the dedup/keepalive rules that fixed the
double-click bug, and the Cmd→Ctrl remap decisions — lives in pure functions
(`wacom-helper/PressureCore.swift`, `wintab-src/wintab_core.h`) with native unit tests:

```bash
bash tests/run-tests.sh    # builds + runs the C and Swift test suites
```

The same applies to the timelapse: the tile walk (`wintab-src/timelapse_core.h`), the
encoder's sizing and segmenting decisions (`timelapse-encoder/EncoderCore.swift`), and
deciding that tonight's session continues a drawing from three weeks ago
(`timelapse-encoder/LibraryCore.swift`). `run-tests.sh` also drives the real encoder and the
real filing code against throwaway folders, because both of those move files.

If you change behaviour in any core file, add or adjust a test case.

**A test that has never failed is not evidence.** Every trap in these suites was proved by
reintroducing the bug and watching it go red — the identity thresholds in `LibraryCore` were
calibrated against measured numbers (they are in the comments), and each of the thirteen ways
to break the ladder was mutated in turn. Do the same for anything you add: comment the trap
in the test so the next person knows what it is holding.

### CI

Every push / PR runs `.github/workflows/build.yml` on a macOS runner: unit tests,
cross-build of `wintab32.dll` (mingw-w64), the Swift helper (+ `--version` smoke test),
the `.app` bundle with structural validation (real Mach-O main executable — the error -47
regression guard — DLL/installer/icon present, version stamped), `shellcheck` on the shell
scripts, and a Wine-download-URL check. The built app is attached as a workflow artifact.

Pushing a `v*` tag additionally runs `.github/workflows/release.yml`, which builds, zips,
and attaches the app to a GitHub Release (after checking the zip contains no `.slc`/`.exe`).

Green = logic + build + packaging verified; CI does **not** verify drawing behaviour
(that's the checklist below).

Run the same checks locally:
```bash
bash tests/run-tests.sh
cd wintab-src && x86_64-w64-mingw32-windres wintab32.rc -O coff -o wintab32_res.o && \
  x86_64-w64-mingw32-gcc -shared -O2 -o wintab32.dll wintab32.c wintab32_res.o wintab32.def -lgdi32 -luser32 -lws2_32 -municode
cd ../wacom-helper && swiftc -O -o wacom-pressure-helper main.swift PressureCore.swift
cd .. && bash make-app.sh
```

## Manual checklist (with hardware)

Note your setup at the top of your report: **Mac model + chip, macOS version, tablet model +
connection (USB/BT), SAI version.** Tick each item ✅/❌ and note anything odd.

### Setup / install
- [ ] `make-app.sh` builds `dist/SAI Pen Pressure.app` without errors.
- [ ] First launch: the setup **window** appears with the checklist.
- [ ] Wine missing → **Install Wine** downloads + installs it; the row flips to ✅.
- [ ] SAI folder picker accepts a folder with `sai2.exe` and rejects one without.
- [ ] Granting Input Monitoring flips the row to ✅ (possibly after a reopen).
- [ ] **Launch** builds the prefix (first time ~1 min) and opens SAI.

### Core pressure
- [ ] Strokes **vary in width/opacity with pen force** (light = thin, hard = thick).
- [ ] A slow deliberate curve is smooth (no gaps/jitter).
- [ ] Lifting the pen ends the stroke cleanly (no trailing line to the next stroke).

### Cursor / hover
- [ ] While hovering (pen near, not touching), the brush cursor **tracks the pen**.
- [ ] The macOS arrow cursor stays hidden while drawing (doesn't flicker back).

### Coexistence
- [ ] **Mouse/trackpad still paints** normally (switch to it mid-session).
- [ ] A **single pen tap = a single click** (no accidental double-click) on canvas and on tools.

### Multi-monitor (if available)
- [ ] With a 2nd display, there's a **single** cursor that lands where the pen is on both screens.

### Shortcuts / saving
- [ ] **Cmd+Z undoes**, Cmd+Y / Cmd+Shift+Z redoes, Cmd+S saves — inside SAI (via Wine's
      built-in Cmd→Ctrl; no Accessibility permission needed).
- [ ] **Cmd+Tab still switches apps** (not remapped).
- [ ] With a license in the prefix's `SAI2` folder: **saving works**.

### Timelapse across sessions
- [ ] Draw, quit SAI, reopen the **same file** and draw again → one drawing in the Timelapses
      tab with two sessions, and one video containing both.
- [ ] **Rename the canvas** between two sessions → still one drawing.
- [ ] Two **new** documents on the same day → two drawings, no question asked.
- [ ] Reopen a drawing you have worked on elsewhere since → it asks, with two stills side by
      side; "Separate drawings" must not ask again for that pair.
- [ ] "Take out of this drawing" moves a session into its own drawing, and both videos rebuild.
- [ ] Export at 30s → a separate file; the drawing's own video is still full length.
- [ ] Resize a canvas between sessions → the combined video fits both, with neither squashed.
- [ ] Hover a still in the Videos tab → it plays in place and loops; move away and it stops.
- [ ] **Change the videos folder while the app is open**: Recording tab → Choose… → pick another
      folder → Videos tab lists that folder's contents immediately, and no longer the old one's.
      Change it back and the first folder's videos return. No restart at any point.
      (Each folder keeps its own `.library.json`, so drawings recorded into one do not follow you
      into the other.)

### Safety / lifecycle (the destructive paths now have automated cover)
Uninstall, the licence rescue and a damaged library index are covered by
`tests/run-tests.sh` against throwaway folders. Two things it deliberately does
NOT do, and which therefore need a human: removing **Wine** during uninstall (it
moves a real application to the Trash), and the **Wine prefix rebuild** itself
(needs a real `wineboot`). Check those by hand on a machine you can restore.
- [ ] Uninstall with "Move Wine to Trash" → Wine Staging is in the Trash, and only it.
- [ ] Rebuild the prefix with a licence installed → SAI still saves afterwards.

### Safety / lifecycle
- [ ] Kill switch: `echo 0 > <prefix>/drive_c/wt_pressure.txt` stops pressure immediately.
- [ ] Closing SAI quits the helper/app cleanly (no lingering process, cursor released).

### Known non-bugs (don't report as new)
- Fast curves are boxy over **Bluetooth** (~130 Hz) — use USB (~200 Hz).
- SAI's **top menu row ignores pen taps** while the pen is in range (SAI drops the pen's
  mouse click as a "duplicate") — use the mouse/trackpad for menus. See README Limitations.
- After app-switching, SAI's window can get stuck ignoring input — Space-swipe to fix (a Wine
  `winemac.drv` issue, not this bridge).

## Debug logs to attach when something fails
```bash
WT_VERBOSE=1 ./wacom-helper/wacom-pressure-helper      # helper console
WT_DEBUG=1 bash ./launch-sai2-pressure.sh              # DLL log -> <prefix>/drive_c/wtlog.txt
```
