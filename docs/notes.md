---
title: Engineering notes
---

[← back](index.md)

Decisions, and a few mistakes worth preserving. Kept because the *reasoning* is the part that
gets lost, and because a fix whose motivation is forgotten tends to get undone.

---

## The dedup that stopped the pen drawing

**v0.1.5 shipped a bug that made drawing impossible.** Worth dwelling on, because everything
about it was misleading.

Tapping a brush slot with the pen sometimes registered as a double click, opening the Property
dialog. The cause was real: a pen tap reaches SAI twice — once as our WinTab packet, once as the
mouse click Wine synthesises from the same tap. Real Windows drivers tag their synthetic events
so applications can tell them apart; Wine's carry no tag.

The fix was a `WH_GETMESSAGE` hook that swallowed left-button messages arriving within 400 ms of
a pen-tip transition, scoped "to the main window only, since dialogs are separate windows."

That scoping reasoning was wrong in one word. **The canvas is also a child of the main window.**
So the hook ate the `WM_LBUTTONDOWN` that begins every stroke, roughly 6 ms after each pen-down.

What made it genuinely hard was that every diagnostic looked *perfect*:

```
posted=274 recv=274 gaps=0 fetched=274 udp=live
WTPacket #256 press=1023
```

Zero packet loss, full-range pressure, SAI reading every packet. The pressure pipeline was
flawless. SAI simply was never told the button went down. And because the bug lived in the
bundled DLL, **no amount of reinstalling could fix it** — which is exactly what the user tried,
repeatedly, for hours.

Three lessons, all paid for:

1. **A working data path is not a working feature.** We measured throughput and concluded health.
2. **Reach for the instrumented path first.** `WT_DEBUG=1` writes a log showing precisely what SAI
   received. It answered in seconds what reasoning had failed to answer all evening.
3. **A regression that stops the core function beats the bug it fixed.** The dedup is now opt-in
   (`WT_CLICK_DEDUP=1`) and the double-click issue is reopened. A nuisance is preferable to a pen
   that cannot draw.

### And then it happened again

**v0.1.10 shipped the same outage from a different cause** — which is the more useful story,
because the fix above was still present and still correct.

That fix was a guard at the *install site*: when the dedup was not requested, the hook was simply
never installed. The hook procedure needed no check of its own, because the hook's **existence
was itself the proof of consent**.

Then two-finger pan needed the same `WH_GETMESSAGE` hook. Pan is on by default, so the install
condition was widened to "install if *either* feature wants it" — and the hook began installing
for everyone. The install-site guard silently stopped guarding anything. The commit even stated
the intended contract in a comment: *"Each still decides for itself inside `click_hook_proc`."*
That second half was never written. The flag was computed, logged, and discarded.

The log said `dedup=off` while the same log recorded it eating clicks.

Three further lessons:

4. **A guard that lives somewhere other than the thing it guards is a guard with an expiry date.**
   Nothing was wrong with either change in isolation. The invariant lived in the gap between them,
   where no reviewer and no test could see it.
5. **A comment describing intent is not an implementation.** The comment was accurate about what
   *should* happen and was read, for two releases, as evidence that it did.
6. **A test that has never failed is not evidence.** During the investigation a "zero clicks eaten"
   result was briefly taken as proof the fix worked — while the helper was dead and no click
   *could* have been eaten. The unfixed build would have produced the identical output. The
   decision now lives in `wintab_core.h` behind `wtc_should_eat_click()`, covered by cases that
   were **confirmed to fail when the bug is deliberately reintroduced**.

There is a seventh, learned the same evening and arguably the most expensive:

7. **A fix can be correct, committed, released — and still not reach anyone.** The DLL doing the
   work lives inside the Wine prefix, and it was only ever copied there during first-time setup or
   an explicit reinstall. An *upgrade* left the old one in place. A release consisting entirely of
   a DLL fix would have shipped to nobody, and the bug report would have read "the fix doesn't
   work." Since v0.1.11 the prefix copy is compared against the app's on every launch, and the DLL
   stamps its build date into the log so "is the fix even loaded?" is answerable rather than
   assumed.

## Following the hardware instead of guessing

Pressure was quantised to 1024 levels regardless of hardware — a fixed constant from WinTab
convention. Modern tablets report 4096 or more, so most of the resolution was discarded.

The first attempt simply raised the constant to 8191, and **made drawing visibly worse.** Two
reasons, both instructive:

- De-duplication compared pressure for *exact* equality, so 1024-level quantisation had been
  silently filtering sensor jitter. Removing it exposed every micro-fluctuation as a packet.
- The tablet under test had 4096 levels. Asking for 8192 spread the same hardware steps over
  twice the range — upsampled noise, not detail.

The tablet had been telling us the answer the whole time: its HID tip-pressure element carries a
logical range, and that range *is* the level count. Ask the hardware, then filter jitter
deliberately with a deadband scaled to the chosen resolution, rather than by accident.

## Permissions, and the identity a grant attaches to

macOS attaches Input Monitoring to a **code signing identity**. Ad-hoc signatures have no Team ID
and a new hash on every build, so there is nothing durable to grant to: the permission is lost on
each rebuild, the permission list fills with duplicate entries, and — the part that wastes real
time — **macOS never shows the prompt at all.** It denies the request silently.

`make-app.sh` had defaulted to ad-hoc *on purpose*, reasoning that a distinct identity per build
keeps permissions from entangling across versions. Precisely backwards. It now prefers a real
identity when the machine has one.

Released builds remain ad-hoc, because signing them properly requires a paid Apple Developer
Program membership. That is documented rather than hidden — the install page states plainly that
no prompt will appear, because waiting for a prompt that cannot come is the worst possible
failure mode.

## Doing more by being inside the process

Pinch-to-zoom looked like it would cost the **Accessibility** permission — synthesising key or
scroll events with `CGEvent.post` requires it, and this project had deliberately shed that
permission earlier.

It didn't, because `wintab32.dll` already runs inside SAI. The Mac side only *observes* the
gesture on the tap it already has, and the DLL posts `WM_MOUSEWHEEL` from within SAI's own
process. Nothing is synthesised at the OS level, so nothing needs granting.

`WM_MOUSEWHEEL` rather than PageUp/PageDown because it carries a position — SAI zooms at the
cursor rather than the canvas centre — and because two-finger scroll already proved that path
works.

Generalisable: **a foothold inside the target process is worth more than a permission.** Canvas
rotation could follow the same route.

## Still unsolved

Kept visible rather than quietly dropped.

**The menu-bar icon.** It is created successfully — `isVisible=true`, a real frame — but lands at
x=1321 on a 1352pt screen, underneath the system clock, while a minimal test application on the
same machine lands correctly around x=863. Five theories tested and disproven: a dark emoji
glyph, a missing `autosaveName`, ad-hoc signing, a full menu bar (125pt free, 31pt needed), and a
stale persisted position. The next step is a bisect of the launch sequence, not a sixth theory.

**The second cursor.** The macOS arrow sometimes remains over SAI's brush cursor. One cause was
found and fixed — entering proximity emitted nothing, so SAI was never told a pen had arrived
until it moved. It still recurs intermittently. A captured log killed the leading theory: SAI
opens its context before any packets are sent, so nothing is being lost to a startup race.

---

[Home](index.md) · [Install](install.md) · [Troubleshooting](troubleshooting.md) · [How it works](how-it-works.md) · [Engineering notes](notes.md) · [GitHub](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix)
