# Multi-monitor test kit (issue #37)

Checks where the pen lands with any screen layout, with no second monitor and no tablet.

| File | What it does |
|---|---|
| `vdisplay.m` | Adds a fake 1920x1080 screen left, right, above or below the main one (`CGVirtualDisplay`). Gone when the process ends. |
| `inject.py` | Plays the helper: sends pen samples to the DLL over UDP, computed exactly as `wacom-helper` does. `--hover` never clicks. |
| `harness.py` | Puts it together: fake screen, SAI started without the helper, hover on every screen, then checks the DLL log (`WT_LOG_POS`) against where each point really is. |
| `strokefind.m` | Screenshot diff of where ink appeared. Needs Screen Recording permission for whatever runs it. |

Build the two Objective-C tools first:

```bash
clang -fobjc-arc -framework Foundation -framework CoreGraphics vdisplay.m -o vdisplay
clang -fobjc-arc -framework Foundation -framework CoreGraphics -framework ImageIO strokefind.m -o strokefind
```

Then, with the DLL under test in the prefix's `system32` and the SAI Pen Pressure app **quit**:

```bash
python3 harness.py left
```

Cases: `left`, `right`, `above`, `below`, `hotplug-right` (screen added while SAI runs, the #37
report) and `unplug`.

**It opens SAI and changes the screen layout while it runs.** Only run it when that's fine.
It never moves the cursor or clicks: samples are hover only, pressure 0.

What it checks is what the DLL hands SAI, not SAI's own reaction to it. Whether SAI picks up a
new layout without a restart shows up in the log (`SAI re-read its context`); whether the ink
then appears under the pen still needs a real look.

Recorded results (2026-11-06, MacBook Pro M3 Pro, SAI2 64-bit):
- `left` with the v0.3.6 DLL: 0/6. Taps on the main screen were sent 1920 px to the right.
- `left` with the fixed DLL: 6/6.
