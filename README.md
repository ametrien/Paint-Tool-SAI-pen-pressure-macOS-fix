# SAI Pen Pressure & Timelapse Recorder on macOS

[![build](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/actions/workflows/build.yml/badge.svg)](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/actions/workflows/build.yml)
[![release](https://img.shields.io/github/v/release/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix?include_prereleases&sort=semver)](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/releases/latest)
[![downloads](https://img.shields.io/github/downloads/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/total)](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/releases)
[![license](https://img.shields.io/github/license/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix)](LICENSE)

Run **PaintTool SAI Ver.2** on a Mac (via Wine) **with real Wacom pen pressure** — the one
thing that normally doesn't survive the trip through Wine — and **record a timelapse of your
canvas** while you draw.

macOS + Wine already run SAI and move the cursor fine, but Wine's Mac driver throws away pen
**pressure**. This project adds it back with a tiny two-part bridge:

- a **custom `wintab32.dll`** that speaks the WinTab tablet API to SAI (drop-in, no Wine rebuild), and
- a small **native macOS helper** that reads your tablet's real pressure and feeds it to that DLL.

The result: pressure-sensitive strokes that taper with how hard you press.

## What it looks like

Four tabs, one window.

<p align="center">
  <img src="docs/assets/screenshots/setup.png" alt="Setup tab: status of Wine, SAI, licence and Input Monitoring, with a Launch button" width="49%">
  <img src="docs/assets/screenshots/pen.png" alt="Pen tab: pressure levels, pen feel, and the pen feel curve" width="49%">
</p>
<p align="center">
  <img src="docs/assets/screenshots/recording.png" alt="Recording tab: canvas timelapse settings" width="49%">
  <img src="docs/assets/screenshots/developer.png" alt="Developer tab: logs, diagnostics and a health check" width="49%">
</p>

**Setup** gets SAI running and tells you which of the four prerequisites are missing.
**Update SAI…** swaps in a newer SAI build without touching your licence, brushes or preferences —
useful because Ver.2 is a rolling preview.
**Pen** is pressure levels, pen feel and the response curve.
**Recording** is the canvas timelapse.
**Developer** holds the logs, a diagnostics dump and a health check.

---


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

📺 **Video walkthrough:** [watch the setup tutorial](https://youtu.be/62mJwWQsEYI)

---

## What you get

**Drawing**

- **Real pen pressure** in SAI, with adjustable levels (up to 8192) and pen feel
- **Mouse and trackpad still paint normally** — no need to unplug anything
- Works across **multiple monitors**

**It behaves like a Mac app, not Windows in a box**

- **⌘Z / ⌘Y / ⌘S** and the rest, rather than Ctrl — remapped inside Wine, so SAI simply sees the right keys
- **Pinch to zoom** and **two-finger scroll to pan** on the trackpad
- **⌃⌥⌘Space** brings back a SAI window that has gone missing, and it can do that automatically when you switch back to SAI

**Canvas timelapse** *(v0.2.0+)*

- **One frame per brush stroke** — hours of drawing become a couple of minutes
- Records the **canvas, not the screen**: no panels, no cursor, and no camera lurching when you zoom or pan
- Layer opacity and blend modes come through; **several open canvases become one video each**
- Pick a target length; it encodes as you draw, so it costs megabytes rather than gigabytes

**Setup and upkeep**

- **One app, no terminal.** Wine is installed for you, with progress
- Licence handling, including the two-folders trap that silently stops SAI saving
- **Update SAI in place** when a new build lands, keeping your licence, brushes and preferences
- Reset, reinstall or uninstall from the same window; logs and a health check when something is odd

## Get started

1. **[Download the latest release](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/releases/latest)** and drag the app to Applications.
2. **Right-click it → Open** the first time (macOS asks once, because the app is not notarised).
3. Follow the setup window. It installs Wine, finds your SAI folder, and checks the one permission it needs.

You bring your own copy of **PaintTool SAI Ver.2** and, if you want to save your work, a licence
from SYSTEMAX. Everything else the app handles.

→ **[Full install guide](https://ametrien.github.io/Paint-Tool-SAI-pen-pressure-macOS-fix/install)**, including the manual command-line route
→ **[Troubleshooting](https://ametrien.github.io/Paint-Tool-SAI-pen-pressure-macOS-fix/troubleshooting)**, organised by how to tell which problem you have
→ **[How it works](https://ametrien.github.io/Paint-Tool-SAI-pen-pressure-macOS-fix/how-it-works)**, if you want the architecture

---

## Canvas timelapse

> **Requires v0.2.0 or later. macOS only** — on Windows or Linux use
> [art-timelapse](https://github.com/cromachina/art-timelapse), which is where this idea came
> from. See [credit](#credit).

<p align="center">
  <img src="docs/assets/demo/timelapse-example.gif" alt="A short canvas timelapse: handwriting appearing stroke by stroke on a white canvas" width="600">
  <br>
  <em>Fifteen strokes, recorded and played back — the canvas alone, with nothing else in frame.</em>
  <br>
  <a href="docs/assets/demo/timelapse-example.mp4">Watch the original video</a>
</p>

Recording is on by default. Draw, press **Make video…** — the result appears in the Recording tab
and lands in `~/Movies/SAI Timelapses`. You do not have to quit SAI first; recording carries on
afterwards.

It reads SAI's canvas out of memory rather than capturing the screen, so the video is the artwork
alone: no panels, no cursor, and no camera movement when you zoom, pan or rotate while working.
Layer opacity and blend modes come through, and several open canvases each get their own video.

→ **[More about recording](https://ametrien.github.io/Paint-Tool-SAI-pen-pressure-macOS-fix/#canvas-timelapse)** — video length, what happens to undo, and
how much disk it uses

---

## Limitations

- **SAI and its license are not included** — bring your own (legal requirement).
- Tested with a **Wacom Intuos (CTL-4100)** on Apple Silicon. Other WinTab tablets with a
  macOS driver *should* work (the helper reads standard tablet events) but are untested.
- **Bluetooth report rate (~130 Hz)** makes fast curves boxy — use USB for ~200 Hz ([why](https://ametrien.github.io/Paint-Tool-SAI-pen-pressure-macOS-fix/troubleshooting#fast-curves-come-out-boxy)).
- Tilt/rotation are not forwarded (the test tablet has none); pressure only.
- **SAI can freeze on input after app-switching** — press **⌃⌥⌘Space** (or the 🖊 menu-bar icon → *Wake SAI*) to instantly un-stick it.

The last two are caused by SAI and by Wine's macOS driver (not the pressure bridge). See
**[KNOWN_ISSUES.md](KNOWN_ISSUES.md)** for the full explanation, what we tried, and what
didn't work.

---

## Build from source (contributors)

Only `wintab32.dll` is committed prebuilt (cross-compiling it needs mingw-w64). The Swift
helper is built from source automatically by `install.sh` / `make-app.sh` — or by hand:
```bash
# custom wintab32.dll  (needs mingw-w64:  brew install mingw-w64)
cd wintab-src
x86_64-w64-mingw32-gcc -shared -O2 -o wintab32.dll wintab32.c wintab32_res.o wintab32.def \
    -lgdi32 -luser32 -lws2_32 -municode

# native helper  (needs Xcode command-line tools)
cd ../wacom-helper
swiftc -O -o wacom-pressure-helper main.swift PressureCore.swift
```

Contributions welcome — especially testing on other tablets and Macs.

---

## Credit

The timelapse exists because of [**cromachina/art-timelapse**](https://github.com/cromachina/art-timelapse),
which has been doing this on Windows and Linux for a while. The insight — that SAI's canvas can be
read out of the running process, so a timelapse can show the artwork rather than a recording of the
application — is theirs, and so is the knowledge of roughly where to look inside a canvas structure.

**On Windows or Linux, go and use it.** It is the right tool there, and this project has nothing to
offer those platforms.

The implementations differ substantially. art-timelapse reads SAI from *outside* the process, which
on macOS would need a debugger entitlement and a permission prompt; this reads it from *inside*,
because a tablet bridge already runs in there for pressure — which also means a finished brush
stroke is something we are told rather than something inferred from mouse events. No code was
copied. The memory offsets are facts about SAI's binary and were verified here against a live
process, though the field layout was informed by theirs rather than found blind; the full account is
in [TIMELAPSE-PLAN.md](TIMELAPSE-PLAN.md).

art-timelapse is GPL-3.0 and this project is MIT, which is why the boundary was worth keeping clear.

## License & attribution

This project (the pressure-bridge code — `wintab32.dll` source, the macOS helper, the
installer and documentation) is released under the **[MIT License](LICENSE)**.

**PaintTool SAI** is proprietary software by SYSTEMAX Software Development (Koji Komatsu).
This project does **not** include — and must never include — SAI itself, its installer, or
any license certificate. You obtain those from <https://www.systemax.jp/en/sai/> yourself.
The MIT license here covers only the bridge code in this repository.
