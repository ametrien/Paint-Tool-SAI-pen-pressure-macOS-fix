# SAI Pen Pressure on macOS

Run **PaintTool SAI Ver.2** on a Mac (via Wine) **with real Wacom pen pressure** — the one
thing that normally doesn't survive the trip through Wine.

macOS + Wine already run SAI and move the cursor fine, but Wine's Mac driver throws away pen
**pressure**. This project adds it back with a tiny two-part bridge:

- a **custom `wintab32.dll`** that speaks the WinTab tablet API to SAI (drop-in, no Wine rebuild), and
- a small **native macOS helper** that reads your tablet's real pressure and feeds it to that DLL.

The result: pressure-sensitive strokes that taper with how hard you press, plus your mouse/
trackpad still paint normally.

> **Status:** working. Position + pressure + hover tracking + mouse coexistence all work, plus
> multi-monitor and Mac-style Cmd shortcuts. See [Limitations](#limitations).
>
> **Tested configuration:**
> - Mac: **Apple M3 Pro**, **macOS Tahoe 26.3 (25D125)**
> - SAI: **PaintTool SAI Ver.2 (64-bit)**
> - Tablet: **Wacom Intuos BT S (CTL-4100WL)**, over USB and Bluetooth
> - Displays: **single screen**, and **two screens in mirroring mode**
>
> Other tablets / Macs / display setups are untested — reports welcome (see
> [CONTRIBUTING](CONTRIBUTING.md)).

---

## Quick start — from zero to drawing

Starting with nothing but a Mac and a tablet? Follow these in order (~15 min, most of it downloads):

1. **Install your tablet's macOS driver** (e.g. Wacom's driver from wacom.com). Check the pen
   moves the cursor in any app before continuing.
2. **Download PaintTool SAI Ver.2** from https://www.systemax.jp/en/sai/devdept.html — under *"Download
   PaintTool SAI Ver.2 Technical Preview Stable Version"*, get the **SAI Ver.2 64bit … Technical
   Preview** ZIP (~3 MB). Unzip it; the folder contains `sai2.exe`. *(You can draw and test
   pressure for free — a license is only needed to save; see step 7.)*
3. **Download the app** — no terminal needed. From the
   [**latest release**](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/releases/latest),
   download **`SAI-Pen-Pressure-….zip`** and double-click it to unzip → you get
   **`SAI Pen Pressure.app`** (drag it to your Applications folder if you like).
   *Developers can instead `git clone` this repo and run `./make-app.sh`.*
4. **Open it.** macOS blocks unsigned apps, so: double-click the app once (it'll refuse), then go
   **System Settings → Privacy & Security**, scroll down, and click **"Open Anyway"** → confirm.
   You only do this once. *(Why the warning? see ["is this safe?"](#macos-wont-let-me-open-it--is-this-safe).)*
5. **Follow the setup window.** It checks everything and fixes each item:
   - **Install Wine** if you don't have it (downloads it, with progress) →
   - **Choose** your SAI folder from step 2 →
   - **Grant** *Input Monitoring* (and optionally *Accessibility* for Cmd-shortcuts); reopen the
     app if macOS asks →
   - click **Launch SAI with Pressure**.
6. **Turn on WinTab in SAI:** Others → Options → **Pen Tablet** → **Use WinTab API**, then
   relaunch SAI (reopen the app).
7. **Draw — you've got pressure!** *To save your work* you need a SAI license:
   - Buy one, and you'll get an email titled *"Information About Your Software License"* with a
     **License Number** and a **Certificate Download Password**.
   - In SAI, open **Others → System ID** and note the ID it shows.
   - Go to https://www.systemax.jp/en/license.html, enter the License Number, password, and your
     **System ID**, and download the `.slc` certificate.
   - Drop that `.slc` into `~/SAI2-pressure/drive_c/SAI2/` and restart SAI (it reads the license
     only at startup). *(The certificate is tied to that System ID — if you ever rebuild the Wine
     prefix and the ID changes, just re-download it from the same page.)*

That's it. The sections below explain the pieces, the manual (command-line) route, and options.

---

## What you need to bring

This tool **can't** bundle everything — two pieces are legally yours to provide:

| You provide | Where |
|---|---|
| **PaintTool SAI Ver.2** (free technical preview, 64-bit ZIP) | https://www.systemax.jp/en/sai/devdept.html |
| **A SAI license** — only needed to *save* your work | https://www.systemax.jp/en/license.html (you can draw & test pressure without it) |
| **A tablet + its macOS driver** | e.g. Wacom driver from wacom.com |
| **Wine** (Gcenx "Wine Staging" build) | https://github.com/Gcenx/macOS_Wine_builds/releases |

This project provides the **pressure bridge** (the DLL + helper) and an **installer** that wires
it all together.

---

## Easiest: the app (recommended)

**Download `SAI Pen Pressure.app`** from the
[latest release](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/releases/latest)
(no terminal needed) — or build it yourself with `./make-app.sh`. Then:

1. **First launch:** double-click it → macOS blocks it → **System Settings → Privacy & Security →
   "Open Anyway"** (it's unsigned; [why?](#macos-wont-let-me-open-it--is-this-safe)).
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

### "macOS won't let me open it / is this safe?"

macOS shows an "unidentified developer" warning because signing an app so Gatekeeper trusts it
requires a **paid Apple Developer account (~$100/year)**, which this free project doesn't have.
So you allow it yourself: double-click the app once (macOS refuses), then go **System Settings →
Privacy & Security**, scroll down, and click **"Open Anyway"**. (On older macOS, right-click the
app → **Open** also works.)

And if you have doubts — **you should!** — this whole thing is **open source**. Read the code
before you run it: the entire bridge is a small `wintab32.dll` (C) and one Swift helper, right
here in this repo. Don't run tools you can't inspect.

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
