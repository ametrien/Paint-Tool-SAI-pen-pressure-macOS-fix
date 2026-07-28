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
pinch-to-zoom and two-finger scroll-to-pan post their messages without needing any macOS
permission at all. A translator that sits inside the room can do things a translator shouting
through the door cannot.

Because it lives in the Wine prefix rather than in the app, upgrading the app used to leave the
old DLL in place — so a release whose entire content was a DLL fix could reach nobody. Since
**v0.1.11** the prefix copy is compared against the app's on every launch and replaced when they
differ, and the DLL stamps its build date into its debug log, so *"is the fix actually loaded?"*
is a question with an answer.

### The macOS helper — outside

Reads the tablet through a `CGEventTap`, which is why Input Monitoring is required and why it is
the *only* permission needed. A tap, rather than a passive monitor, because macOS coalesces
monitored events and fast strokes lost samples — you could see it as missing dots in a quick line.

Each sample goes over UDP to `127.0.0.1:47800`, with a file as fallback. UDP because a dropped
packet matters less than a delayed one; a stale pressure value is worse than a missing frame.

### The setup app

Both of the above, plus Wine, the SAI folder, and licence handling, behind one window. It is
mostly there to make the fiddly parts unfiddly.

## Recording the canvas

*Requires v0.2.0 or later.*

The timelapse does not screen-record. It reads SAI's canvas out of SAI's own memory, which is why
the video contains the artwork and nothing else — no panels, no cursor, and no camera movement when
you zoom or pan while drawing.

That is possible because of where the bridge already lives. `wintab32.dll` is loaded *inside*
`sai2.exe`, so reading the canvas is an ordinary memory read rather than something requiring a
debugger, a permission prompt, or a second process. Being the tablet driver also means a finished
stroke is a fact we are told, not one guessed at from mouse movement — which is what makes "one
frame per brush stroke" possible at all.

SAI stores the canvas as a pyramid of 256×256 tiles, one level per zoom step. The reader walks the
smallest level still larger than the target size, stitches the tiles into a single image, and hashes
it: if a stroke changed nothing — an undo, a pan, a toolbar click — no frame is written. Frames go to
disk as raw images, and a small bundled encoder turns them into H.264 with AVFoundation.

The one cost of living inside SAI is that a bad pointer would take SAI down, along with unsaved work.
So every read is checked against the memory map before it happens, the canvas structures are
validated before anything inside them is followed, and a fault of any kind switches recording off for
the session rather than trying again.

The offsets those structures live at are specific to each SAI build, and change with every release.
They are recorded in a table, and there is a scanner in the repository that derives them from a
running SAI — which is how support for a new build gets added.

## Where your files actually go

This is the single most common misunderstanding, and it has cost people whole evenings.

**SAI is copied into a Wine prefix and runs from there.** The folder you choose during setup is a
*source*, read at install time — not the copy that runs.

| | |
|---|---|
| Your SAI folder | a **source**. Copied at install. Not needed to run |
| `~/SAI2-pressure/drive_c/SAI2` | what actually **runs**, licence included |
| `~/Library/Application Support/SAIPenPressure` | settings, and a saved copy of your licence |

So editing your own SAI folder changes nothing until you reinstall. Update SAI itself, and the
copy inside Wine keeps running the old build until you reinstall it — which is why the setup
window shows *source* and *installed in Wine* as separate rows, so they can visibly disagree
instead of quietly disagreeing.

**The licence is the exception.** It used to be the commonest version of this trap: dropping the
`.slc` into your SAI folder, restarting, and finding SAI still refused to save — the file real,
valid, and in a folder SAI never reads. Since **v0.1.12** a certificate found in your SAI folder
is adopted rather than ignored: noticed when you choose the folder, and again on every install or
reinstall, then written to every location SAI might read and kept so a rebuild can restore it.

## Pressure resolution

The app reads your tablet's HID tip-pressure element and uses its logical range as the level
count. A Wacom Intuos BT S reports 4096. No lookup table of model names — the hardware is asked
directly, so it works for tablets nobody has tested.

Asking the hardware has one catch, found the hard way: a **Bluetooth** tablet that has gone idle
isn't visible to answer, and the question is only asked once, at startup. A 4096-level pen could
therefore run at 1024 with nothing said anywhere — both halves of the bridge agreed on the wrong
number, so everything worked, just coarser. Since **v0.1.11** the last answer your hardware gave
is remembered between launches, and the tablet is asked once more just before SAI starts.

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
