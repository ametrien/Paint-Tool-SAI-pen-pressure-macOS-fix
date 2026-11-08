# Why drawing lags with "Sharp text on Retina screens" (issue #39)

Investigated 2026-11-07 on Anastasia's MacBook Pro (M3 Pro, built-in Liquid Retina XDR display,
"looks like" 1352x878), macOS 26.6.2, Wine Staging 11.16 (Gcenx), SAI Ver.2 Alpha 2026.07.27.

## Short version

**Problem:** with "Sharp text on Retina screens" on (Wine's RetinaMode), strokes appear late while
drawing, worse on bigger screens (the reporter's LG at 4096x2304 more than a built-in display), and
an idle SAI uses about 55% of a core instead of about 15%.

**Cause:** the time goes into macOS re-drawing SAI's window picture on the processor, converting the
colour of every pixel, every time the window changes. Wine 11.16's Mac driver hands macOS a new
`CGImage` of the whole window on every update, even for one brush dab. That work grows with the
number of pixels, so Retina mode (4x the pixels) makes it about 4x heavier, and Rosetta (Wine is
Intel code) slows it further. It is how Wine hands window contents to macOS, not SAI's own drawing
and not our code.

**Solution:** Wine changed exactly this on 2026-11-05 (commit `b77a5f9b60`, "winemac: Use IOSurface
to update native window layers instead of CGImage", by Marc-Aurel Zent, based on a patch by Brendan
Shanks). It is not in Wine 11.21 and should arrive in 11.22. Backported to 11.16 by hand (only
`winemac.so` rebuilt), it took idle SAI from ~55% to ~9% of a core and the main thread while drawing
from ~68% to ~6% (see "Backported fix tested" below). Not yet tested with pen pressure through the
app, and not yet tested with an official Wine 11.22.

## What was measured (facts)

### 1. spindump while drawing (Retina on, recording on, launched from the test app)

`sudo spindump <sai pid> 10 10`: 1001 samples of SAI's process over 10 s of continuous drawing.

- Main thread (`com.apple.main-thread`): **6.8 s of CPU in 10 s** (about 68% of a core).
  Every other thread together: under 1 s. SAI's own drawing code and our DLL are not the cost.
- Of the main thread's 1001 samples:

  | Frame | Samples |
  |---|---|
  | `CA::Transaction::commit` | 535 |
  | `CA::Layer::prepare_contents` | 530 |
  | `CA::Render::copy_image` → `create_image_by_rendering` | 527 |
  | `CGContextDrawImage` | 527 |
  | `img_data_lock` | 430 |
  | `provider_with_softmask_get_bytes_at_position_inner` | 286 |
  | `CGColorTransformConvertUsingCMSConverter` / `vImageConvert_AnyToAny` | ~284 |
  | waiting (`mach_msg2_trap`) | 260 |

  So about **53% of all main-thread time** is Core Animation re-rendering SAI's window image on the
  CPU, and about **28%** is per-pixel colour conversion inside that, through a soft mask.

The same call chain showed up in two separate `lldb` snapshots earlier the same evening.

### 2. Idle CPU, pen away, nothing happening (`top`, `ps -M`)

| SAI idle | Retina on | Retina off |
|---|---|---|
| Window visible | ~55% (main thread ~30%) | ~15% (main thread ~10%) |
| Window hidden | ~27% (main thread ~25%) | ~18% (main thread ~10%) |

For comparison, Wine's Notepad in the same prefix idles at ~2.7%.

### 3. Ruled out, one link at a time (idle CPU, same conditions)

- **Our app**: quitting it while SAI kept running changed nothing (18.2% → 18.5%).
- **Our DLL** (pen bridge, recording, logging): SAI launched with `WINEDLLOVERRIDES="wintab32=b"`
  idled the same (~16-17%).
- **Wine itself**: Notepad ~2.7%.
- **Timelapse recording**: captures now take 4-7 ms and, by default, only run once the pen rests.
  Sessions with recording almost idle still lagged.
- **Power and heat**: plugged in vs battery made no difference; Low Power Mode off; no thermal warnings.
- **A second pen sender**: pen rate a normal 113-139 points/s, one app running.
- **SAI redrawing constantly**: a Wine `+win,+bitblt` trace of an idle open canvas showed almost no
  window updates (one every few seconds, only on mouse movement).
- **SAI re-setting the cursor**: a `+cursor` trace showed no `SetCursor` while idle; SAI only reads
  the cursor position about 20 times a second.
- **The graphics card**: sai2.exe imports only GDI32/USER32 for drawing and loads no OpenGL,
  Direct3D, DXGI or Vulkan library. SAI draws with the CPU on Windows too.
- **See-through windows**: the trace shows no `WS_EX_LAYERED` and no
  `SetLayeredWindowAttributes`, so SAI is not the source of the mask.
- **An open canvas matters**: SAI without a document idled at ~4-8%, with one at ~16-17%
  (Retina off).

### 4. The "merged pen points" counter is too noisy to compare sessions

`recv - posted` in `wt_status.txt` (points our DLL had to merge because SAI was busy) ranged from
0.4% to 18% across similar sessions, including sessions where recording did almost nothing. It
depends on how fast and how large one scribbles. One session proves nothing; use idle CPU or
spindump instead.

## What is not proven yet

- **Why** macOS has to convert. Most likely the image Wine hands over (a `CGImage`, apparently
  with a mask or alpha) is in a different colour space from the display (P3 on this XDR panel), and
  a masked image cannot be colour-matched on the GPU, so Core Animation renders it on the CPU.
  Not tested: changing the display profile to sRGB was declined (no "Colour profile" option on the
  XDR preset page, and we did not want to change system colours).
- **Why idle CPU is high** when the Wine trace shows few window updates. The idle numbers fit the
  same mechanism at a lower rate, but that link is not measured.
- **Whether Wine's IOSurface change fixes it.** In current Wine master, `WineContentView updateLayer`
  sets `layer.contents = _ioSurface` instead of a `CGImage`, which macOS can composite on the GPU.
  That should remove the CPU re-render, but only a test with Wine 11.22 or later will tell.

Wine's Mac driver has no colour-profile setting. Its registry options are: WindowsFloatWhenInactive,
CaptureDisplaysForFullscreen, AllowVerticalSync, AllowSetGamma, Left/RightOptionIsAlt,
Left/RightCommandIsCtrl, AllowSoftwareRendering, AllowImmovableWindows,
UseConfinementCursorClipping, CursorClippingLocksWindows, UsePreciseScrolling, OpenGLSurfaceMode,
EnableAppNap, RetinaMode.

## Test app: colour profile or mask? (2026-11-08)

`tools/handoff-test/main.swift` copies Wine 11.16's handoff (32-bit BGRX `CGImage` over a data
provider, optional `CGImageCreateWithMask`, `CGImageCreateWithImageInRect`, set as `layer.contents`)
in a 2704x1660 px Retina window, aiming for 60 updates/s for 8 s per variant. The display reports
its colour space as "Color LCD". Target is 480 updates; fewer means the main thread could not keep up.

| Variant | Intel build (Rosetta, like Wine) | Apple chip build |
|---|---|---|
| sRGB + mask (Wine 11.16) | 281 updates, ~99% CPU | 478 updates, 92% CPU |
| sRGB, no mask | 371 updates, ~98% CPU | 480 updates, **58% CPU** |
| P3 + mask | 87 updates, ~99% CPU | 273 updates, 99% CPU |
| P3, no mask | 95 updates, ~99% CPU | 320 updates, 99% CPU |

What it says:
- **Matching the colour profile would not help.** Tagging the picture P3 was the slowest variant by
  far; sRGB was the fastest. The display's own profile is "Color LCD", not plain P3, so "P3" is not
  a match either. The colour-profile idea is not supported.
- **The mask costs extra**, but removing it alone is not enough: under Rosetta the sRGB, no-mask
  variant still could not reach 60 updates/s.
- **Handing a whole new picture to macOS on every update is the expensive part**, and Rosetta makes
  it much worse. That is what Wine's IOSurface change replaces.

## Backported fix tested (2026-11-08)

Wine's IOSurface commit `b77a5f9b60` was backported to 11.16 by hand and only `winemac.so` rebuilt
(branch `wine-iosurface`, `tools/winemac-iosurface/`). In a copy of Wine, Retina on, same test canvas:
SAI idle **~55% → ~9%** of a core, main thread ~25-30% → ~5%; while drawing the main thread went from
~68% (spindump) to ~6%. Anastasia: "feels way faster". Not yet tested with pen pressure through the app.

## Next steps

1. When Gcenx publishes Wine 11.22 (or later): install it next to 11.16, point the app at it
   (`WINE=` env, or install it as the default), and repeat the spindump while drawing with Retina on.
   Success looks like `create_image_by_rendering` / colour conversion gone from the main thread and
   strokes keeping up.
2. If it helps: move the installer (`install-wine.sh`) to that Wine and say so in #39.
3. If it does not: look at what the IOSurface path still converts, and consider proposing a Wine
   change upstream.

## How to measure (for next time)

- Idle CPU: `top -l 3 -s 2 -stats pid,cpu -pid <pid>`; per thread: `ps -M -p <pid>`.
- Where the main thread spends time, no Xcode needed and without pausing SAI:
  `sudo spindump <pid> 10 10 -file ~/sai-spindump.txt`, then count frames in the main thread's
  section. `sample` (even under `arch -x86_64`) shows only addresses for Rosetta processes.
- `lldb -p <pid> --batch -o "thread backtrace 1" -o detach` works for single snapshots. **Do not**
  script repeated stop/continue cycles: an interrupted script left SAI frozen and then closed it,
  losing an unsaved canvas.
- Wine traces: launch from Terminal with `WINEDEBUG=+timestamp,+win,+bitblt` or `+cursor` and
  `2> file`. Close any SAI that is open first, including a hidden one: a second launch just hands
  over to the running SAI.
