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

**This also means you must re-grant it after upgrading.** Ad-hoc signing gives every build its
own identity, so macOS sees a new app and silently drops the old permission — without re-showing
the prompt. If pressure stops working right after you install a new version, this is the first
thing to check, before suspecting the release.

*Building from source on a Mac with an Apple Development certificate avoids all of this:
`make-app.sh` signs automatically, the identity stays stable across rebuilds, and macOS then
prompts normally.*

## 5. Turn on WinTab in SAI

*Others → Options → Pen Tablet →* **Use WinTab API**, then relaunch SAI. Without this SAI
ignores the pressure entirely.

## 6. Your licence

You can draw and test pressure without one — it's needed only to **save**.

Buy from SYSTEMAX, get your **System ID** from *Others → System ID*, download the `.slc` from
[the licence page](https://www.systemax.jp/en/license.html), then use **Install…** on the
*SAI license* row. It's copied into every folder SAI might read it from, and kept so rebuilding
the Wine prefix can restore it.

If the `.slc` is already sitting in your SAI folder, you don't need to do anything: since
**v0.1.12** it's picked up automatically — when you choose the folder, and again on every install
or reinstall — and the *SAI license* row will say so.

*This project cannot supply, generate or activate a licence.*

---

Trouble? → [Troubleshooting](troubleshooting.md)

---

[Home](index.md) · [Install](install.md) · [Troubleshooting](troubleshooting.md) · [How it works](how-it-works.md) · [Engineering notes](notes.md) · [GitHub](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix)

---

## Manual install, from the command line

The app does all of this for you. This route exists for people who would rather see the
steps, or who are working on the project itself.


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

4. **Grant permission.** System Settings → **Privacy & Security** → grant your terminal app
   (Terminal / iTerm) **Input Monitoring**, then fully quit and reopen the terminal. (That's the
   only permission needed; the helper captures nothing without it. Cmd→Ctrl shortcuts are handled
   by Wine, so no Accessibility permission is required.)

5. **Add your license** (to be able to save): drop your `sai-*.slc` file into the prefix's SAI
   folder — the installer prints the exact path — and restart SAI. SAI reads the license only
   at startup.

6. **Turn on WinTab in SAI:** Others → Options → **Pen Tablet** → **Use WinTab API**, then
   restart SAI.

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
