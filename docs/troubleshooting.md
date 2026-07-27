---
title: Troubleshooting
---

[← back](index.md)

Most reports fall into one of these. Each entry says **how to tell**, not just what to do.

---

## The pen draws, but every stroke is the same width

Pressure isn't reaching SAI, *or* SAI is ignoring it.

1. **Test it outside SAI first.** In the setup window click **Test pen** and press. If the bar
   doesn't move, the problem is on the macOS side — see *no pressure at all* below. If it moves,
   macOS is fine and the problem is inside SAI.
2. **Check SAI's tablet API.** *Others → Options → Pen Tablet →* **Use WinTab API**, then quit
   SAI **completely** and relaunch. A rebuilt Wine prefix resets this.
3. **Check the brush.** In SAI's tool panel, **Min Size**. At 100% pressure cannot change stroke
   width — every stroke draws full width no matter how hard you press. Try ~10%.

## No pressure at all — the bar never moves

Almost always the permission.

- **System Settings → Privacy & Security → Input Monitoring** must list **SAI Pen Pressure**,
  switched **on**.
- **macOS will not prompt you** for downloaded releases. You have to add it by hand — see
  [Install](install.md#input-monitoring).
- The grant is matched **by path** for unsigned apps: move the app after granting and you must
  grant again. Put it in **/Applications** first.
- macOS only applies a new grant on a **fresh launch**. Quit and reopen the app.

## SAI won't save — "licence" errors

Your certificate is probably in the wrong folder for your build of SAI.

Where SAI reads the `.slc` **changed between builds**: older Ver.2 builds read it next to
`sai2.exe`, while the **2026-07-12 Technical Preview Major Renovated** build reads it from a
`settings` folder. The wrong folder is indistinguishable from an invalid licence — SAI simply
refuses to save.

Use **Install…** on the *SAI license* row and it copies to **both**, so whichever build you run
finds it. The row then reports which locations are covered.

Note that dropping the `.slc` into **your own** SAI folder does nothing — that folder is only a
source, copied at install time. See [How it works](how-it-works.md).

## The pen won't draw at all (v0.1.5 only)

**Upgrade.** v0.1.5 shipped a bug that swallowed the click that starts every stroke. Pressure
arrived perfectly, so every diagnostic looked healthy while nothing painted — and no amount of
reinstalling helped, because the bug was inside the bundled DLL. Fixed in v0.1.6.

## SAI stops responding to clicks after switching apps

A Wine focus bug, not a pressure one. Press **⌃⌥⌘Space**, or use **Wake SAI** in the setup
window or the menu-bar icon. Recent versions also auto-recover on returning to SAI.

## Two cursors — the macOS arrow sits on top of SAI's brush cursor

Known, intermittent at launch, [issue #20](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/issues/20).
Cosmetic — drawing is unaffected. Moving the pen usually clears it.

## Something else — collect diagnostics

Turn on **Developer mode** (menu-bar icon, or right-click the Dock icon), then **Copy
diagnostics** and paste it into an issue. It reports versions, paths, what's installed and
which permissions are granted.

For pen problems specifically, launch with the DLL's own log enabled:

```bash
osascript -e 'quit app "SAI Pen Pressure"'; sleep 2; \
  WT_DEBUG=1 "/Applications/SAI Pen Pressure.app/Contents/MacOS/SAIPenPressure"
```

Click **Launch SAI**, reproduce, then copy `~/SAI2-pressure/drive_c/wtlog.txt` — it is
overwritten on each launch. It shows exactly what SAI received.

---

[Home](index.md) · [Install](install.md) · [Troubleshooting](troubleshooting.md) · [How it works](how-it-works.md) · [Engineering notes](notes.md) · [GitHub](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix)
