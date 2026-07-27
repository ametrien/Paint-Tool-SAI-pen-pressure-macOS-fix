---
title: Install
---

[← back](index.md)

About 15 minutes, most of it downloading.

## 1. Your tablet's driver

Install your tablet manufacturer's macOS driver and confirm the pen moves the cursor in any
app before going further. Nothing here can work if macOS itself doesn't see the pen.

## 2. PaintTool SAI Ver.2

From [systemax.jp](https://www.systemax.jp/en/sai/devdept.html). Unzip it; the folder contains
`sai2.exe`. Two builds are offered:

- **2026-07-12 Technical Preview Major Renovated** — newest, and it has a **dark theme**
  (*Window → Window Color → Dark Colors*). Reads the licence from a `settings` folder.
- **Technical Preview Stable Version** — older, reads the licence next to `sai2.exe`.

Either works. The app handles the licence difference for you.

## 3. The app

Download `SAI-Pen-Pressure-….zip` from the
[latest release](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/releases/latest),
unzip, and **move it to /Applications** before granting permissions — the grant is matched by
path.

First launch: **right-click → Open** (the one-time unsigned-developer bypass).

## 4. Wine, and your SAI folder

The setup window installs Wine for you if it's missing, with a progress bar. Then point it at
your SAI folder from step 2 — it usually finds it for you.

## Input Monitoring

This is the only permission needed, and it's the fiddly step.

**macOS will not show a prompt.** Released builds are ad-hoc signed — proper signing needs a
paid Apple Developer Program membership this project doesn't have — and macOS only prompts for
apps with a stable signing identity. So add it manually, once:

1. Click **Grant…** in the setup window. It opens the right pane, reveals the app in Finder, and
   copies its path to your clipboard.
2. In **System Settings → Privacy & Security → Input Monitoring**, click **+**.
3. Press **⇧⌘G**, paste (**⌘V**), choose the app, and switch it **on**.
4. **Quit and reopen the app** — macOS only applies a grant on a fresh launch.

*Building from source on a Mac with an Apple Development certificate avoids all of this:
`make-app.sh` signs automatically and macOS then prompts normally.*

## 5. Turn on WinTab in SAI

*Others → Options → Pen Tablet →* **Use WinTab API**, then relaunch SAI. Without this SAI
ignores the pressure entirely.

## 6. Your licence

You can draw and test pressure without one — it's needed only to **save**.

Buy from SYSTEMAX, get your **System ID** from *Others → System ID*, download the `.slc` from
[the licence page](https://www.systemax.jp/en/license.html), then use **Install…** on the
*SAI license* row. It's copied into every folder SAI might read it from.

*This project cannot supply, generate or activate a licence.*

---

Trouble? → [Troubleshooting](troubleshooting.md)
