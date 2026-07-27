---
title: How it works
---

[← back](index.md)

## The shape of the problem

SAI is a Windows program asking a Windows API for pen data. Your tablet is a USB device talking
to a macOS driver. Between them sits Wine, translating Windows calls into something macOS
understands — but Wine has no tablet driver to translate *from*, so the WinTab calls return
nothing and SAI concludes there is no pen.

Everything here follows from that: we have to be on **both sides** of the boundary at once.

## The three pieces

### `wintab32.dll` — inside SAI

A small WinTab implementation, cross-compiled for Windows with mingw and loaded into SAI's own
process. A Wine registry override (`DllOverrides\wintab32 = native,builtin`) makes SAI load ours
instead of Wine's stub. SAI then asks it, perfectly ordinarily, for pen packets.

Living inside SAI's process turns out to matter far beyond pressure. It means we can call Win32
APIs *as SAI* — which is how the "Wake SAI" recovery restores a lost window, and how
pinch-to-zoom posts a wheel message without needing any macOS permission at all. A translator
that sits inside the room can do things a translator shouting through the door cannot.

### The macOS helper — outside

Reads the tablet through a `CGEventTap`, which is why Input Monitoring is required and why it is
the *only* permission needed. A tap, rather than a passive monitor, because macOS coalesces
monitored events and fast strokes lost samples — you could see it as missing dots in a quick line.

Each sample goes over UDP to `127.0.0.1:47800`, with a file as fallback. UDP because a dropped
packet matters less than a delayed one; a stale pressure value is worse than a missing frame.

### The setup app

Both of the above, plus Wine, the SAI folder, and licence handling, behind one window. It is
mostly there to make the fiddly parts unfiddly.

## Where your files actually go

This is the single most common misunderstanding, and it has cost people whole evenings.

**SAI is copied into a Wine prefix and runs from there.** The folder you choose during setup is a
*source*, read once at install time.

| | |
|---|---|
| Your SAI folder | a **source**. Copied at install. Not needed to run |
| `~/SAI2-pressure/drive_c/SAI2` | what actually **runs**, licence included |
| `~/Library/Application Support/SAIPenPressure` | settings, and a saved copy of your licence |

So editing your own SAI folder changes nothing until you reinstall. The commonest version of
this: dropping the `.slc` licence into your SAI folder, restarting, and finding SAI still refuses
to save. The file is real, it is valid, and SAI never looks there.

The setup window shows both locations as separate rows for exactly this reason — *source* and
*installed in Wine* — so they can visibly disagree instead of quietly disagreeing.

## Pressure resolution

The app reads your tablet's HID tip-pressure element and uses its logical range as the level
count. A Wacom Intuos BT S reports 4096. No lookup table of model names — the hardware is asked
directly, so it works for tablets nobody has tested.

You can override this in **Settings → Pressure levels**, and it will warn you if you ask for more
levels than your tablet has. That warning is earned: asking a 4096-level tablet for 8192 doesn't
invent detail, it spreads the same steps over twice the range, and sensor noise that used to be
rounded away becomes visible as stroke width wobbling. It looks like the tool got worse, because
it did.

**Pen feel** applies a response curve before transmission, so it needs no restart. It stacks with
your tablet driver's own curve and SAI's per-brush Min Size, which is why the default is linear —
three curves multiplying together is how a pen ends up feeling broken in ways nobody can trace.

## Why a licence lands in two folders

Where SAI reads the certificate **changed between builds**. Older Ver.2 builds read it beside
`sai2.exe`; the 2026-07-12 "Major Renovated" preview reads it from a `settings` folder.

Guessing wrong is indistinguishable from an invalid licence — SAI simply refuses to save, with no
hint that the file is merely misplaced. Since a certificate is 128 bytes, the app stops guessing
and writes both. Whichever build you run finds its own.

---

[Home](index.md) · [Install](install.md) · [Troubleshooting](troubleshooting.md) · [How it works](how-it-works.md) · [Engineering notes](notes.md) · [GitHub](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix)
