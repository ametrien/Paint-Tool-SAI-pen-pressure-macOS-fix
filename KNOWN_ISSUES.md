# Known issues

An honest list of the bugs we know about — the symptom, the underlying cause, **what we
tried, and what didn't work** — so nobody re-treads the dead ends.

Both issues below are caused by layers **beneath** this project (SAI itself, and Wine's
macOS driver). They are not defects in the pressure bridge, and there is no bridge-side fix
for either without breaking something more important (drawing). Contributions that prove
otherwise are very welcome.

---

## 1. Pen taps don't work on SAI's top menu row ("File", "Edit", …)

**Symptom.** While the pen is in range, tapping SAI's **top menu bar** does nothing. The
canvas, tool panels, brush list and sliders all respond to the pen normally. The
mouse/trackpad clicks the menu fine.

**Cause.** SAI de-duplicates pen-vs-mouse input. When our WinTab stream tells SAI a pen is
present, SAI discards the pen's *synthesized mouse click* on the menu (it expects the "real"
input to arrive as a WinTab packet instead). SAI's menu bar is driven by mouse clicks, not
WinTab packets — so the click is dropped. The canvas and panels are driven by the WinTab
packets themselves, so they're unaffected. With the bridge **off**, the pen is an ordinary
mouse and the menu works — which confirms our stream is the trigger.

**What we tried**

- **Advertised the context as `CXO_SYSTEM` (0x0001) alongside `CXO_MESSAGES`**, exactly like
  a real Wacom driver (it declares the system cursor is integrated with the pen). Result: SAI
  *does* accept the mouse click on the menu — but it then processes **both** the mouse click
  **and** our `buttons=1` WinTab packet, so menus **open and instantly close** (a double
  click). Real Windows drivers avoid this because Windows tags pen-synthesized mouse events
  with a signature (`GetMessageExtraInfo` == `0xFF515700`) so apps can recognise and drop the
  duplicate; Wine's `winemac.drv` mouse events carry no such tag, so SAI can't tell the two
  events are the same tap. **Reverted** — the double-click is worse than the dead menu.
- Confirmed it's **not** our refactor: the behaviour is identical with the pre-refactor DLL.

**Not yet explored (help welcome)**

- Whether the trigger is specifically the **continuous hover stream** (vs. the tap's own
  packets). The helper has a diagnostic flag for exactly this: run it with **`WT_NO_HOVER=1`**
  (streams only presses — no hover/keepalive) and see whether menu taps start working:
  ```bash
  WT_NO_HOVER=1 WT_PRESSURE_FILE="$HOME/SAI2-pressure/drive_c/wt_pressure.txt" \
    ./wacom-helper/wacom-pressure-helper &
  bash launch-sai2-pressure.sh
  ```
  - If the menu **works** in this mode → the hover stream is the trigger, and a targeted fix
    becomes possible: keep hover streaming everywhere **except** when the pen is over SAI's
    menu strip (the helper can read SAI's window rect and suppress hover there). The cost is
    slightly laggier hover near the top of the window.
  - If the menu **still fails** → the tap's own packets trigger it, and there is no
    bridge-side fix.
- Injecting the Windows pen signature into the mouse event's ExtraInfo would fix it globally,
  but that's a change in **Wine** (`winemac.drv`), not in this project.

**Workaround.** Use the mouse/trackpad for the top menu. Everything else takes the pen.

---

## 2. SAI stops responding to input after switching apps

**Symptom.** After switching to another macOS app and back, SAI's window *looks* focused but
ignores all clicks and keys.

**Cause.** A known **`winemac.drv`** (Wine's macOS driver) bug: on an app switch Wine can fail
to restore the window's **Win32 foreground/active** state even though macOS shows SAI as the
active app. SAI's own `WM_MOUSEACTIVATE` handler then eats every canvas click
(`MA_NOACTIVATEANDEAT`), and the Wacom driver demotes the pen to a plain mouse — canvas dead
to both, menu row still alive. Unrelated to the pressure bridge. (Full investigation:
[issue #2](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/issues/2).)

**Fix (shipped).** Our `wintab32.dll` lives *inside* SAI's process, so on a wake request it
runs a repair routine **on SAI's own UI thread** (marshalled via a thread-scoped
`WH_GETMESSAGE` hook). Three layers were broken, and the wake repairs all of them:

1. **Wineserver foreground** — sometimes parked on the desktop window, and Wine's
   foreground lock refuses `SetForegroundWindow` from a non-foreground process
   (`ERROR_ACCESS_DENIED`). The wake attaches to the foreground owner's input state
   (`AttachThreadInput`) and retries.
2. **The Cocoa key window** — `winemac.drv` only informs macOS on a focus *change*, so
   the wake toggles focus through `NULL` to force the driver call.
3. **SAI's internal "am I active" flag** — the decisive one. SAI only updates it from
   `WM_ACTIVATE`/`WM_ACTIVATEAPP` *messages*; Wine restores activation without a state
   change, so no message is ever generated and SAI keeps eating canvas clicks even with
   every system-side state correct. The wake synthesizes the activation message sequence
   directly into SAI's window proc.

The helper requests this wake automatically when you return to SAI or click a dead canvas
(and again ~0.6 s after the transition settles, so a wake always runs while SAI is properly
active); `⌃⌥⌘Space`, the 🖊 menu-bar item, or the setup-window button trigger it manually.
Every attempt is logged to `C:\wt_wakelog.txt` (helper side: `/tmp/sai-wake.log`). Opt out
with `WT_NO_WIN32_WAKE=1`.

**What we tried / researched**

- **No registry switch fixes it.** We went through the full list of Mac-driver options in
  Wine's source (`dlls/winemac.drv/macdrv_main.c`) — window float, fullscreen capture, cursor
  clipping, Retina, etc. None touch activation / input-queue reattachment. Forum-cited keys
  like `UseTakeFocus` / `GrabFullscreen` are **X11-only** and ignored by the Mac driver.
- **"Update Wine":** already on the newest Gcenx build (**wine-11.10 Staging**). Later
  mainline Wine reworked focus handling; a future Gcenx build may include the fix.
- **macOS-side activation bounces / cross-thread `SetForegroundWindow`** — helped some paths,
  never reliable; the thread-local calls must run on SAI's UI thread (see issue #2).

**Fallback.** If a wake ever fails: `⌃⌥⌘Space`, or switch to a **different Space and back**,
or Cmd-Tab away and click SAI's window body.

*Sources: [Wine winemac.drv source](https://github.com/wine-mirror/wine/blob/master/dlls/winemac.drv/macdrv_main.c),
[winemac input-loss report](https://github.com/Sikarugir-App/Sikarugir/issues/237).*

---

## Non-bugs (expected — please don't report these)

- **Boxy fast curves over Bluetooth** (~130 Hz report rate) — use a USB data cable (~200 Hz).
- **Low pressure feels non-linear / jumpy** in the raw "Test Tablet Pressure" bar — that's the
  tablet's physical activation-force region; SAI applies its own pressure curve when drawing,
  so strokes feel smooth.
