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

**Cause.** A known **`winemac.drv`** (Wine's macOS driver) bug: on re-activation the window
regains focus visually but Wine never re-attaches the window's input queue. Unrelated to the
pressure bridge.

**What we tried / researched**

- **No registry switch fixes it.** We went through the full list of Mac-driver options in
  Wine's source (`dlls/winemac.drv/macdrv_main.c`) — window float, fullscreen capture, cursor
  clipping, Retina, etc. None touch activation / input-queue reattachment. Forum-cited keys
  like `UseTakeFocus` / `GrabFullscreen` are **X11-only** and ignored by the Mac driver.
- **"Update Wine":** already on the newest Gcenx build (**wine-11.10 Staging**). Later
  mainline Wine reworked focus handling; a future Gcenx build may include the fix.

**Fix (one key).** Press **⌃⌥Space** (Control-Option-Space) — or click the **🖊 menu-bar icon →
*Wake SAI window*** (also a button in the setup window). This forces a full re-activation of
SAI's window and it takes input again immediately. No permission needed.

How it works: the helper finds the exact process that owns SAI's on-screen window (via
`CGWindowList` — Wine runs as several processes, and only one owns the visible window) and
hides + re-activates it, which is the programmatic equivalent of the manual Space-swipe. The
earlier naive attempt (activating "a" Wine process, or the whole app) did nothing because it
poked the wrong process. Returning via **Cmd-Tab** also auto-wakes it (the helper re-activates
Wine when it comes to the foreground).

**Manual fallback.** Switch to a different Space and back (three-finger swipe left/right).

*Sources: [Wine winemac.drv source](https://github.com/wine-mirror/wine/blob/master/dlls/winemac.drv/macdrv_main.c),
[winemac input-loss report](https://github.com/Sikarugir-App/Sikarugir/issues/237).*

---

## Non-bugs (expected — please don't report these)

- **Boxy fast curves over Bluetooth** (~130 Hz report rate) — use a USB data cable (~200 Hz).
- **Low pressure feels non-linear / jumpy** in the raw "Test Tablet Pressure" bar — that's the
  tablet's physical activation-force region; SAI applies its own pressure curve when drawing,
  so strokes feel smooth.
