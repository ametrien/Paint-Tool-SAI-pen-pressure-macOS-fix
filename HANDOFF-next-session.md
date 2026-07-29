# Handoff — SAI Pen Pressure macOS

**Repo:** `/Users/admin/Documents/sai-pen-pressure-macos`
**GitHub:** `ametrien/Paint-Tool-SAI-pen-pressure-macOS-fix`
**Docs:** https://ametrien.github.io/Paint-Tool-SAI-pen-pressure-macOS-fix/
**Maintainer:** Anastasia (GitHub: **ametrien**)
**Current release:** v0.1.11 — published, artifact verified, confirmed working across a Mac restart.

---

## ⚠️ READ FIRST — things that will waste your time otherwise

### 1. `gh` silently reverts to the wrong account

`gh` has several accounts (`adorite`, `petaloverflow`, `anstasia-dev`) and **defaults to `adorite`, which has `push: false`** on this repo. It reverts on its own between sessions. Before any GitHub write:

```bash
gh api user --jq .login          # must print: ametrien
gh auth switch --user ametrien   # if it doesn't
```

### 2. The helper and SAI must BOTH be running

Three separate pressure tests were wasted in one session because the helper had been closed — reusing the same terminal window kills it. With no helper, SAI paints from plain mouse events, which carry **no pressure at all**, and the result looks exactly like "pressure is broken".

Check before believing any pressure result:

```bash
pgrep -f wacom-pressure-helper || echo "HELPER DEAD — any pressure test is invalid"
```

In `wtlog.txt` the same fact appears as `recv=0 … udp=quiet`.

### 3. The verbose helper log is BIASED toward zeros

`main.swift` prints a sample only when `seq % 100 == 1 || p == 0` — i.e. **every zero, but only one in every hundred non-zeros.** A perfectly healthy pen therefore looks like a wall of `pressure=0`, and the real values land only on sequence numbers ending in `01`. This has been misread as "pressure is broken" more than once. The zeros are hover samples; judge by the non-zero lines.

### 4. Wine's `wineserver` outlives the app

A per-prefix daemon; launching a different `wine` binary attaches to the **existing** server. Before any Wine test:

```bash
pkill -f sai2.exe
"/Applications/Wine Staging.app/Contents/Resources/wine/bin/wineserver" -k
pkill -f wineserver
sleep 3
```

### 5. `experimental-changes.patch` in this folder is OBSOLETE — do not apply it

It holds a previous session's guesses (`.cghidEventTap` → `.cgSessionEventTap`, an `NSEvent` pressure fallback, a `print()` inside the tap callback). **None of them were the problem.** The tap change reverses a documented decision — the HID tap was chosen because higher-level taps are coalesced and drop fast pen samples — and the `print()` runs inside the tap callback, where a slow callback makes macOS disable the tap outright. Delete the file when convenient.

---

## What the "pressure stopped after a Mac restart" problem actually was

**The restart was a coincidence.** The regression shipped in v0.1.10.

`#19` had made the click de-dup opt-in with a guard at the **install site**: the `WH_GETMESSAGE` hook simply wasn't installed unless you asked for it, so the hook's existence *was* the proof of consent and `click_hook_proc` never needed a check of its own. `#24` (two-finger pan) needed that same hook and is on by default, so the early return was widened to `if (!want_dedup && !want_pan) return;`. The hook began installing for everyone, the install-site guard silently stopped guarding anything, and `WM_LBUTTONDOWN` was eaten 2 ms after every pen-down. The log read `dedup=off` while recording itself eating clicks.

A stroke that never starts also has no pressure — which is why this presented as "pen pressure stopped working" rather than "clicks are ignored".

Fixed in v0.1.11 (#26): the decision moved into `wintab_core.h` as `wtc_should_eat_click()`, gated on the resolved flag, with 13 native test cases **proven to fail when the bug is deliberately reintroduced**.

### Ruled out with evidence — don't re-investigate

Input Monitoring, the Wacom driver, Bluetooth pairing, the `wintab32` DLL override, the licence, the Wine prefix, reinstall cleanliness, and the event tap itself (it is `.listenOnly` and *cannot* consume clicks).

### Also fixed in v0.1.11

- **#27** — detection ran once at startup, and a sleeping Bluetooth tablet isn't enumerable then, so a 4096-level pen silently ran at 1024 with nothing reported. Last known good is now remembered in `pmax-detected.txt`, and the tablet is re-asked just before SAI starts.
- **DLL delivery** — `installBridge()` only ever ran during setup/reinstall, so an app **upgrade** left the old DLL in the prefix. Without this fix, v0.1.11's DLL work would have reached nobody. `syncBridgeDLL()` now syncs it on every launch. Remember this one: *a fix can be correct, committed, released, and still not reach the user.*
- The DLL log carries a `built <date> <time>` stamp, so "is the fix even loaded?" is answerable rather than guessed.

---

## Open issues

- **#28** — install/uninstall/reinstall never stop `wineserver`; uninstall deletes the prefix out from under a live daemon; nothing prevents two SAI instances; `performSetup`'s long steps (wineboot ~1 min, full SAI copy) show no progress and read as frozen. Confirmed by inspection, **not reproduced**. The progress infrastructure already exists in `installWineInApp()` (it parses live `curl` percentages) — it just isn't threaded through `performSetup`.
- **#25** — SAI's "Discharging of recovery point" error. **Proven not ours**: reproduces with `WINEDLLOVERRIDES="wintab32=b"`, on both SAI builds, two Wine versions, fresh prefixes. Two wrong conclusions are recorded in the issue so nobody repeats them. #28's "two SAI instances" is worth eliminating before digging further — same shape, but *not* a claim they are the same bug.
- **#14** — menu-bar pen icon lands at x=1322 on a 1352pt screen. Seven theories disproven, and an older release shows it too, so it isn't a regression. Next step is mechanical: bisect `applicationDidFinishLaunching` until the item lands at x≈863 like a minimal control app.

---

## Architecture

```
Wacom tablet
  → macOS CGEventTap (needs Input Monitoring)
  → wacom-helper (Swift)  ──UDP 127.0.0.1:47800──┐
                          └─ wt_pressure.txt ────┤
                                                 ↓
                       wintab32.dll  (runs INSIDE SAI's process, via Wine)
                                                 ↓
                                               SAI
```

**Key architectural fact:** our DLL runs *inside SAI's process*, so it calls Win32 APIs **as SAI**. That is how "Wake SAI", pinch-to-zoom and scroll-to-pan all work **without the Accessibility permission**.

| Path | Purpose |
|---|---|
| `~/SAI2-pressure/` | Wine prefix; SAI is **copied** here and runs from here |
| `~/SAI2-pressure/drive_c/wt_pressure.txt` | helper writes, DLL reads |
| `~/SAI2-pressure/drive_c/wtlog.txt` | DLL log — **only** with `WT_DEBUG=1`, **overwritten each launch** |
| `~/SAI2-pressure/drive_c/wt_pmax.txt` | pressure full-scale, shared helper↔DLL |
| `~/Library/Application Support/SAIPenPressure/` | settings (`pmax.txt` = user override, `pmax-detected.txt` = last detected), licence stash |
| `~/Documents/SYSTEMAX Software Development/SAIv2/` | **SAI's own** settings + error logs; outside the prefix, survives every rebuild |

---

## Commands

```bash
# app: universal, auto-signed, installed, launched
cd /Users/admin/Documents/sai-pen-pressure-macos && ./make-app.sh && rm -rf "/Applications/SAI Pen Pressure.app" && cp -R "dist/SAI Pen Pressure.app" /Applications/ && open "/Applications/SAI Pen Pressure.app"

# DLL (only if wintab32.c changed) — then rebuild the app as above
cd /Users/admin/Documents/sai-pen-pressure-macos/wintab-src && x86_64-w64-mingw32-gcc -shared -O2 -o wintab32.dll wintab32.c wintab32_res.o wintab32.def -lgdi32 -luser32 -lws2_32 -municode && cp wintab32.dll ~/SAI2-pressure/drive_c/windows/system32/wintab32.dll

# tests (native; no tablet, Wine or mingw needed)
bash tests/run-tests.sh
```

The version comes from the latest **git tag**, so tag before building a release. `make-app.sh` auto-signs with the machine's Apple Development identity; ad-hoc signing (`SIGN_ID="-"`, what CI gets) gives every build a new identity, so macOS loses Input Monitoring on every rebuild and never re-prompts.

### The two-terminal diagnostic

```bash
# terminal 1 — leave running
cd /Users/admin/Documents/sai-pen-pressure-macos && WT_VERBOSE=1 ./wacom-helper/wacom-pressure-helper

# terminal 2 — a NEW window, not the same one
pkill -f sai2.exe; "/Applications/Wine Staging.app/Contents/Resources/wine/bin/wineserver" -k 2>/dev/null; pkill -f wineserver; sleep 3; cd ~/SAI2-pressure/drive_c/SAI2 && WINEPREFIX=~/SAI2-pressure WINEDEBUG=-all WT_DEBUG=1 "/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine" sai2.exe
```

Then read `~/SAI2-pressure/drive_c/wtlog.txt`. `posted=/recv=/gaps=/fetched=` tells you exactly which hop is broken. **Copy it before relaunching.**

---

## Working style that keeps paying off

- **Instrument before theorising.** `WT_DEBUG=1` answered in one run what hours of reasoning did not. Every real fix this project has had came from a log or a measurement.
- **A test that has never failed is not evidence.** A "0 clicks eaten" result was once reported as proof the fix worked — while the helper was dead and no click *could* have been eaten. The broken build would have printed the same thing. Reintroduce the bug and watch the test fail.
- **Verify the artifact, not the build.** Download the published zip and check version, architectures, signature and the DLL's md5.
- **Don't close an issue on "code written".** #8 was closed that way and broke drawing for two releases — and v0.1.11 finally found the mechanism that made it possible: the DLL never reached the prefix on upgrade.
- **State confidence honestly** — "leading hypothesis, unverified" vs "confirmed, here is the evidence". Anastasia acts immediately on stated causes, so a wrong one costs real time.
