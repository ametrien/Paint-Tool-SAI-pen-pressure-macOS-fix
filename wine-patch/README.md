# Wine Mac driver with the IOSurface fix (for Wine Staging 11.16)

`winemac-iosurface-11.16.so` is Wine's Mac display driver (`lib/wine/x86_64-unix/winemac.so`)
rebuilt from Wine 11.16 with:

- upstream Wine commit `b77a5f9b60` ("winemac: Use IOSurface to update native window layers instead
  of CGImage", by Marc-Aurel Zent, based on a patch by Brendan Shanks), backported to 11.16;
- Wine Staging 11.16's `winemac.drv-no-flicker-patch`, so it matches the Staging build.

The full source change is `winemac-iosurface-11.16.patch`, against the `wine-11.16` tag of
https://gitlab.winehq.org/wine/wine. Build steps and test results: `tools/winemac-iosurface/README.md`
on the `wine-iosurface` branch.

## Why

With "Sharp text on Retina screens", Wine 11.16 makes macOS re-draw and colour-convert the whole SAI
window on the CPU on every update. See `RETINA-LAG-FINDINGS.md`. With this driver, SAI's idle CPU went
from ~55% to ~9% of a core with Retina on.

## How the app uses it

`wacom-helper/WinePatch.swift`: before SAI starts, if Retina mode is on and the installed
`winemac.so` is byte-for-byte the known Gcenx Wine Staging 11.16 original (SHA-256 in
`WinePatchCore.swift`), the app backs it up as `winemac.so.orig-11.16` and puts this file in its place.
With Retina off it puts the original back. Any other Wine is never touched. Once Wine ships the fix
itself (expected in 11.22), none of this applies to it.

## Licence

Wine is free software under the GNU Lesser General Public License, version 2.1 or later
(https://gitlab.winehq.org/wine/wine/-/blob/master/COPYING.LIB). This file is a modified Wine
library and is distributed under the same licence; its complete source is Wine 11.16 plus
`winemac-iosurface-11.16.patch`.
