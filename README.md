# PaintTool SAI 2 on Mac: pen pressure & timelapse

[![build](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/actions/workflows/build.yml/badge.svg)](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/actions/workflows/build.yml)
[![release](https://img.shields.io/github/v/release/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix?include_prereleases&sort=semver)](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/releases/latest)
[![downloads](https://img.shields.io/github/downloads/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/total)](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/releases)
[![license](https://img.shields.io/github/license/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix)](LICENSE)

Run **PaintTool SAI Ver.2** on a Mac with **real pen pressure**, and record a **timelapse of your
canvas** while you draw. Free and open source.

- **[What you need](#what-you-need):** a Mac, a tablet and your own SAI.
- **[Get started](#get-started):** download the free app, follow the setup window, get SAI and a licence, and the setups users have reported working.
- **[What you get](#what-you-get):** pressure and pen feel, Mac shortcuts, sharp text on Retina screens, Chinese, Japanese and Korean text, timelapse.
- **[What it does not do](#what-it-does-not-do):** SAI and its licence are not included, pressure only, and the limits that belong to SAI or Wine.
- **[What it looks like](#what-it-looks-like):** every tab, with a screenshot.
- **[Your brushes, textures and presets](#your-brushes-textures-and-presets):** bring your settings from a PC, or add a brush pack.
- **[Something not working?](#something-not-working):** troubleshooting, and one button that collects a problem report.

📺 **[Watch the setup video](https://youtu.be/62mJwWQsEYI)**

<p align="center">
  <img src="docs/assets/screenshots/sai-on-mac.png" alt="PaintTool SAI Ver.2 running on a MacBook next to SAI Pen Pressure, with a pressure-sensitive pen stroke on the canvas" width="88%">
</p>

## What you need

- **A Mac with Apple Silicon or an Intel Mac.** Both work.
- **A pen tablet that macOS itself recognises.** The app reads the standard tablet events macOS
  gives every app, so nothing in it is tied to one tablet.
- **PaintTool SAI Ver.2**, free to download, and a licence from SYSTEMAX if you want to save.
  **[Where to get both, step by step](#get-sai-and-a-licence)**.

Wine is installed for you during setup. On Apple Silicon, setup also installs Rosetta if it is not
there yet, because Wine runs through it. Intel Macs do not need Rosetta.

## Get started

SAI Pen Pressure is free.

1. **[Download the latest release](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/releases/latest)** and drag the app to Applications.
2. **Right-click it → Open** the first time (macOS asks once, because the app is not notarised).
3. Follow the setup window. It installs Wine, finds your SAI folder, and checks the one permission it needs.

You bring your own copy of **PaintTool SAI Ver.2** and, if you want to save your work, a licence
from SYSTEMAX. Everything else the app handles. How to get both is just below.

**Check it on your own Mac in a minute:** the Pen tab's **Test pen** shows the pressure the app
sends and the pressure that arrives on SAI's side. Both bars move when it works.

→ **[Full install guide](https://ametrien.github.io/Paint-Tool-SAI-pen-pressure-macOS-fix/install)**, including the manual command-line route
→ **[Troubleshooting](https://ametrien.github.io/Paint-Tool-SAI-pen-pressure-macOS-fix/troubleshooting)**, organised by how to tell which problem you have
→ **[How it works](https://ametrien.github.io/Paint-Tool-SAI-pen-pressure-macOS-fix/how-it-works)**, if you want the architecture

### Get SAI and a licence

**SAI Ver.2 (free download)**

1. Open the official page: **[systemax.jp/en/sai/devdept.html](https://www.systemax.jp/en/sai/devdept.html)**
2. Download a **SAI Ver.2 64bit** ZIP (its file name ends in `64bit-en.zip`). Not 32bit, and not
   *SAI Ver.1*, which is an `.exe` installer.
3. Unzip it anywhere, for example into Documents. In the app's setup window, choose that folder.

SAI Ver.2 is a *Technical Preview* that SYSTEMAX keeps updating, so the page usually has two:
the **stable** build, older and settled, and the newer **Major Renovated** build (its file says
*Alpha*). Either works with this app for pen pressure.

**The timelapse** has been tested on SAI Ver.2 (64bit) Alpha.2026.07.27 and Alpha.2026.10.19
(from v0.3.17). With another build it looks for the canvas by itself, and the Recording tab says
whether it found it. If you are on v0.3.16 or older, recording works with 07.27 only
([#56](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/issues/56)).

**The licence (paid, needed only to save)**

Without a licence SAI draws, and pen pressure works, but it cannot save. SYSTEMAX sells one
licence, named *SAI Ver.1*; it unlocks saving in Ver.2 too.

1. **Buy it:** [systemax.jp/en/sai/purchase/purchase.php](https://www.systemax.jp/en/sai/purchase/purchase.php)
2. **Wait for the email** titled *"[SYSTEMAX] Information about Your Software License"*. It has
   your **licence number** and a **certificate download password**.
3. **Find your System ID in SAI, started from this app:** *Others → System ID*. The certificate is
   made for that ID, and SAI under Wine has its own, so an ID from a Windows PC will not work.
4. **Download the certificate.** Enter the licence number, the password and the System ID on
   this page, and you get a file named `sai-….slc`:
   **[systemax.jp/en/license.html](https://www.systemax.jp/en/license.html)**
5. **Install it with the app:** *Setup → Show all steps → SAI license → Install…*, and pick that
   file. The app puts it in every folder SAI may read it from and keeps a copy for later.

Lost the email? SYSTEMAX can send it again:
[systemax.jp/en/sai/reissue.php](https://www.systemax.jp/en/sai/reissue.php)

This project is not affiliated with SYSTEMAX and cannot sell, make or unlock a licence.

### Reported working

Users have reported it working on:

- Macs: **M5 MacBook Air** and **M3 Pro MacBook Pro** on **macOS Tahoe 26**, **M1 Pro MacBook Pro**,
  and an Intel **MacBook Air 13" (2019, Core i5, 8 GB)** on **macOS Sonoma 14.5** (app 0.3.18)
- Tablets: **Wacom Intuos S**, over USB and Bluetooth (CTL-4100 and CTL-4100WL)
- Displays: one screen, two screens mirrored, two screens extended, a screen connected while SAI is
  open, and an external LG UltraFine
- Wine: **Wine Staging 11.16 (Gcenx) with the Retina patch**, the build Setup installs
- SAI: **PaintTool SAI Ver.2 (64-bit)**

If you try another Mac or tablet, a short report as an issue helps the next person, whether it
worked or not (see [CONTRIBUTING](CONTRIBUTING.md)).

---

## What you get

**Drawing**

- **Real pen pressure** in SAI, with adjustable levels (up to 8192), pen feel presets and your own profiles
- **Mouse and trackpad still paint normally** — no need to unplug anything
- Works over **Bluetooth as well as USB** (USB samples faster, which shows on quick strokes)
- Works across **multiple monitors**

**It behaves like a Mac app, not Windows in a box**

- **⌘Z / ⌘Y / ⌘S** and the rest, rather than Ctrl — remapped inside Wine, so SAI simply sees the right keys
- **⌥ is Alt** (hold it for the eyedropper). Each key can be changed on the **Keys** tab, for example to keep one ⌥ for typing @ or €
- **Pinch to zoom** and **two-finger scroll to pan** on the trackpad
- **⌃⌥⌘Space** brings back a SAI window that has gone missing, and it can do that automatically when you switch back to SAI
- **Sharp, full-resolution SAI on Retina screens**, without the drawing lag, with a Wine that has the fix (Setup installs one)
- **Chinese, Japanese and Korean text instead of boxes**, with the fonts already on your Mac, and **SAI's menus in Japanese** if you like

**[Canvas timelapse](#credit)** *(v0.2.0+)*

- **A frame each time the pen rests**, or after every stroke if you turn that on — hours of drawing become a couple of minutes
- Records the **canvas, not the screen**: no panels, no cursor, and no camera lurching when you zoom or pan
- Layer opacity and blend modes come through; **several open canvases become one video each**
- Pick a target length; it encodes as you draw, so it costs megabytes rather than gigabytes

**Drawing statistics**

- **Time and strokes** by week, month, year or all time, your average day and your streak
- **By day, by hour, by weekday, and a calendar** of the whole year
- Counted from the pen itself, so it works with recording off, and stays on your Mac
- **Export CSV…** with every day and every hour, for your own charts

**Setup and upkeep**

- **One app, no terminal.** Wine is installed for you, with progress
- Licence handling, including the two-folders trap that silently stops SAI saving
- **Update SAI in place** when a new build lands, keeping your licence, brushes and preferences
- **Updates itself** when you let it, from the GitHub releases, and never while SAI is open
- Reset, reinstall or uninstall from the same window; logs and a health check when something is odd
- **Copy problem report** collects what an issue needs in one paste, with your user name hidden

## Why not just run a virtual machine?

That is what most people do, and it works. It is also heavy for what you get. When this project
started, a VM was the only way: nothing else gave SAI pen pressure on a Mac.

| | Virtual machine | This project |
|---|---|---|
| **Cost** | a Windows licence, plus the VM app if it is a paid one | **free, and open source** |
| Disk | tens of gigabytes | ~300 MB for Wine, plus SAI itself |
| Memory | a whole second OS running alongside macOS | a translation layer, only while SAI is open |
| Your tablet | forwarded over virtual USB into the guest | stays on macOS, using the driver you already have |
| Pen pressure | depends on USB passthrough and the guest's driver | read natively on macOS and handed to SAI |
| Starting SAI | boot the VM, wait, then launch SAI | double-click |
| Timelapse | screen-record the window, panels and cursor and all | **built in** — records the canvas itself |

<p align="center">
  <img src="docs/assets/vm-vs-bridge.svg" alt="Where pen pressure travels. In a virtual machine: tablet, then macOS, then virtual USB forwarded by the VM app, then a Windows driver inside the guest, then SAI in Windows; the virtual USB and the guest driver are where pressure gets lost or arrives late. With SAI Pen Pressure: tablet, then the tablet driver on macOS as usual, then SAI Pen Pressure, which adds your pen feel, then over UDP to our wintab32.dll inside SAI, then SAI in Wine, which asks for pen packets the Windows way." width="100%">
</p>

The tablet row is the one that decides it: in a VM your pen has to survive being forwarded through
virtual USB and picked up again by a Windows driver inside the guest, which is exactly where
pressure gets lost or arrives late. Latency you would never notice in a spreadsheet is intolerable
in a brush stroke.

SAI itself is commercial software either way — you need a licence from SYSTEMAX to *save*, whichever
route you take. What this saves you is the Windows licence and the machine around it.

→ **[The longer version](https://ametrien.github.io/Paint-Tool-SAI-pen-pressure-macOS-fix/#why-not-just-run-a-virtual-machine)**, including the honest
trade-off: a VM runs real Windows, so when something misbehaves there it is SAI's fault rather than
the translation layer's.

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

Recording is on by default. Draw; when you close SAI, the video is made and filed under the
drawing's name in the **Videos** tab, in `~/Movies/SAI Timelapses`. Come back to the same drawing
another day and it is added to the same video. **Make video now…** in the Recording tab makes one
mid-session; recording carries on afterwards.

> **Tested on SAI Ver.2 Alpha.2026.07.27 and Alpha.2026.10.19** (v0.3.17 and later). Recording
> reads SAI's memory, and the place it reads moves from one SAI build to the next. With a build
> it does not know, it looks for the canvas by itself, and the Recording tab says whether that
> worked. If it did not, nothing is recorded
> ([#56](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/issues/56)).

It reads SAI's canvas out of memory rather than capturing the screen, so the video is the artwork
alone: no panels, no cursor, and no camera movement when you zoom, pan or rotate while working.
Layer opacity and blend modes come through, and several open canvases each get their own video.

→ **[More about recording](https://ametrien.github.io/Paint-Tool-SAI-pen-pressure-macOS-fix/#canvas-timelapse)** — video length, what happens to undo, and
how much disk it uses

---

## What it does not do

**Not included, by design**

- **SAI and its licence.** Bring your own. This project cannot supply, generate or activate a
  licence, and never will.
- **Changes to SAI itself.** Nothing patches `sai2.exe`. The bridge is a `wintab32.dll` that SAI
  loads through its own WinTab support, plus a helper that runs on macOS.
- **Accounts, analytics, telemetry.** The app's only network use is GitHub: checking for new
  versions of itself and of Wine, and downloading them. *Copy problem report* goes to your
  clipboard, with your user name hidden by default.
- **Windows or Linux.** For the timelapse there, use
  [art-timelapse](https://github.com/cromachina/art-timelapse) (see [credit](#credit)).
- **Notarisation.** Releases are ad-hoc signed and not notarised (that needs a paid Apple
  Developer membership). Hence the one-time right-click → Open, and Input Monitoring has to be
  granted again after each update.

**Limits of the bridge**

- **Pressure only.** Tilt, rotation and the eraser end are not forwarded; the test tablet has
  none of them.
- **One tablet tested** (Wacom Intuos CTL-4100). Any tablet macOS itself recognises should work,
  because the helper reads standard tablet events, but Huion, XP-Pen and others are untested.
- **Bluetooth report rate (~130 Hz)** makes fast curves boxy; USB gives ~200 Hz
  ([why](https://ametrien.github.io/Paint-Tool-SAI-pen-pressure-macOS-fix/troubleshooting#fast-curves-come-out-boxy)).
- **A screen connected while SAI is open** may need SAI restarted before it gets pressure. Until
  then the pen works there as a mouse, and the menu-bar icon says so
  ([#37](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/issues/37)).

**Limits that belong to SAI or Wine**, worked around where possible

- **SAI can freeze on input after switching apps** (Wine's macOS driver). The app wakes it when
  you come back; if it still sticks, press **⌃⌥⌘Space** or use the pen icon in the menu bar →
  *Wake SAI*.
- **The pen cannot click SAI's top menu row** (File, Edit, …): SAI drops the click once it knows a
  pen is present. Use the trackpad or mouse for the menu
  ([#1](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/issues/1)).
- **Some small panel icons stay tiny at 200% scaling.** They are fixed-size bitmaps inside SAI;
  only SYSTEMAX can change them
  ([#45](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/issues/45)).
- **Wine is an Intel build.** Gcenx's Wine Staging runs under Rosetta on Apple Silicon, and Apple
  ends Rosetta for apps with **macOS 28** (expected autumn 2027). The app itself is native and not
  affected; Wine has to move to an Apple Silicon build that runs SAI's x86 code through the FEX
  emulator. Those exist in preview; the plan is in
  [KNOWN_ISSUES](KNOWN_ISSUES.md#4-wine-runs-under-rosetta-and-rosetta-ends-with-macos-28)
  ([#30](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/issues/30)).

**[KNOWN_ISSUES.md](KNOWN_ISSUES.md)** has the full explanation of each, what was tried, and
what did not work.

---

## What it looks like

Seven tabs, one window. Each tab is described below.

<p align="center">
  <a href="docs/assets/screenshots/all-tabs.png"><img src="docs/assets/screenshots/all-tabs.png" alt="All seven tabs. Top row: Setup, with Launch and Wake SAI; Pen, with pressure levels, pen feel presets, the curve and two more feel sliders, and Test pen; Keys, with what each Option and Command key sends; Recording, with the timelapse switches and save folder. Bottom row: Videos, a grid of drawings with a bar for the selection; Statistics, with the total, days drawn, average day and streak for the month, and a bar for each day; Advanced, with developer mode, automatic updates, sharp text on Retina screens, the Language menu with the font in use, and the Wine in use." width="100%"></a>
</p>

### Setup

<p align="center"><a href="docs/assets/screenshots/setup.png"><img src="docs/assets/screenshots/setup.png" alt="The Setup tab: Launch SAI with Pressure, the setup check, Wake SAI, Auto-wake, Show all steps, Copy problem report and More." width="70%"></a></p>

Where you start SAI, and where installing happens.

- **Launch SAI with Pressure** starts SAI with the bridge in place. **Wake SAI** and **Auto-wake**
  bring SAI back when it stops reacting after you switch apps.
- **Show all steps** lists what SAI needs: Wine, your SAI folder, SAI installed into Wine, the
  pressure bridge, your licence (optional) and the Input Monitoring permission. Each has its own
  fix button, and **Set up everything automatically** does them in order.
- **More** has *Update SAI…* (a newer SAI build, keeping your licence, brushes and preferences),
  *Reset everything & reinstall…* and *Uninstall…*.
- **Copy problem report** puts everything an issue needs on your clipboard.

It does not download SAI or a licence for you: you point it at a SAI folder you already have.

### Pen

<p align="center">
  <a href="docs/assets/screenshots/pen.png"><img src="docs/assets/screenshots/pen.png" alt="The Pen tab: pressure levels, the pen feel preset, the pen feel curve with its plot, Ignore light touch, Full width at, and the Test pen button." width="49%"></a>
  <a href="docs/assets/screenshots/pen-test.png"><img src="docs/assets/screenshots/pen-test.png" alt="The Pen tab during Test pen: a sending bar at 1549 of 4095 and a receiving bar showing packets and the peak that reached SAI." width="49%"></a><br>
  <sub>Left: the Pen tab. Right: the same tab with Test pen running.</sub>
</p>

How the pen feels in SAI. Pen feel changes apply instantly, without restarting SAI.

- **Pressure levels:** *Auto* uses what your tablet reports; 1024 to 8192 can be set by hand.
  SAI reads this when it starts, so quit and reopen SAI after changing it.
- **Pen feel:** presets named by what you are doing (*Normal*, *Light hand*, *Inking*, *Painting*,
  *Heavy hand*), and up to three profiles of your own, saved, renamed and deleted from the same menu.
- **Pen feel curve**, **Ignore light touch** and **Full width at** fine-tune a preset. The small
  plot shows the result.
- **Test pen** shows two bars: what the app sends, and what actually arrives on SAI's side of the
  bridge. If the first moves and the second stays flat, the app tells you what to press.

It does not change SAI's own brush settings. Pen feel works on top of them, so a brush's
*Min Size* still applies.

### Keys

<p align="center"><a href="docs/assets/screenshots/keys.png"><img src="docs/assets/screenshots/keys.png" alt="The Keys tab: what the left and right Option and Command keys send to SAI, Restore defaults, and the Try a key box." width="70%"></a></p>

What each ⌘ and ⌥ key sends to SAI: *Ctrl*, *Alt*, or *Option (types special characters)*, set
separately for the left and right keys. By default ⌘ is Ctrl (⌘Z, ⌘S…) and ⌥ is Alt (the
eyedropper). **Try a key** shows what a key press turns into, without sending anything to SAI.

SAI reads these when it starts, so a change applies the next time SAI opens.

### Recording

<p align="center"><a href="docs/assets/screenshots/recording.png"><img src="docs/assets/screenshots/recording.png" alt="The Recording tab: Record a timelapse while I draw, Record every stroke separately, Video quality set to Standard (1024 px), and the folder videos are saved to." width="70%"></a></p>

The canvas timelapse. Tick **Record a timelapse while I draw**, choose where videos are saved, and
draw. The video is made when SAI closes. **Record every stroke separately** gives more detail, at
the cost of drawing feeling slower. **Video quality** is Standard (1024 px) or High (2048 px):
High keeps fine lines sharper, and the videos are larger.

A line under the settings names your SAI build and says whether recording works with it. It
records the canvas, not the screen: no panels, no cursor, no zooming, and no sound. Changes
apply the next time SAI starts.

### Videos

<p align="center"><a href="docs/assets/screenshots/videos.png"><img src="docs/assets/screenshots/videos.png" alt="The Videos tab: a grid of drawings as stills, and the bar under it with Play, Export, Show in Finder and Delete." width="70%"></a></p>

One video per drawing, even when you work on it over several evenings, shown as a grid of stills.
Hover over a still to play it, double-click to open it.

- **Select** the way Finder does: click one, ⌘-click to add or remove one, Shift-click for a
  range, ⌘A for all.
- The bar under the grid acts on the selection: **Play**, **Export…** (a copy at 30 seconds, 1 or
  2 minutes, or full length), **Show in Finder** and **Delete…**.
- **Delete** asks once, says exactly what goes, and moves it to the Trash, so a wrong click can be
  undone. Several videos can go at once.
- **Right-click** a video to rename the drawing, list its sessions (to take out one that was filed
  with the wrong drawing) or rebuild the video.

It does not edit videos beyond choosing their length.

### Statistics

<p align="center"><a href="docs/assets/screenshots/statistics.png"><img src="docs/assets/screenshots/statistics.png" alt="The Statistics tab for the last month, Days view: 55 h and 200,095 strokes in total, 25 of 30 days drawn, an average day of 2 h 12 min and a streak of 4 days, best 9. Below, a bar for each day's drawing time with a line at the average day, then all-time totals, the best day and Export CSV." width="70%"></a></p>

How much you draw, counted while SAI is the app in front, whether or not you record.

- Look at the last **Week**, **Month** or **Year**, or **All time**. For each you get the total
  time and strokes, how many of the days you drew, your **average day**, and your **streak** of
  days in a row with the best one.
- Four views:
  - **Days**: a bar for each day, with a line at your average day.
  - **Hours**: which hours of the day you draw in, and when you draw most.
  - **Weekdays**: your average Monday, Tuesday and so on, days off included.
  - **Calendar**: every day of the year, coloured by how long you drew. Point at a day to see
    its time, strokes, sessions, and when you started and stopped.
- All-time totals and your best day, always at the bottom.

<p align="center">
  <a href="docs/assets/screenshots/statistics-hours.png"><img src="docs/assets/screenshots/statistics-hours.png" alt="The Hours view: drawing time by hour of the day over the last 30 days, mostly in the evening and at night, around 22:00." width="32%"></a>
  <a href="docs/assets/screenshots/statistics-weekdays.png"><img src="docs/assets/screenshots/statistics-weekdays.png" alt="The Weekdays view: the average drawing time for each day of the week, highest on Saturday with 4 h 11." width="32%"></a>
  <a href="docs/assets/screenshots/statistics-calendar.png"><img src="docs/assets/screenshots/statistics-calendar.png" alt="The Calendar view: every day of 2026 as a square, coloured from none to 2 h or more, with hours per month, and the day pointed at shown below: Thursday, 19 November, 12 min, 695 strokes, 1 session, 08:44 to 08:56." width="32%"></a>
</p>

- **Export CSV…** saves every day as a row for a spreadsheet: strokes, drawing and pen time,
  average stroke, strokes per minute, sessions, the longest session, first and last stroke, and
  minutes in each hour.
- The menu bar shows today's total once you have drawn.

Drawing time is the time the pen is down plus short pauses between strokes. A pause over a minute
is a break and is not counted, and nor is time with SAI open but not drawing. It counts strokes and
time, not what you drew or in which canvas.

### Advanced

<p align="center"><a href="docs/assets/screenshots/advanced.png"><img src="docs/assets/screenshots/advanced.png" alt="The Advanced tab: Developer mode, Install updates automatically, Sharp text on Retina screens, the Language menu with the font in use, and the Wine in use." width="70%"></a></p>

- **Install updates automatically**, never while SAI is open.
- **Display › Sharp text on Retina screens:** SAI at your screen's full resolution
  ([details](#sharp-text-on-retina-screens-without-lag)).
- **Display › Language:** SAI's menus in English or 日本語, and the font for Chinese, Japanese and
  Korean text, so it shows instead of boxes ([details](#chinese-japanese-and-korean-text)).
- **Wine:** the Wine in use, whether it has the fix for the Retina drawing lag, and buttons to add
  the patch or update Wine.
- **Developer mode** adds the logs, a health check, a diagnostics dump and shortcuts to SAI's
  folders inside Wine.

---

## Sharp text and languages

### Sharp text on Retina screens, without lag

1. **Check that your Wine has the fix** in **Advanced › Wine**. A new install gets one. If yours is older,
   press **Update Wine for sharper, faster drawing** (quit SAI first), or **Add patch** if you have Wine Staging 11.16.
   Wine **11.22 or newer** has the fix built in, once it is released.
2. **Advanced › Display › Sharp text on Retina screens.** With the fix in place it is on by default.
3. **In SAI, set Window › Scaling of User Interface to 200%**, then quit and reopen SAI so its panels land
   where they should. If you turn sharp text off again, set it back to 100% and restart SAI once more.

Some small panel icons stay small at 200%. That is SAI's own icon art
([#45](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/issues/45)).
Why the fix is needed: [issue #39](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/issues/39) and
[RETINA-LAG-FINDINGS.md](RETINA-LAG-FINDINGS.md).

### Chinese, Japanese and Korean text

SAI asks for Windows fonts that a Mac does not have, so without help these characters show as boxes.
**Advanced › Display › Language** fixes that with the fonts that come with your Mac:

- **English** or **日本語** for SAI's menus. SAI's menus only come in these two languages.
- **Chinese, Japanese and Korean text**, such as layer names, file names and dialogs, shows with either:
  the app uses Hiragino Sans, PingFang and Apple SD Gothic Neo, in the order of your Mac's languages.
- **Your own fonts** installed with Font Book are in the list too. *Add a font…* takes one you downloaded:
  it opens in Font Book to install. The path of the font in use is shown, with *Copy path*.

The app never copies, bundles or downloads a font; it only points Wine at the fonts on your Mac.
SAI's Text tool is not affected: it uses its own font engine, which does not support these fonts yet.
A change takes effect the next time SAI starts.

<p align="center"><a href="docs/assets/screenshots/sai-japanese.png"><img src="docs/assets/screenshots/sai-japanese.png" alt="SAI with its menus and panels in Japanese, every character readable." width="80%"></a></p>

#### Your own fonts

Fonts you installed with Font Book show up under **Your fonts** in the same menu. SAI's menus and
panels then use that font for Chinese, Japanese and Korean, and the path is shown with *Copy path*.
Use fonts whose licence lets you use them; the app never copies them.

<p align="center"><a href="docs/assets/screenshots/font-menu.png"><img src="docs/assets/screenshots/font-menu.png" alt="The Language menu in Advanced: English, 日本語, then Your fonts with installed Japanese fonts, Add a font and Off." width="55%"></a></p>

<p align="center">
  <a href="docs/assets/screenshots/sai-font-mitsu.png"><img src="docs/assets/screenshots/sai-font-mitsu.png" alt="SAI's Japanese menus drawn in the handwritten MitsuFont." width="49%"></a>
  <a href="docs/assets/screenshots/sai-font-shigoto.png"><img src="docs/assets/screenshots/sai-font-shigoto.png" alt="SAI's Japanese menus drawn in ShigotoMemogaki." width="49%"></a><br>
  <sub>MitsuFont (left) and ShigotoMemogaki (right)</sub>
</p>

---

## Your brushes, textures and presets

SAI keeps them where it does on Windows, in your **Documents** folder:
**Documents › SYSTEMAX Software Development › SAIv2 › settings**. Wine gives SAI your Mac's own
Documents folder, so this is an ordinary folder you can open in Finder. It appears the first time
SAI starts.

In it are your tools and brush presets (`custool`), brush textures (`brushtex`), paper textures
(`papertex`), scatter shapes (`scatter`), brush shapes (`blotmap`, `bristle` and `brshape`, inside
`brushfom`) and swatches (`swatch`). Updating SAI, Wine or this app does not touch it, and neither
do *Reset everything & reinstall…* and *Uninstall…*.

**From a PC: your whole settings folder**

1. **Start SAI once from the app**, then close it.
2. **On the PC**, in File Explorer open **Documents › SYSTEMAX Software Development › SAIv2**, and
   copy the `settings` folder to the Mac: a USB stick, a cloud drive, or zip it and send it to
   yourself.
3. **On the Mac**, with SAI closed, open the same folder: in Finder choose **Go › Go to Folder…**
   and paste `~/Documents/SYSTEMAX Software Development/SAIv2`. Rename the `settings` folder there
   to keep it (`settings-mac`, say), and put the PC's `settings` folder in its place. Check that
   `custool`, `brushtex` and the others are straight inside `settings`, not in a second `settings`
   folder inside it.
4. **Start SAI from the app.** Your tool tabs, presets and textures are there.

Replace the whole folder rather than copying files into it: SAI numbers its tools, so two sets
mixed together can mix up the tool panel. The PC's folder also brings the PC's window layout, so
the first time SAI may open at the PC's size or position.

**Brush and texture packs**

Packs people share are `.bmp` pictures, some with an `.ini` beside them, in folders named the way
SAI names them. With SAI closed, copy the files from each folder of the pack into the folder of the
same name in `settings`, then start SAI:

| Pack folder | Copy its files into | Where they show up in SAI |
|---|---|---|
| `brushtex` | `settings/brushtex` | a brush's texture list, `[ No Texture ]` |
| `blotmap`, `bristle`, `brshape` | the folder of the same name in `settings/brushfom` | a brush's shape list, `[ Simple Circle ]` |
| `papertex` | `settings/papertex` | **Layer Effect › Paper**, in the layer settings |
| `scatter` | `settings/scatter` | the Scatter tool's shape list (*Stars* at first) |

Copy only the `.bmp` and `.ini` files. Leave out `bak` folders, which are old copies, and any
`.exe` that comes with a pack: SAI does not need it.

A big pack does not slow SAI's start. With the whole Brush Collection from r/PaintToolSAI added
(2,195 files, 612 MB), SAI's window opened as quickly as without it, in under two seconds.

<p align="center">
  <a href="docs/assets/screenshots/brushes-texture.png"><img src="docs/assets/screenshots/brushes-texture.png" alt="A brush's texture list in SAI on a Mac: No Texture, Layer Paper, Acrylic from a brush pack, SAI's own Canvas, a home-made test texture with diagonal stripes, and Paper." width="24%"></a>
  <a href="docs/assets/screenshots/brushes-shape.png"><img src="docs/assets/screenshots/brushes-shape.png" alt="A brush's shape list: Berber, Bencil and Hexagon from a brush pack among SAI's own Blots, Bristle, Flat Bristle and Flat Face." width="24%"></a>
  <a href="docs/assets/screenshots/brushes-paper.png"><img src="docs/assets/screenshots/brushes-paper.png" alt="Layer Effect, Paper: the paper texture list with Berber from a pack and the striped test texture next to SAI's own textures." width="24%"></a>
  <a href="docs/assets/screenshots/brushes-scatter.png"><img src="docs/assets/screenshots/brushes-scatter.png" alt="The Scatter tool's shape list: two shapes from a pack, one with an accented name, next to SAI's Stars." width="24%"></a><br>
  <sub>Textures and shapes from a brush pack in SAI on a Mac: brush texture, brush shape, paper and scatter.</sub>
</p>

Tested with SAI Ver.2 Alpha.2026.10.19 and app 0.3.18: a whole settings folder (its tool tab
names and presets came through) and the Brush Collection from r/PaintToolSAI.

---

## Something not working?

First: **[Troubleshooting](https://ametrien.github.io/Paint-Tool-SAI-pen-pressure-macOS-fix/troubleshooting)**,
organised by how to tell which problem you have. If pressure is the problem, the **Pen** tab's
**Test pen** shows two bars: what the app sends, and what actually arrives on the other side,
inside Wine, where SAI would read it. If the top one moves and the bottom stays flat, the app
will tell you what to press.

<p align="center">
  <img src="docs/assets/test-pen.svg" alt="Finding a pressure problem with Test pen. Strokes come out all one width, or there is no pressure: on the Pen tab press Test pen, press the pen on the tablet and watch both bars. Neither bar moves: macOS isn't passing the pen on, so turn on Input Monitoring for SAI Pen Pressure in System Settings and reopen the app. Top moves, bottom stays flat: Wine isn't loading the bridge, so press Repair in the Pressure bridge row on the Setup tab. Both bars move: the fault is inside SAI, so turn on Use WinTab API, quit SAI fully and reopen it, and keep the brush's Min Size below 100%. Still stuck: Copy problem report on the Setup tab and open an issue." width="100%">
</p>

If that doesn't sort it, **[open an issue](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/issues/new/choose)**
and start it with **Copy problem report** on the Setup tab.

That one button collects everything needed to help: your Mac and chip, macOS and Wine versions,
your tablet and how it is connected, whether Wine is loading the pressure bridge or ignoring it,
what SAI last received, and the recent log. Paste it into the issue and there is usually nothing
else to gather.

**Please write issues in English.** A machine translation (DeepL, Google Translate, ChatGPT) is
completely fine — I just can't read Chinese, Japanese, Korean and so on, and I'd rather not guess at
what you meant. You're welcome to paste your original text underneath the translation.

请用英文提交 issue（机器翻译即可）· Issue は英語でお願いします（機械翻訳で大丈夫です）

---

## How it works, in short

Wine already runs SAI on a Mac and moves the cursor, but its Mac driver throws pen **pressure**
away. This project adds it back with a two-part bridge:

- a **custom `wintab32.dll`** that speaks the WinTab tablet API to SAI, loaded by Wine in place of
  its own (no Wine rebuild), and
- a small **native macOS helper** that reads your tablet's real pressure and sends it to that DLL.

→ **[How it works](https://ametrien.github.io/Paint-Tool-SAI-pen-pressure-macOS-fix/how-it-works)**, the full architecture

## How it fits together

<p align="center">
  <img src="docs/assets/architecture.svg" alt="Architecture. On the left, your SAI folder and the tablet feed SAI Pen Pressure.app in /Applications: its Setup window copies SAI and your licence into the Wine prefix, its pen engine sends every pen sample, pinch-to-zoom step and wake request over UDP to our wintab32.dll, and a few small files carry the rest. On the right, Wine Staging.app in /Applications runs sai2.exe from the prefix ~/SAI2-pressure, which holds drive_c/SAI2 with sai2.exe and your licence (next to sai2.exe and in settings/), windows/system32/wintab32.dll, the drive_c/wt_*.txt files (pressure scale, bridge status and fallbacks), the registry files, and the timelapse frames. Below, the app keeps its settings and a copy of your licence in ~/Library/Application Support/SAIPenPressure, and a separate encoder turns the frames into videos in ~/Movies/SAI Timelapses." width="100%">
</p>

**The pen.** The tablet moves the cursor in every app, but the pressure stops at macOS. The app
reads it through an event tap, applies your pen feel, and sends each sample over UDP
(`127.0.0.1:47800`) to our `wintab32.dll`. Wine loads that DLL into `sai2.exe` in place of its
own, so SAI asks it for pen packets the ordinary Windows way. If the port is busy, the DLL reads
the newest sample from `C:\wt_pressure.txt` instead.

**Where things live.**

| What | Where |
|---|---|
| The app | `/Applications/SAI Pen Pressure.app` |
| Wine | `/Applications/Wine Staging.app` (installed by the app if missing) |
| SAI's own Windows drive (the Wine prefix) | `~/SAI2-pressure` |
| SAI itself | `~/SAI2-pressure/drive_c/SAI2/` |
| Your licence | the original `.slc` file from SYSTEMAX, copied to `~/SAI2-pressure/drive_c/SAI2/` **and** `~/SAI2-pressure/drive_c/SAI2/settings/`, because older and newer SAI builds read it from different folders |
| A spare copy of the licence | `~/Library/Application Support/SAIPenPressure/license/`, so a rebuilt prefix gets it back |
| Our DLL | `~/SAI2-pressure/drive_c/windows/system32/wintab32.dll`, replaced from the app on every launch when they differ |
| App settings | `~/Library/Application Support/SAIPenPressure/` |
| Timelapse videos | `~/Movies/SAI Timelapses/`, one folder per drawing |

The SAI folder you pick during setup is only a source: SAI is copied into the prefix and runs
from there.

**The same port, and a few small files.** Pinch-to-zoom steps and Wake SAI requests travel on
the pen port too, so SAI reacts at once. The rest goes through text files in
`~/SAI2-pressure/drive_c`: the pressure scale (`wt_pmax.txt`, written before SAI starts) and the
DLL's own report (`wt_status.txt`), which is how the app knows the bridge really is loaded inside
SAI. Zoom and wake are also written to `wt_zoom.txt` and `wt_wake.txt`, as a fallback for when the
port is not reaching the DLL.

**The timelapse.** Because the DLL runs inside SAI, it can read the canvas straight from SAI's
memory after a stroke and write it to `drive_c/sai-timelapse/frames/`. A separate encoder process
turns those frames into H.264 video, so video work never slows the pen, and the Videos tab groups
sessions of the same drawing into one video.

**A session, step by step.** Setup happens once. After that, **Launch SAI** prepares the bridge
and starts SAI, every pen sample goes from the tablet through the app to our DLL while you draw,
and closing SAI finishes the video and quits the app with it.

<p align="center">
  <img src="docs/assets/user-journey.svg" alt="Sequence diagram of a session, with six participants: you, the tablet, the app, SAI running in Wine, our DLL inside SAI, and the encoder. The first time: you open the app and pick your SAI folder; the app installs Wine if it is missing and copies SAI and your licence into ~/SAI2-pressure; you allow Input Monitoring and reopen the app. Every time you start: you press Launch SAI; the app updates our DLL if it changed and saves the tablet's pressure levels for it, starts the encoder if recording is on, and starts sai2.exe in Wine, which loads wintab32.dll; the first time only, you turn on Use WinTab API in SAI. While you draw: your stroke's pressure reaches the app through the event tap, every sample goes over UDP to our DLL, which hands pen packets to SAI, and a canvas frame goes to the encoder. When you close SAI: you save and quit SAI, the Wine process ends, the app stops the encoder so it finishes the video, files the video with its drawing and quits; the timelapse is saved in ~/Movies." width="100%">
</p>

The full story, with the reasons behind each choice, is in
[How it works](https://ametrien.github.io/Paint-Tool-SAI-pen-pressure-macOS-fix/how-it-works).

## Build from source (contributors)

`make-app.sh` builds everything into `dist/`: the helper and the timelapse encoder as universal
binaries, from the file lists in `wacom-helper/sources.txt` and `timelapse-encoder/sources.txt`,
and the app bundle around them. Only `wintab32.dll` and the test probe `wtprobe.exe` are committed
prebuilt, because cross-compiling them needs mingw-w64, and the app icon `icon/AppIcon.icns`,
because the picture it is drawn from may not be kept here (`tools/make-icon.swift` says how to
draw it again). By hand:
```bash
# wintab32.dll and the test probe  (brew install mingw-w64)
cd wintab-src
x86_64-w64-mingw32-windres wintab32.rc -O coff -o wintab32_res.o
x86_64-w64-mingw32-gcc -shared -O2 -o wintab32.dll wintab32.c wintab32_res.o wintab32.def \
    -lgdi32 -luser32 -lws2_32 -municode
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o wtprobe.exe wtprobe.c -luser32

# native helper  (Xcode command-line tools)
cd ../wacom-helper
swiftc -O -o wacom-pressure-helper $(bash ../tools/sources.sh helper)
```

Tests: `bash tests/run-tests.sh` runs the C cores under AddressSanitizer and UBSanitizer, the
Swift cores, and the end-to-end checks on a real filesystem. CI runs the same script on every push.

## Support

The best support is simply using SAI Pen Pressure and telling me what goes wrong, in an
[issue here on GitHub](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/issues).
If you'd really like to do more, you can [buy me a coffee on Ko-fi](https://ko-fi.com/ametrien).

Contributions welcome — especially testing on other tablets and Macs.

---

## Credit

**The canvas timelapse is our own implementation, inspired by
[art-timelapse](https://github.com/cromachina/art-timelapse).** How we built it, step by step:
[TIMELAPSE-PLAN.md](TIMELAPSE-PLAN.md).

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

art-timelapse is GPL-3.0 and this project is not, which is why the boundary was worth keeping clear.

**The app icon** is "Pen" by gravisio from Flaticon:
[Drawing icons created by gravisio - Flaticon](https://www.flaticon.com/free-icons/drawing).
It is used under Flaticon's free licence, which asks for this credit, and is not under the GPL.

## License & attribution

This project (the pressure-bridge code: the `wintab32.dll` source, the macOS app, the installer
and the documentation) is released under the **[GNU GPL version 3](LICENSE)**, with the
additional terms in **[NOTICE](NOTICE)**. You may use it, change it and share it. If you share a
copy or a version of your own:

- it stays under the GPL 3, with its source code available;
- keep the NOTICE with it, and the credit "SAI Pen Pressure by ametrien" with a link here,
  wherever it shows credits or About information, and in its documentation;
- say that you changed it, and do not present it as the original.

Versions up to and including **0.3.16** were released under the MIT License, and **0.3.17** under
the Apache License 2.0. Those copies stay under those licences.

The Wine Mac driver in [wine-patch/](wine-patch/) is a modified part of Wine and stays under
Wine's own licence, the GNU LGPL 2.1 or later.

**PaintTool SAI** is proprietary software by SYSTEMAX Software Development (Koji Komatsu).
This project does **not** include — and must never include — SAI itself, its installer, or
any license certificate. You get those from SYSTEMAX yourself:
[where to get SAI and a licence](#get-sai-and-a-licence).
The licence here covers only the bridge code in this repository.
