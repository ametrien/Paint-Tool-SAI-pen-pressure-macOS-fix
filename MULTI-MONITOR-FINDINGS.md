# Multiple monitors (#37): what we know

Written 2026-11-06, on branch `fix/37-extended-displays`. Nothing here is on `main`.
Each point says whether it was **seen** (a person drew and looked), **logged** (in the DLL log or
status file), **unit-tested**, or only **predicted** (worked out, not yet seen).

Test machine: MacBook Pro M3 Pro, macOS 26, Wine 11.16 Staging (Retina mode off), SAI2 64-bit,
Wacom Intuos BT S over Bluetooth, LG TV (3840x2160, used as 1920x1080) as the second screen.

## The bug

**Symptom (seen).** With the TV set to *Extended*, ink landed about a fifth of the screen to the
left and a little high, the laptop screen could not be drawn on at all, and Wake SAI did not help.
With the screens mirrored, everything worked.

**Cause (logged).** The DLL measured the desktop once, when SAI started. The app's helper measures
it again on every display change and sends the pen as a position inside the whole desktop. In the
failing session SAI had started while the screens were mirrored: the DLL still said
`virtual 1920x1080` while macOS had 3432x1121 (TV plus laptop). The helper's positions were
squeezed into the old area:

- TV centre (x 960) arrived at x 960 × 1920 / 3432 ≈ 537, 22 % to the left. Seen: "a fifth or a
  quarter to the left".
- Up to about 4 % too high, more towards the bottom. Seen: "maybe 1/25 higher".
- The whole laptop screen fell inside the right half of the TV's area, so it was unreachable.

**Why it seemed random (seen + logged).** It depends only on whether the screens changed after SAI
started. A fresh launch with the screens already extended logged `virtual 3432x1121` and drew
correctly on the TV. The laptop screen in that session was not checked.

Anything that changes the desktop while SAI is open triggers it: connecting or unplugging a
screen, switching between mirrored and extended, rearranging, or changing a screen's resolution.
The laptop's own scaling changed during today's testing (1512x982 to 1352x878), which alone is
enough.

**Second problem (predicted, shown with the test kit).** With a screen to the left of or above
the main one, the desktop starts at a negative position, but v0.3.6 tells SAI its tablet area
starts at 0,0. With a fake 1920x1080 screen on the left, the v0.3.6 DLL sent every point on the
main screen 1920 px to the right (0 of 6 points right); the fixed DLL got 6 of 6. This checks what
the DLL tells SAI, assuming SAI reads its area from the context it opened (`lcSysOrg`), which is
what a real Wacom driver relies on. Nobody has drawn in that layout yet.

## The fix (on this branch)

- The DLL turns the helper's position into a real screen point using the desktop as Wine reports
  it *now*, then places it inside the area SAI opened with (`wtc_place`). On one screen this is
  exactly the old mapping, edges included (unit-tested on a grid).
- It re-reads the screens about once a second and tells SAI where the desktop really starts.
- When the screens change it sends SAI the standard WinTab messages (`WT_INFOCHANGE`,
  `WT_CTXUPDATE`). If SAI then re-reads its context, the new area is used and every screen keeps
  pressure without a restart. SAI does call `WTGetW` on its own (logged), but whether it does so
  after a screen change is **not known yet**: the log line `SAI re-read its context` will say.
- If the pen goes onto a screen outside SAI's area, the DLL does not post it. SAI then takes the
  pen as a mouse there: right place, no pressure. The status file gets `newscreen=1`, and the app
  turns the menu-bar pen into a warning sign with "Screens changed. Restart SAI for pressure
  there." (also on the Setup tab's bridge row).
- A self-check compares the pen with Wine's cursor while hovering over SAI. If they stay more than
  48 px apart for 20 samples, the DLL follows the cursor and logs it (`mismatch=1`).

**Tests.** The #37 numbers are replayed in `tests/test_wintab_core.c`: 9 of the placement tests
fail when the old mapping is put back. A later edge case (the pen at exactly the right edge counted
as outside) failed its new test and was fixed. The app's notice has its own tests, including that a
status file left behind by a closed SAI never asks for a restart. The full suite passed before the
edge fix; after it, the C core tests pass.

**Seen with the fixed build.** "It's better, way better!" with the `dist/` build.

**Not seen yet:** screen left or above; a screen connected while SAI is open (pressure there, or
the restart notice); unplugging while SAI is open.

## "Feels a bit wobbly, a bit less precise"

The session that felt this way was the laptop screen alone, 3 strokes (logged).

**Ruled out:**
- *Two programs sending pen samples*: `gaps=0` in the DLL log, one sender.
- *Lost pressure levels*: `pmax=4095` (4096 levels).
- *The self-check taking over*: `mismatch=0`, no `SELFCHECK` lines.
- *Screens changing mid-session*: no `SCREENS` lines.
- *A changed helper*: the helper's code is identical to v0.3.6 (only CI config and docs changed
  since the tag), and the DLL was built with the same compiler flags as CI.
- *Different positions*: on one screen the DLL gives SAI exactly what v0.3.6 gave (unit-tested).
- *The new code slowing samples down*: measured with `tools/multimon/wtbench.c` under Wine 11.16.
  The self-check costs about 30 µs per hover sample (max about 170 µs, one 3.4 ms outlier in 6000
  calls, when the cursor had been still), the screen check 3 µs once a second. A Bluetooth sample
  arrives every 7,700 µs. Neither check runs while the pen is down, so strokes are not affected.
  SAI read every posted packet at once (`lat=0ms`).

**Different from this morning, effect not tested:**
- *Laptop scaling.* Now "looks like" 1352x878: macOS draws 2704x1756 and scales it onto the
  3024x1964 panel by 1.118. The default, and this morning's setting, is 1512x982, an exact 2x.
  With Wine's Retina mode off, SAI is drawn at 1x and goes through that non-integer scaling, so
  thin lines and the brush circle come out softer.
- *Tablet mapping.* The Wacom driver maps the Intuos BT S to the whole desktop (`Desktop_0_` in 36
  of its 48 mapping entries). With the TV extended, the tablet covers both screens (3432x1121), so
  each screen gets only part of the tablet, and control there is coarser. No effect with one screen.
- *Bluetooth.* About 120 to 130 samples a second in both of today's sessions, so not new. Over USB
  it is about 200. The README already notes Bluetooth makes fast curves boxier.

**Still to check (needs a person):**
1. Draw at the default 1512x982 scaling and compare.
2. Side by side: the app in `/Applications` (v0.3.6 DLL) against the one in `dist/` (fixed DLL),
   same canvas and zoom. Each Launch installs its own DLL; `syncBridgeDLL` replaces it whenever the
   two differ, in either direction.
3. SAI's canvas zoom and the tool's stabilizer, compared with usual.
4. If it was on the TV: the LG input set to PC or Game mode (less processing and lag), and the
   Wacom mapping set to one screen.
5. Whether the *path* wobbles or the *line width*. Width would point at pressure instead.

Note: the `dist/` app was built before the edge fix, so it does not have it.

## Workaround for v0.3.6

1. Connect and arrange the screens first, then start SAI.
2. After any display change, save, quit SAI and start it again. Wake SAI is not enough.
3. Keep the main display (the one with the menu bar) top-left in *Displays → Arrange*: other
   screens to its right or below, with their top edge not above its top edge. A screen to the left
   or above may shift strokes even after a restart (predicted, see above).
4. Optional: map the pen to one screen in the Wacom settings.

## Where things are

- Branch `fix/37-extended-displays`, local only, not pushed. `main` is untouched at `11095ae`.
- `tools/multimon/`: fake display, fake pen, layout harness, and `wtbench.c`. The harness opens
  SAI and changes the screen layout, so only run it when that is fine.
- The SAI prefix has the shipped v0.3.6 DLL again. `/Applications/SAI Pen Pressure.app` is
  untouched; the fixed build is `dist/SAI Pen Pressure.app`.
