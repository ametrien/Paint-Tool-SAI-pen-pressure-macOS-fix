---
title: How it works
---

[← back](index.md)

## Where your files go

The single most common misunderstanding: **SAI is copied into a Wine prefix and runs from
there.** The folder you pick during setup is a *source*, used once.

| | |
|---|---|
| Your SAI folder | a **source**. Copied at install; not needed to run |
| `~/SAI2-pressure/drive_c/SAI2` | what actually **runs**, licence included |
| `~/Library/Application Support/SAIPenPressure` | settings, a saved copy of your licence |

So editing files in your own SAI folder — most often dropping in the `.slc` — changes nothing
until you reinstall. The setup window shows both locations as separate rows for this reason.

## The pieces

**`wintab32.dll`** — a small WinTab implementation loaded *inside* SAI. SAI asks it for pen
packets; a Wine registry override makes SAI load ours instead of Wine's stub.

**The macOS helper** — reads your tablet through a `CGEventTap` (hence Input Monitoring) and
streams each sample over UDP to the DLL, with a file as fallback.

**The setup app** — the two above, plus Wine and licence management, behind one window.

Running inside SAI's own process is also what lets features like pinch-to-zoom work without
asking for extra permissions: the DLL posts messages to SAI directly, so nothing has to be
synthesised at the macOS level.

## Pressure resolution

The app reads your tablet's HID tip-pressure range and uses its real level count — a Wacom
Intuos BT S reports 4096. You can override this in **Settings → Pressure levels**, but setting
more levels than the hardware has doesn't give finer control: the same steps get spread over a
wider range, so sensor noise shows up as wobbly stroke width.

**Pen feel** applies a response curve before the value is sent, so it takes effect without
restarting SAI. It stacks with your tablet driver's own curve and SAI's per-brush Min Size —
which is why the default is linear.
