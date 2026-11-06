#!/usr/bin/env python3
"""End-to-end multi-monitor check (issue #37), no tablet and no screenshots.

For a screen layout, this: adds a fake display (vdisplay) where asked, starts
SAI under Wine with the DLL's debug log on and WITHOUT the helper, hovers a
fake pen (inject.py --hover) at known points on every screen, then reads back
from the DLL log (WT_LOG_POS) exactly what SAI was told for each point, and
compares that with where the point really is inside the tablet area SAI opened.

Hover only, pressure 0, and the cursor is never moved: nothing clicks or draws
in SAI, and nothing touches the user's mouse. The cursor self-check is off for
the run (WT_NO_SELFCHECK), since the real cursor is wherever it happens to be;
its decision logic is covered by tests/test_wintab_core.c.

    harness.py <case> [--keep]

cases:
  left | right | above | below   fake 1920x1080 screen there, SAI started after
  hotplug-right                  SAI started on one screen, fake screen added
                                 to the right while it runs (the #37 report)
  unplug                         SAI started with the fake screen on the left,
                                 which is then removed while it runs

PASS means: for every point inside SAI's area, the DLL meant that exact
screen point and posted that exact position (to 1 px); every point outside
the area was flagged outside, so it is never posted (stepped aside).

Needs: SAI installed in $SAI_PREFIX (default ~/SAI2-pressure) with the DLL
under test in system32, and SAI Pen Pressure NOT running (its helper would
send real samples in between ours). The fake display does change the screen
layout while a case runs; it is removed again at the end.
"""
import os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
PREFIX = os.path.expanduser(os.environ.get("SAI_PREFIX", "~/SAI2-pressure"))
WINE_BIN = "/Applications/Wine Staging.app/Contents/Resources/wine/bin"
LOG = f"{PREFIX}/drive_c/wtlog.txt"
sys.path.insert(0, HERE)
import inject  # noqa: E402


def sh(*a, **k):
    return subprocess.run(a, capture_output=True, text=True, **k)


def kill_sai():
    env = dict(os.environ, WINEPREFIX=PREFIX)
    sh(f"{WINE_BIN}/wineserver", "-k", env=env)
    for _ in range(40):
        if not sh("pgrep", "-f", "sai2.exe").stdout.strip():
            return
        time.sleep(0.25)


def start_vdisplay(where):
    p = subprocess.Popen([f"{HERE}/vdisplay", where], stdout=subprocess.PIPE, text=True)
    for line in p.stdout:                      # wait until it has been placed
        if "placed" in line:
            break
    time.sleep(1.5)
    return p


def start_sai():
    if os.path.exists(LOG):
        os.remove(LOG)
    env = dict(os.environ, WINEPREFIX=PREFIX, WINEDEBUG="-all", WT_DEBUG="1",
               WT_LOG_POS="1", WT_NO_SELFCHECK="1")
    subprocess.Popen([f"{WINE_BIN}/wine", "sai2.exe"], cwd=f"{PREFIX}/drive_c/SAI2", env=env,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(120):
        if os.path.exists(LOG) and "ctx from SAI" in open(LOG, errors="replace").read():
            time.sleep(2)
            return
        time.sleep(0.5)
    raise SystemExit("SAI never opened a tablet context (is 'Use WinTab API' on?)")


def log_text():
    return open(LOG, errors="replace").read()


def sai_area(text):
    """The area SAI believes in: its opened context, updated by any re-read."""
    m = re.findall(r"ctx from SAI: .*?out=\((-?\d+),(-?\d+) ext (-?\d+),(-?\d+)\) "
                   r"sys=\((-?\d+),(-?\d+) ext (-?\d+),(-?\d+)\)", text)
    oX, oY, eX, eY, sx, sy, sw, sh_ = map(int, m[-1])
    for r in re.findall(r"SAI re-read its context: area .*? -> \((-?\d+),(-?\d+) (\d+)x(\d+)\)", text):
        sx, sy, sw, sh_ = map(int, r)
        eX, eY = sw * 8, sh_ * 8
    return oX, oY, eX, eY, sx, sy, sw, sh_


def expected(gx, gy, area):
    oX, oY, eX, eY, sx, sy, sw, sh_ = area
    inside = sx <= gx < sx + sw and sy <= gy <= sy + sh_
    x = oX + int((gx - sx) * 8) * eX // (sw * 8)
    y = oY + int((sy + sh_ - gy) * 8) * eY // (sh_ * 8)
    return inside, x, y


def tap_all(results, label):
    for did, r in inject.displays().items():
        for fx, fy in ((0.5, 0.5), (0.1, 0.1), (0.9, 0.9)):
            before = log_text().count("\nPOS ")
            sys.argv = ["inject", str(did), str(fx), str(fy), "--hover", "--quiet"]
            inject.main()
            gx, gy = r.x + fx * r.w, r.y + fy * r.h
            text = log_text()
            pos = re.findall(r"\nPOS screen=\((-?\d+),(-?\d+)\) inside=(\d) out=\((-?\d+),(-?\d+)\)", text)
            if len(pos) <= before:
                results.append(False)
                print(f"  FAIL {label} display {did} at ({gx:.0f},{gy:.0f}): no POS line (DLL got nothing)")
                continue
            sx, sy, ins, ox, oy = map(int, pos[-1])
            inside, ex, ey = expected(gx, gy, sai_area(text))
            on_glass = abs(sx - gx) <= 1 and abs(sy - gy) <= 1
            if inside:
                ok = on_glass and ins == 1 and abs(ox - ex) <= 8 and abs(oy - ey) <= 8
                what = f"screen ({sx},{sy}) out ({ox},{oy}), want out ({ex},{ey})"
            else:
                ok = on_glass and ins == 0
                what = f"screen ({sx},{sy}) outside SAI's area, flagged inside={ins} (want 0)"
            results.append(ok)
            print(f"  {'PASS' if ok else 'FAIL'} {label} display {did} at ({gx:.0f},{gy:.0f}): {what}")


def main():
    case = sys.argv[1] if len(sys.argv) > 1 else "left"
    keep = "--keep" in sys.argv
    kill_sai()
    results, vd = [], None
    try:
        if case in ("left", "right", "above", "below"):
            vd = start_vdisplay(case)
            start_sai()
            tap_all(results, case)
        elif case == "hotplug-right":
            start_sai()
            tap_all(results, "before")
            vd = start_vdisplay("right")
            time.sleep(3)                       # DLL re-checks screens once a second
            tap_all(results, "after")
        elif case == "unplug":
            vd = start_vdisplay("left")
            start_sai()
            tap_all(results, "before")
            vd.terminate(); vd.wait(); vd = None
            time.sleep(3)
            tap_all(results, "after")
        else:
            raise SystemExit(__doc__)
        text = log_text()
        for line in text.splitlines():
            if re.search(r"OwnTab .* loaded|ctx from SAI|SCREENS|SELFCHECK|WTGetW|WTInfoW cat=3|WTSetW|WTOpen|WTClose", line):
                print("  log:", line[:200])
    finally:
        if not keep:
            kill_sai()
        if vd:
            vd.terminate(); vd.wait()
    print(f"{case}: {sum(results)}/{len(results)} passed")
    sys.exit(0 if results and all(results) else 1)


if __name__ == "__main__":
    main()
