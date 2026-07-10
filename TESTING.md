# Testing

Most of this project can't be tested automatically — it needs a real tablet, Wine, and SAI on
screen. So testing is two parts: **automated build checks** (CI, below) and a **manual
checklist** you run with hardware before a release or when reviewing a PR that touches drawing
behaviour.

## Automated (CI)

Every push / PR runs `.github/workflows/build.yml` on a macOS runner: it cross-builds
`wintab32.dll` (mingw-w64), builds the Swift helper, assembles the `.app`, lints the shell
scripts, and checks the Wine-download URL still resolves. Green = it builds and packages; it
does **not** verify drawing behaviour (that's the checklist).

Run the same checks locally:
```bash
cd wintab-src && x86_64-w64-mingw32-windres wintab32.rc -O coff -o wintab32_res.o && \
  x86_64-w64-mingw32-gcc -shared -O2 -o wintab32.dll wintab32.c wintab32_res.o wintab32.def -lgdi32 -luser32 -lws2_32 -municode
cd ../wacom-helper && swiftc -O -o wacom-pressure-helper main.swift
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
- [ ] With Accessibility granted: **Cmd+Z undoes**, Cmd+Y / Cmd+Shift+Z redoes, only inside SAI.
- [ ] **Cmd+Tab still switches apps** (not remapped).
- [ ] With a license in the prefix's `SAI2` folder: **saving works**.

### Safety / lifecycle
- [ ] Kill switch: `echo 0 > <prefix>/drive_c/wt_pressure.txt` stops pressure immediately.
- [ ] Closing SAI quits the helper/app cleanly (no lingering process, cursor released).

### Known non-bugs (don't report as new)
- Fast curves are boxy over **Bluetooth** (~130 Hz) — use USB (~200 Hz).
- After app-switching, SAI's window can get stuck ignoring input — Space-swipe to fix (a Wine
  `winemac.drv` issue, not this bridge).

## Debug logs to attach when something fails
```bash
WT_VERBOSE=1 ./wacom-helper/wacom-pressure-helper      # helper console
WT_DEBUG=1 bash ./launch-sai2-pressure.sh              # DLL log -> <prefix>/drive_c/wtlog.txt
```
