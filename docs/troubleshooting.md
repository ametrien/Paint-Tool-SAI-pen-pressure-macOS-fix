---
title: Troubleshooting
---

[← back](index.md)

Most reports fall into one of these. Each entry says **how to tell**, not just what to do.

---

## The pen draws, but every stroke is the same width

Pressure isn't reaching SAI, *or* SAI is ignoring it.

1. **Read the "Pressure bridge" row on the Setup tab.** It answers this on its own. With SAI
   closed it checks the two things that decide whether SAI can get pressure at all: our
   `wintab32.dll` in the Wine prefix, and the Wine setting that makes SAI load it instead of
   Wine's own (without that setting the file is ignored and every stroke is flat). If it's red,
   press **Repair** — it takes a second and touches nothing else. **While SAI is running the same
   row reports from inside SAI**: whether SAI asked for a tablet at all, whether pressure is
   arriving, and how many points SAI has actually drawn from the pen.
2. **Test it outside SAI first.** In the **Pen** tab press **Test pen**, then press the pen on the
   tablet. Two bars move: the top one is what this app *sends*, the bottom one is what actually
   *arrives* inside Wine, where SAI reads it. Between them they place the fault on their own, with
   SAI closed:
   - **Neither moves** — the problem is on the macOS side. See *no pressure at all* below.
   - **Top moves, the bottom stays flat** — Wine is not loading our bridge, so SAI would get
     nothing. A line underneath says so and points at **Repair** on the Setup tab.
   - **Both move** — the bridge works end to end, so the fault is inside SAI. Steps 3 and 4.

   <p align="center">
     <img src="assets/screenshots/pen.png" width="620"
          alt="The Pen tab during a test: a sending bar reading 983 of 4095, and below it a receiving bar with a packet count and peak, both filled">
   </p>

   *Both bars moving, as above, means pressure is reaching SAI's side of the bridge.*
3. **Check SAI's tablet API.** *Others → Options → Pen Tablet →* **Use WinTab API**, then quit
   SAI **completely** and relaunch. A rebuilt Wine prefix resets this.
4. **Check the brush.** Test with the **AirBrush** tool: its stock settings show pressure most
   clearly, so a stroke that still comes out flat there is a real fault rather than a brush
   setting. On other brushes, look at **Min Size** in the tool panel: at 100% pressure cannot
   change stroke width — every stroke draws full width no matter how hard you press. Try ~10%.

## No pressure at all — the bar never moves

Almost always the permission.

- **System Settings → Privacy & Security → Input Monitoring** must list **SAI Pen Pressure**,
  switched **on**.
- **macOS will not prompt you** for downloaded releases. You have to add it by hand — see
  [Install](install.md#input-monitoring).
- The grant is matched **by path** for unsigned apps: move the app after granting and you must
  grant again. Put it in **/Applications** first.
- macOS only applies a new grant on a **fresh launch**. Quit and reopen the app.

## Bluetooth: the tablet is connected, and macOS ignores it anyway

I've seen this happen on a Mac with none of this installed, so it isn't ours and nothing here can
fix it: the pen never reaches macOS in the first place, so there is nothing for us to pass on. It
still earns a place on this page, because it is part of drawing on a Mac with a Wacom — and
because from the outside it looks exactly like a broken install.

**How to tell.** The tablet is paired and shown as connected, the Pen tab even names it
(*"Intuos BT S connected"*), and still nothing happens: the cursor doesn't move and **Test pen**
stays flat. That line naming your tablet comes from asking macOS which devices exist, which says
only that it is there, not that it is sending anything. Plug the USB cable in: if the pen works
that way, this is what you have.

**Fix: restart the Wacom driver.** Both lines, in this order:

```bash
pkill -f "WacomTabletDriver|TabletDriver.app|WacomTouchDriver"
```

```bash
launchctl kickstart -k "gui/$(id -u)/com.wacom.wacomtablet"
```

The second one matters: on the Mac this was written from, the drivers did **not** come back on
their own after the first, and the tablet was dead until they were kicked back up. Give it a few
seconds, then try the pen again.

If it's still silent: power the tablet off and on, toggle Bluetooth off and on, or use the USB
cable, which sidesteps the whole thing.

*Unrelated but often noticed at the same time:* over Bluetooth the tablet doesn't publish its
pressure range, so the Pen tab says *"No range reported over Bluetooth, using 4096"*. That's
normal, not a fault — the number is remembered rather than measured.

## SAI won't save — "licence" errors

Your certificate is probably in the wrong folder for your build of SAI.

Where SAI reads the `.slc` **changed between builds**: older Ver.2 builds read it next to
`sai2.exe`, while the **2026-07-12 Technical Preview Major Renovated** build reads it from a
`settings` folder. The wrong folder is indistinguishable from an invalid licence — SAI simply
refuses to save.

Use **Install…** on the *SAI license* row and it copies to **both**, so whichever build you run
finds it. The row then reports which locations are covered.

Since **v0.1.12**, a `.slc` already sitting in your own SAI folder is picked up automatically —
noticed when you choose the folder, and again on every install or reinstall, then copied to both
locations and kept so a rebuild can restore it. Before that it was only copied verbatim, so it
landed wherever it happened to sit in your folder, which may not be where your build reads from.

## The pen won't draw at all

**Upgrade — and check your version.** This exact symptom has shipped twice, from two unrelated
causes:

- **v0.1.5** — fixed in v0.1.6
- **v0.1.10** — fixed in v0.1.11

Both swallowed the click that starts every stroke. Pressure arrived perfectly the whole time, so
every diagnostic looked healthy while nothing painted, and no amount of reinstalling helped —
the bug was inside the bundled DLL, not your setup.

Two things make this hard to recognise, both worth knowing:

- **A stroke that never starts also has no pressure**, so it presents as *"pen pressure stopped
  working"* rather than *"clicks are ignored"*.
- It can look like a **permissions** problem, especially if it appears after a restart. In the
  v0.1.10 case the timing was pure coincidence — the bug had shipped days earlier and simply
  waited for the next launch.

If you are on v0.1.10, the giveaway in a `WT_DEBUG=1` log is a line reading `CLICK dedup: ate
msg=0x201` shortly after a pen-down, while the header of the same log says `dedup=off`.

Note that upgrading is enough: since **v0.1.11** the bundled DLL is refreshed on every launch.
Before that, installing a new version left the old DLL in place, so a DLL-side fix could reach
you only if you happened to reinstall.

## SAI stops responding to clicks after switching apps

A Wine focus bug, not a pressure one. Press **⌃⌥⌘Space**, or use **Wake SAI** in the setup
window or the menu-bar icon. Recent versions also auto-recover on returning to SAI.

## Two cursors — the macOS arrow sits on top of SAI's brush cursor

Known, intermittent at launch, [issue #20](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/issues/20).
Cosmetic — drawing is unaffected. Moving the pen usually clears it.

## Something else — collect diagnostics

Press **Copy problem report** on the **Setup** tab and paste it into an issue. No developer mode
needed. It reports the build, your Mac and chip, the macOS and Wine versions, your tablet and how
it is connected, what is installed where, whether Wine is loading the pressure bridge or ignoring
it, what SAI last received, and the tail of the log. That is almost everything anyone would
otherwise have to ask you for.

<p align="center">
  <img src="assets/screenshots/setup.png" width="620"
       alt="The Setup tab, with the Copy problem report button in the bottom row beside Reset everything and Uninstall">
</p>

For pen problems specifically, launch with the DLL's own log enabled:

```bash
osascript -e 'quit app "SAI Pen Pressure"'; sleep 2; \
  WT_DEBUG=1 "/Applications/SAI Pen Pressure.app/Contents/MacOS/SAIPenPressure"
```

Click **Launch SAI**, reproduce, then copy `~/SAI2-pressure/drive_c/wtlog.txt` — it is
overwritten on each launch. It shows exactly what SAI received.

---

[Home](index.md) · [Install](install.md) · [Troubleshooting](troubleshooting.md) · [How it works](how-it-works.md) · [Engineering notes](notes.md) · [GitHub](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix)

---

## Fast curves come out boxy


- **Connect the tablet by USB for smooth fast strokes.** A Wacom over **Bluetooth reports at
  only ~130 Hz**, versus **~200 Hz over USB**. At that lower rate, quickly-drawn *curves come out
  boxy* (too few points to trace the curve) — the bridge draws every point it's given, so the
  limit is the tablet's Bluetooth report rate, not the software. Plug in a **data** USB cable
  (not charge-only) for the higher sample rate and noticeably smoother fast lines. Bluetooth is
  fine for slower, deliberate drawing.
- If you must stay wireless, raising SAI's own **Stabilizer** setting smooths the path (at the
  cost of a little stroke "drag").
