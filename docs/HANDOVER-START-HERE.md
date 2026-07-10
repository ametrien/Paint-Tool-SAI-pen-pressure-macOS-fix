# SAI on macOS — MASTER HANDOVER (start a fresh chat with this)

**Updated 2026-07-09 (late). PEN PRESSURE WORKS, saving is licensed.** Current source of
truth. Older docs (`TECHNICAL_WRITEUP.md`, `JOURNEY.md`, `HANDOFF-pen-pressure*.md`) are
historical context only.

User is a **React/.NET engineer, not a Wine/C/systems person** — explain plainly and drive
the work yourself. **NEVER test GUI/hardware behavior yourself (no synthetic clicks/strokes/
pressure injections as "tests") — the user does all interactive testing and reports back.**

---

## 0. STATUS — where things are RIGHT NOW

- ✅ **SAI Ver.2 (64-bit) runs** on standalone Wine 11.10 Staging (Gcenx build).
- ✅ **REAL WACOM PEN PRESSURE WORKS** end to end — pressure-varying strokes with the real pen.
- ✅ **Mouse/trackpad painting still works** alongside the tablet (we only speak WinTab for
  tablet-sourced events).
- ✅ **Saving works** — the paid SAI license is installed (see §6). SAI Ver.2 preview lets you
  draw but blocks *saving* until it finds the `.slc` cert in its program folder at startup.
- ✅ **Skew fixed** (screen-aspect output extent) + user set Wacom mapping to full screen.
- ✅ **Lag fixed** via packet conflation — needs a final user confirm but built & installed.
- 🟡 **Multi-monitor**: NOT supported yet (single-screen assumption → double cursor on a 2nd
  display). User wants it; implementation was drafted then reverted. See §5.
- 🟡 **Minor open items**: intermittent right-click (maybe pen barrel button), Wine window
  grey-out on hide/reopen (Wine-level, happens with mouse too). See §5.

## 1. THE WORKING ARCHITECTURE (current)

```
 Wacom pen (CTL-4100WL "Intuos BT S") — Bluetooth OR USB, Wacom driver installed
      │  macOS events. We use a CGEventTap (.cghidEventTap, listenOnly) — far less
      │  coalesced than an NSEvent global monitor, so fast samples aren't dropped.
      │  Only TABLET-sourced events are used (mouse subtype == tabletPoint, plus
      │  tabletPointer/Proximity); real mouse events are ignored so SAI's own mouse
      │  painting keeps working. Needs Accessibility + Input Monitoring on the terminal.
      ▼
 wacom-helper/wacom-pressure-helper   (Swift; source wacom-helper/main.swift)
      │  reads tabletEventPointPressure (→0..1023) + CGEvent.location; sends one UDP
      │  datagram per sample "seq press x y w h" to 127.0.0.1:47800 (lossless on
      │  loopback — proven gaps=0). Also writes the file as fallback + kill switch.
      ▼
 our custom wintab32.dll   (C; source wintab-src/wintab32.c, +wintab32.def/.rc)
      │  producer thread blocks on the UDP socket, posts each sample immediately.
      │  CONFLATION: only PostMessage(WT_PACKET) when SAI has < POST_WINDOW(2)
      │  unfetched packets (transitions always post); intermediate samples collapse
      │  into the freshest so the drawn point never trails behind a backlog.
      │  Streams continuously like a real driver (hover = buttons0/press0 + position,
      │  contact = buttons1 + pressure) so SAI's brush cursor tracks the pen.
      ▼
 SAI2.exe → pressure strokes   (WinTab context, pktData 0x15e2, out extent = screen*8)
```

Facts proven along the way — **do NOT re-litigate**:
- SAI resolves the **entire WinTab API via GetProcAddress at startup**, dies with "Windows
  function call failed" if ANY export is missing → we export all 29 (A+W + manager stubs).
- **Position must come from the tablet's own event coords, NOT `GetCursorPos`** — using the
  Wine cursor created a feedback loop (SAI moves cursor from our packet → we read it back →
  runaway drift, two cursors). Reverted; never reintroduce.
- Output extent must carry the **screen aspect** (`lcOutExt = screenW*8 × screenH*8`); a
  square 32767² stretched drawings horizontally.
- Continuous hover streaming is needed for cursor tracking, BUT must be gated to tablet
  events only, and the file fallback must be **edge-triggered** — otherwise a static pen-up
  value keeps telling SAI "a pen is here" and blocks mouse painting.
- UDP on loopback is lossless at our rate (drain empties the socket); the felt lag was a
  message backlog, fixed by conflation, not a transport problem.

## 2. HOW TO RUN

**Easiest — one click:** double-click **`Start SAI2 with pen pressure.command`** in Finder.
It opens in Terminal (inheriting Terminal's Accessibility + Input Monitoring), starts the
helper in the background, launches SAI, and stops the helper when SAI closes.

**Manual (two terminals):**
```bash
# Terminal.app (NOT inside Claude Code — needs its Accessibility + Input Monitoring grants):
~/Documents/wineORwhiskyFORSAI/wacom-helper/wacom-pressure-helper   # prints captured=N pressure=P

# any terminal:
bash ~/Documents/wineORwhiskyFORSAI/launch-sai2-pressure.sh
```
In SAI: Options → Pen Tablet → **"Use WinTab API"** (already saved in this prefix), draw on a
raster layer. Kill switch: `echo 0 > ~/SAI2-pressure/drive_c/wt_pressure.txt` and/or quit SAI.

**Rebuild after changing source:**
```bash
cd ~/Documents/wineORwhiskyFORSAI/wintab-src
x86_64-w64-mingw32-gcc -shared -O2 -o wintab32.dll wintab32.c wintab32_res.o wintab32.def \
    -lgdi32 -luser32 -lws2_32 -municode
cp wintab32.dll ~/SAI2-pressure/drive_c/windows/system32/wintab32.dll   # then RESTART SAI

cd ~/Documents/wineORwhiskyFORSAI/wacom-helper
swiftc -O -o wacom-pressure-helper main.swift                          # then RESTART helper
```
(`-lws2_32` is required now — the DLL uses winsock.)

## 3. DIAGNOSTICS (wtlog.txt = ~/SAI2-pressure/drive_c/wtlog.txt)

- `producer: ... posted=N recv=N gaps=N fetched=N` heartbeat every 2 s. gaps=0 = no UDP loss.
- `BACKLOG posted_serial=.. fetched=.. gap=N` during a stroke — gap should stay small (≤~2)
  now that conflation is in; a big/growing gap would mean lag returned.
- `WTPacket #N ...` sampled fetches (every 64th) = SAI is consuming.
- `PEN DOWN/UP buttons=.. press=..` at each tip transition — for the stray-click investigation
  (we only ever emit buttons 0/1, so a right-click is likely the pen barrel button or Wine).
- Helper console/`helper.log`: `captured=N pressure=P` proves the Mac capture side alone.

## 4. TUNING KNOBS

- `POST_WINDOW` (wintab32.c, currently 2): max unfetched packets before conflation. Lower =
  tighter cursor tracking (less lag) but fewer intermediate points; raise if strokes look
  choppy, lower toward 1 if the point still trails.
- Helper 8× fixed-point on x/y/w/h preserves sub-pixel position through the integer protocol.

## 5. OPEN ITEMS / NEXT

- **Multi-monitor (user wants this):** single-screen assumption causes a double cursor on a
  2nd display. Plan: helper reports position within the FULL virtual desktop (CGDisplay union
  via `CGGetActiveDisplayList`/`CGDisplayBounds`, top-left global space) with a display-
  reconfiguration callback to refresh; DLL uses `SM_CXVIRTUALSCREEN/SM_CYVIRTUALSCREEN` for
  the context out/sys extents. Watch for virtual-origin offsets (a monitor left/above primary
  gives negative origins) and aspect across the combined space. Add read-only DBG (helper
  coords vs GetCursorPos, no feedback) to verify alignment, then test on the real layout.
- **Right-click glitch:** capture a repro with the PEN DOWN/UP log; if we only ever send
  buttons 0/1, it's the pen's barrel button or Wine's button mapping, not our code.
- **Window grey-out / can't move-resize:** Wine-level (happens with mouse too). Options: live
  with click-to-focus, or run SAI in a Wine virtual desktop (risks disturbing pen positioning
  — test carefully).
- **Cleanup:** gate wtlog logging behind an env var once quality is locked; delete the dead
  Whisky bottle + `bottle-root-junk-quarantine/`; `wintab32_res.o` is a build artifact.
- **TCP transport:** optional; UDP proven lossless, so low priority.

## 6. LICENSE (paid — handle carefully)

- The `.slc` certificate lives at `~/SAI2-pressure/drive_c/SAI2/sai-*.slc` (next to the
  `sai2.exe` that actually runs). SAI reads it **only at startup** → after placing it, restart
  SAI. It is a 128-byte binary cert. **Do NOT commit it to git** (personal/paid; it lives
  outside the repo, keep it that way). Back it up somewhere safe.
- If saving ever breaks again: confirm the `.slc` is in the folder of the sai2.exe you launch
  (there are several sai2.exe copies around) and restart SAI.

## 7. KEY PATHS

```bash
WINE="/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine"   # Gcenx 11.10 Staging
PRESSURE_PREFIX="$HOME/SAI2-pressure"    # daily driver: clone of SAI2-clean + our DLL + license
CLEAN_PREFIX="$HOME/SAI2-clean"          # pristine fallback, no pressure/DLL/license
SAI2="<prefix>/drive_c/SAI2/sai2.exe"    # known-good md5 6f3f351303cf3896f4c2977925c994c2
DLL   = wintab-src/{wintab32.c,.def,.rc,wintab32.dll}   # UDP port 47800, out ext = screen*8
HELPER= wacom-helper/{main.swift,wacom-pressure-helper} # CGEventTap; run from Terminal.app
LAUNCH= "Start SAI2 with pen pressure.command" (one-click) | launch-sai2-pressure.sh (manual)
```
Machine: Apple M3 Pro, arm64. Tablet: Wacom CTL-4100WL, Bluetooth or USB. Whisky is dead —
never try to re-download its libraries.

## 8. History pointers (only if needed)

- `TECHNICAL_WRITEUP.md` — original ACL wineserver patch saga + abandoned winemac.drv rebuild.
- `JOURNEY.md`, `HANDOFF-pen-pressure.md` — old in-Wine tablet driver attempt (superseded).
