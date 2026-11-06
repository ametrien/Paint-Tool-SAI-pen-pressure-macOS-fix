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
  pressure without a restart. **SAI ignores both (read from `sai2.exe`, not run).** Static
  disassembly of the SAI2 build in use (5,171,200 bytes): SAI loads WinTab with `GetProcAddress`
  and calls `WTGetW` from one wrapper (`0x14027c980`), which copies `lcOutOrg/Ext` and
  `lcSysOrg/Ext`. That wrapper runs at start-up and on `WT_CTXOVERLAP` (0x7FF4), and only in the
  handler of SAI's own WinTab window, class `sflWintabCtrlWindow` (`0x14027dcd0`, case at
  `0x14027e0ca`). The window SAI gave `WTOpenW` here (`0x20122`, it receives clicks) is its main
  window, class `sflRootWindow` (`0x140245610`). There `WT_CTXUPDATE` only returns,
  `WT_INFOCHANGE` goes to the default handler, and `WT_CTXOVERLAP` only clears a flag. So with
  the current messages, a screen added while SAI is open gets the restart notice, never pressure.
  SAI opens its context on `sflWintabCtrlWindow` only when an option byte (`0x1404726a5`, set
  in its Options) starts a separate WinTab thread; otherwise on its main window, as here. The
  DLL now logs the class at `WTOpenW` and, on a screen change, posts `WT_CTXOVERLAP` only when
  it is `sflWintabCtrlWindow` (not run yet; build `20:38:13`).
  `sai2.ini [PenTablet] AvoidWacomBug = yes` (SAI's own note: "connected sub monitors ... the
  drawing point and the stylus tip obtain a gap") only makes SAI take the area from its own
  `GetSystemMetrics` at that same copy instead of from `lcSys`. It is still copied once, so it
  does not help with a screen added later.
- If the pen goes onto a screen outside SAI's area, the DLL does not post it. SAI then takes the
  pen as a mouse there: right place, no pressure. The status file gets `newscreen=1`, and the app
  turns the menu-bar pen into a warning sign with "Screens changed. Restart SAI for pressure
  there." (also on the Setup tab's bridge row).
- A self-check compares the pen with Wine's cursor while hovering over SAI. If they stay more than
  48 px apart for 20 samples, the DLL follows the cursor and logs it (`mismatch=1`).

**Tests.** The #37 numbers are replayed in `tests/test_wintab_core.c`: 9 of the placement tests
fail when the old mapping is put back. A later edge case (the pen at exactly the right edge counted
as outside) failed its new test and was fixed. The app's notice has its own tests, including that a
status file left behind by a closed SAI never asks for a restart. The full suite
(`tests/run-tests.sh`) passes with the edge fix, and the DLL cross-builds the way CI does, with no
warnings.

**Seen with the fixed build.** "It's better, way better!" with the `dist/` build.

**Not seen yet:** screen left or above; a screen connected while SAI is open (pressure there, or
the restart notice); unplugging while SAI is open.

## "Less precise with another screen" (solved: Wacom mapping)

**What it was (seen).** First reported as "a bit wobbly, a bit less precise". Corrected later: it
is not shaking, the pen just lands less accurately. Nothing changed during the day. It is easy to
draw with the screens mirrored while watching the laptop, and less precise whenever another screen
is in use (extended, or that screen as main). Any second screen, not only the TV.

**Cause (seen in the Wacom settings).** *Mapping* was "Map to all displays" with *Force proportions*
on. The driver then lays the whole desktop over the tablet at one scale, so only a strip across the
middle of the tablet is active (the panel says "Inactive area detected"). With the #37 layout
(1920x1080 next to the laptop, desktop 3432x1121):

| | Tablet area the laptop screen gets | 1 mm of pen moves |
|---|---|---|
| One screen, or mirrored | all of it, 152 x 95 mm | about 9 points |
| Extended, all displays | about 67 x 43 mm, a fifth of it | about 23 points |

So every movement was about 2.5 times coarser, on either screen. A small tablet (Intuos S) makes
this easy to feel. Our code plays no part in it: the helper reads the cursor's position on the
whole desktop, so it follows any Wacom mapping.

**Fix (seen).** *Mapping → Select one display*, the screen being drawn on. After switching: "oh
you were right". To draw on the other screen, use *Display toggle* (it can go on an ExpressKey) or
switch the mapping back.

**Self-check false alarm (logged, fixed on this branch).** In a two-screen session with the fixed
DLL: "pen at (1510,623) but Wine's cursor at (2109,544) for 20 samples; following the cursor". The
pen had hovered from SAI's window on the laptop onto the TV. Wine only learns the cursor's position
over its own windows, so its cursor stayed frozen inside SAI's window and the "cursor is over SAI"
guard still passed. It cleared when the pen came back, 0.7 s before the next stroke, so no stroke
was drawn from the cursor that time. Fix: `wtc_selfcheck_step()` leaves out samples where our
position moved and Wine's cursor did not move at all; real faults (cursor live, or both still)
still count. Tests replay the log and fail when the frozen-cursor test is removed, narrowed to
"cursor did not move", or made to reset the streak. Not yet run in SAI.

**Still predicted, not seen.** With "all displays", the pen covers 2.5 times more pixels per mm. If
Wine's live cursor trails by one frame (17 ms), a hover faster than about 13 cm/s for 0.16 s would
exceed the 48 px tolerance on two screens (about 32 cm/s on one). No such trip is in the logs.

**"A bit slower on the second screen" (logged: not ours).** Same session, 34 strokes on the laptop
and 8 on the TV: the pen gave a median 118 and 131 samples a second, SAI took every packet within
1 ms on both, no gaps, no stroke drawn from the cursor. The difference is after SAI: the laptop runs
at 120 Hz, the TV at 60 Hz. The TV offers 100 and 120 Hz only with a 1080p signal (1920x1080 pixels),
not with the 4K signal macOS sends for "1920x1080 HiDPI". With Wine's Retina mode off SAI is drawn
at 1x anyway, so a 1080p signal should not make SAI itself softer (not tried). The tablet was on the
USB cable in this session and still gave about 120 to 136 a second, like Bluetooth earlier.

What it looks like (seen): SAI's empty brush circle does not keep up with the cursor on the TV. A
second session with the self-check fix (DLL `19:49:27`, 21 strokes, mostly on the TV): no
`SELFCHECK` lines, and SAI took hover packets within 1 ms except twice on the TV (13 and 17 ms,
about one 60 Hz frame); on the laptop never over 1 ms. So the circle's delay comes after SAI has the
point: SAI draws the circle and the TV shows it at 60 Hz, while macOS draws the cursor itself. The
TV also makes the gap bigger: it reports 1598 mm across, so with the pen mapped to it 1 mm of pen
is about 10.5 mm on the TV, against about 2 mm on the laptop. The same delay is a five times wider
gap there, before the slower refresh. Not tried yet: the TV at 120 Hz (1080p signal), mapping the
pen to part of the TV, a larger tablet.

**Checked along the way.** The session first blamed was the laptop screen alone, 3 strokes
(logged). The fix is not involved:
- *Two programs sending pen samples*: `gaps=0` in the DLL log, one sender.
- *Lost pressure levels*: `pmax=4095` (4096 levels).
- *The self-check taking over*: `mismatch=0`, no `SELFCHECK` lines.
- *Screens changing mid-session*: no `SCREENS` lines.
- *A changed helper*: the helper's code is identical to v0.3.6 (only CI config and docs changed
  since the tag), and the DLL was built with the same compiler flags as CI.
- *Different positions*: on one screen the DLL gives SAI exactly what v0.3.6 gave, at every 1/8 px
  and at 8 scalings including 1352x878, and SAI's 1/8 px area gets the helper's value unrounded
  (unit-tested; both checks fail when a whole-pixel rounding is put back).
- *The new code slowing samples down*: measured with `tools/multimon/wtbench.c` under Wine 11.16.
  The self-check costs about 30 µs per hover sample (max about 170 µs, one 3.4 ms outlier in 6000
  calls, when the cursor had been still), the screen check 3 µs once a second. A Bluetooth sample
  arrives every 7,700 µs. Neither check runs while the pen is down, so strokes are not affected.
  SAI read every posted packet at once (`lat=0ms`).

**Side notes, not the cause.**
- *Laptop scaling* is "looks like" 1352x878, not the default 1512x982 (an exact 2x). With Wine's
  Retina mode off, SAI goes through a 1.118 scaling, so thin lines and the brush circle look a
  little softer. It does not change where the pen lands.
- *Sample rate* was about 120 to 136 a second over Bluetooth and, in a later session, over the USB
  cable too (logged). The docs say USB gives about 200; that was not seen here and is not checked.
  Fast curves are made of short straight pieces; with "all displays" each was 2.5 times longer.

## Workaround for v0.3.6

1. Connect and arrange the screens first, then start SAI.
2. After any display change, save, quit SAI and start it again. Wake SAI is not enough.
3. Keep the main display (the one with the menu bar) top-left in *Displays → Arrange*: other
   screens to its right or below, with their top edge not above its top edge. A screen to the left
   or above may shift strokes even after a restart (predicted, see above).
4. For precision with more than one screen: Wacom *Mapping → Select one display*, and *Display
   toggle* to move between screens. "Map to all displays" makes the pen about 2.5 times coarser
   (see above). This holds for the fixed version too.

## Where things are

- Branch `fix/37-extended-displays`, pushed to GitHub, no PR yet, so CI has not run on it (it runs
  on `main` and on PRs). `main` is untouched at `11095ae`.
- `tools/multimon/`: fake display, fake pen, layout harness, and `wtbench.c`. The harness opens
  SAI and changes the screen layout, so only run it when that is fine.
- `/Applications/SAI Pen Pressure.app` is untouched (v0.3.6). The fixed build is
  `dist/SAI Pen Pressure.app`, rebuilt with the edge fix and the self-check fix; its DLL log
  starts with `built Nov  6 2026 19:49:27`. `make-app.sh` copies the committed
  `wintab-src/wintab32.dll`, it does not compile it, so rebuild the DLL first after a source change. Whichever app last pressed Launch has its DLL in the SAI prefix.
