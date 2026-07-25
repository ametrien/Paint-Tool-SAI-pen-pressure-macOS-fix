# Known issues

An honest list of the bugs we know about — the symptom, the underlying cause, **what we
tried, and what didn't work** — so nobody re-treads the dead ends.

Both issues below are caused by layers **beneath** this project (SAI itself, and Wine's
macOS driver). They are not defects in the pressure bridge, and there is no bridge-side fix
for either without breaking something more important (drawing). Contributions that prove
otherwise are very welcome.

---

## 1. Pen taps on SAI's top menu row ("File", "Edit", …) — ✅ FIXED (v0.1.4)

**Was:** while the pen was in range, tapping SAI's top menu bar did nothing (the canvas and
panels worked; the mouse clicked the menu fine).

**Cause.** SAI de-duplicates pen-vs-mouse input. While our WinTab stream told SAI a pen was
present, SAI discarded the pen's *synthesized mouse click* on the menu — the menu bar is
driven by mouse clicks, not WinTab packets, so the click was dropped. (Advertising the context
as `CXO_SYSTEM` made SAI take the click but then double-fire it, opening-and-closing the menu,
because Wine's mouse events lack the `GetMessageExtraInfo == 0xFF515700` pen signature Windows
apps use to de-dup — so that route was a dead end.)

**Fix.** The helper reads the pen's screen position *and* SAI's window rectangle (via
`CGWindowList`). While the pen is over the **top menu strip** of SAI's window, the helper
streams **nothing** — no hover, no pressure — so SAI sees no pen there and the pen's ordinary
mouse click gets through and opens the menu. Over the canvas and panels, the full pressure
stream continues unchanged. Strip height is tunable with `WT_MENU_STRIP=<points>` (0 disables).

---

## 2. SAI freezes on input after switching apps (still open — manual recovery works)

**Symptom.** After switching to another macOS app and back, SAI's window *looks* focused but
the **canvas ignores both pen and mouse** (no brush dot, nothing draws). The top menu row
still responds.

**Confirmed root cause** (via extensive logging — see
[issue #2](https://github.com/ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix/issues/2)):
SAI's window loses its **Win32 foreground/active** status (a `winemac.drv` focus bug — Wine
doesn't restore Win32 activation even though macOS shows SAI as active). That single state
causes both symptoms: SAI's window proc eats clicks when inactive (`WM_MOUSEACTIVATE` →
`MA_NOACTIVATEANDEAT`), *and* the Wacom driver demotes the pen to a plain mouse (no pressure)
because the target window isn't foreground. The menu works because it's a separate hit-path.

**Ruled out with logs:** App Nap / our helper freezing (its heartbeat keeps ticking); the
event tap dying (`tapEnabled=true` throughout); SAI disabling our WinTab context (`open=1`);
the DLL/pipeline. Input *does* still reach us while stuck — it's just demoted to plain mouse.

**Recovery (reliable, manual).** Press **⌃⌥⌘Space** (Control-Option-Command-Space), or click
the **🖊 menu-bar icon → *Wake SAI window*** (also a setup-window button). It finds the exact
process that owns SAI's window (via `CGWindowList`) and re-activates it, restoring foreground —
which fixes both the mouse and the pen at once. Returning via **Cmd-Tab** usually auto-wakes it.

**Not yet solved: fully automatic recovery.** Detecting the stuck state is doable (the
pen-demotion is a clean signal; opt-in `WT_DEMOTION_WAKE=1`), but the macOS-side re-activation
doesn't *reliably* restore Win32 foreground on its own. The promising next lever is calling
`SetForegroundWindow` from **inside SAI on its UI thread** (our DLL is in-process). Help welcome.

**Manual fallback if the wake ever misses:** switch to a different Space and back (three-finger
swipe left/right).

*Sources: [Wine winemac.drv source](https://github.com/wine-mirror/wine/blob/master/dlls/winemac.drv/macdrv_main.c),
[winemac input-loss report](https://github.com/Sikarugir-App/Sikarugir/issues/237).*

---

## Non-bugs (expected — please don't report these)

- **Boxy fast curves over Bluetooth** (~130 Hz report rate) — use a USB data cable (~200 Hz).
- **Low pressure feels non-linear / jumpy** in the raw "Test Tablet Pressure" bar — that's the
  tablet's physical activation-force region; SAI applies its own pressure curve when drawing,
  so strokes feel smooth.
