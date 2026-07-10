# SAI Pen Pressure on macOS

Run **PaintTool SAI Ver.2** on a Mac (via Wine) **with real Wacom pen pressure** — the one
thing that normally doesn't survive the trip through Wine.

macOS + Wine already run SAI and move the cursor fine, but Wine's Mac driver throws away pen
**pressure**. This project adds it back with a tiny two-part bridge:

- a **custom `wintab32.dll`** that speaks the WinTab tablet API to SAI (drop-in, no Wine rebuild), and
- a small **native macOS helper** that reads your tablet's real pressure and feeds it to that DLL.

The result: pressure-sensitive strokes that taper with how hard you press, plus your mouse/
trackpad still paint normally.

> **Status:** working on Apple Silicon with a Wacom Intuos (CTL-4100). Position + pressure +
> hover tracking + mouse coexistence all work. Multi-monitor is supported (single cursor across
> displays). See [Limitations](#limitations).

---

## What you need to bring

This tool **can't** bundle everything — two pieces are legally yours to provide:

| You provide | Where |
|---|---|
| **PaintTool SAI Ver.2** (free technical preview) | https://www.systemax.jp/en/sai/ |
| **Your SAI license** (if you have one; needed to *save*) | your `.slc` certificate from your purchase |
| **A tablet + its macOS driver** | e.g. Wacom driver from wacom.com |
| **Wine** (Gcenx "Wine Staging" build) | https://github.com/Gcenx/macOS_Wine_builds/releases |

This project provides the **pressure bridge** (the DLL + helper) and an **installer** that wires
it all together.

---

## Easiest: the app (recommended)

Build the double-clickable app once:
```bash
./make-app.sh          # produces dist/SAI Pen Pressure.app  (drag it to /Applications)
```
Then **double-click "SAI Pen Pressure"**:

1. **First launch:** right-click the app → **Open** (once — it's unsigned, so Gatekeeper asks).
2. It **asks for your SAI Ver.2 folder** (the one containing `sai2.exe`), then sets up the
   Wine prefix and installs the bridge.
3. **Grant permissions.** macOS will pop up **two** prompts — the app needs *both*, under
   System Settings → **Privacy & Security**:
   - **Input Monitoring** → turn on **"SAI Pen Pressure"** (this reads the tablet's pressure).
   - **Accessibility** (the prompt says *"…would like to receive keystrokes"*) → turn on
     **"SAI Pen Pressure"** (this is only for the Cmd→Ctrl shortcut remap; you can skip it if
     you don't want that feature, and pressure still works).
4. **⚠️ Quit and reopen the app.** macOS only applies these permissions on a **fresh launch** —
   the first run *won't have pressure* until you restart the app. You only do this once; after
   that, double-clicking the app just works.

You still bring your own Wine (in `/Applications`), SAI, and license (drop your `.slc` into
the prefix's `SAI2` folder and restart SAI). The manual route below does the same thing if you
prefer the command line.

---

## Install (step by step, manual)

1. **Install Wine.** Download `wine-staging-*-osx64.tar.xz` (or the `.app`) from the
   [Gcenx releases](https://github.com/Gcenx/macOS_Wine_builds/releases) and put
   **Wine Staging.app** in `/Applications`.

2. **Download & unzip SAI Ver.2** from systemax. Note the folder that contains `sai2.exe`.

3. **Run the installer** (from this repo):
   ```bash
   ./install.sh
   ```
   It creates a Wine prefix, copies SAI into it, installs the custom `wintab32.dll`, sets the
   DLL override, and generates your personal one-click launcher. It will ask where your SAI
   folder is (or set `SAI2_SRC=/path/to/sai2-folder ./install.sh`).

4. **Grant permissions.** System Settings → **Privacy & Security** → grant your terminal app
   (Terminal / iTerm) **both**:
   - **Accessibility**
   - **Input Monitoring**

   Then fully quit and reopen the terminal. (The helper reads tablet events through these; it
   captures nothing without them.)

5. **Add your license** (to be able to save): drop your `sai-*.slc` file into the prefix's SAI
   folder — the installer prints the exact path — and restart SAI. SAI reads the license only
   at startup.

6. **Turn on WinTab in SAI:** Others → Options → **Pen Tablet** → **Use WinTab API**, then
   restart SAI.

---

## Daily use

**Double-click `Start SAI2 with pen pressure.command`** (the installer places one configured
for your setup). It starts the pressure helper and SAI together, and stops the helper when you
close SAI.

Or from a terminal:
```bash
WT_PRESSURE_FILE="$HOME/SAI2-pressure/drive_c/wt_pressure.txt" \
  ./wacom-helper/wacom-pressure-helper &     # in a terminal with the permissions
bash ./launch-sai2-pressure.sh
```

**Kill switch** if anything ever misbehaves: `echo 0 > <prefix>/drive_c/wt_pressure.txt`, or
just close SAI / quit the helper.

---

## How it works (short version)

```
 tablet ──▶ macOS event ──▶ helper (CGEventTap, reads pressure+position)
                                  │  UDP datagram per sample → 127.0.0.1:47800
                                  ▼
        SAI2 ◀── WT_PACKET ── our wintab32.dll (drop-in; conflates packets to
             (WinTab API)       stay in sync, streams hover like a real driver)
```

Only **tablet** events drive WinTab; real mouse/trackpad events are left alone so SAI's own
mouse painting keeps working. Full details in [`TECHNICAL_WRITEUP.md`](TECHNICAL_WRITEUP.md)
and [`HANDOVER-START-HERE.md`](HANDOVER-START-HERE.md).

---

## Tips for best results

- **Connect the tablet by USB for smooth fast strokes.** A Wacom over **Bluetooth reports at
  only ~130 Hz**, versus **~200 Hz over USB**. At that lower rate, quickly-drawn *curves come out
  boxy* (too few points to trace the curve) — the bridge draws every point it's given, so the
  limit is the tablet's Bluetooth report rate, not the software. Plug in a **data** USB cable
  (not charge-only) for the higher sample rate and noticeably smoother fast lines. Bluetooth is
  fine for slower, deliberate drawing.
- If you must stay wireless, raising SAI's own **Stabilizer** setting smooths the path (at the
  cost of a little stroke "drag").

## Limitations

- **SAI and its license are not included** — bring your own (legal requirement).
- Tested with a **Wacom Intuos (CTL-4100)** on Apple Silicon. Other WinTab tablets with a
  macOS driver *should* work (the helper reads standard tablet events) but are untested.
- **Bluetooth report rate (~130 Hz)** makes fast curves boxy — use USB for ~200 Hz (see Tips).
- Tilt/rotation are not forwarded (the test tablet has none); pressure only.
- A few **Wine window quirks** remain — these are Wine-on-Mac (`winemac.drv`) behaviors,
  independent of the pressure bridge:
  - the window sometimes opens inactive until you click it;
  - after switching to another app, SAI's window can get **stuck ignoring all input** even
    though it looks active. **Workaround: switch to a different Space and back** (3-finger
    swipe left/right on the trackpad) — that forces macOS to fully re-activate the window.
    Clicking alone often isn't enough; this is a known Wine focus bug with no user-side fix.

---

## Build from source (contributors)

Prebuilt binaries are committed, but to rebuild:
```bash
# custom wintab32.dll  (needs mingw-w64:  brew install mingw-w64)
cd wintab-src
x86_64-w64-mingw32-gcc -shared -O2 -o wintab32.dll wintab32.c wintab32_res.o wintab32.def \
    -lgdi32 -luser32 -lws2_32 -municode

# native helper  (needs Xcode command-line tools)
cd ../wacom-helper
swiftc -O -o wacom-pressure-helper main.swift
```

Contributions welcome — especially testing on other tablets and Macs.
