#!/usr/bin/env python3
"""Draw a fake pen stroke in SAI by speaking the helper's wire format to the DLL.

The DLL takes pen samples over UDP 127.0.0.1:47800, so this can play the helper
without a tablet. It draws a small "+" centred on a point of one display, so a
screenshot diff (strokefind) shows where SAI actually put the ink.

    inject.py --list
    inject.py <display-id> <fx> <fy> [--wire old|new] [--size PTS] [--tap] [--warp]

fx, fy are fractions of that display (0.5 0.5 = its centre). Coordinates are
computed exactly as wacom-helper does (PressureCore.mapToVirtual + send()), so
the helper must NOT be running at the same time or its samples mix in.

--hover       hover at exactly that point, pressure 0: never a click in SAI.
              With WT_LOG_POS=1 the DLL logs where it put it (harness.py)
--tap         a single press at exactly that point instead of a "+"
--warp        also move the real cursor there, as a tablet would; without it
              the DLL's self-check sees the cursor elsewhere
--wire old    "seq p x y w h"        (what wacom-helper sends)
--wire new    "seq p x y w h ox oy"  (experimental, not used by the helper)
"""
import ctypes, ctypes.util, socket, sys, time

cg = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))


class CGRect(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double),
                ("w", ctypes.c_double), ("h", ctypes.c_double)]


cg.CGDisplayBounds.restype = CGRect
cg.CGDisplayBounds.argtypes = [ctypes.c_uint32]
cg.CGMainDisplayID.restype = ctypes.c_uint32


class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


cg.CGWarpMouseCursorPosition.argtypes = [CGPoint]


def displays():
    ids = (ctypes.c_uint32 * 16)()
    n = ctypes.c_uint32(0)
    cg.CGGetActiveDisplayList(16, ids, ctypes.byref(n))
    return {ids[i]: cg.CGDisplayBounds(ids[i]) for i in range(n.value)}


def union(ds):
    x0 = min(r.x for r in ds.values()); y0 = min(r.y for r in ds.values())
    x1 = max(r.x + r.w for r in ds.values()); y1 = max(r.y + r.h for r in ds.values())
    return x0, y0, x1 - x0, y1 - y0


def main():
    a = sys.argv[1:]
    ds = displays()
    vX, vY, vW, vH = union(ds)
    if not a or a[0] == "--list":
        main_id = cg.CGMainDisplayID()
        for i, r in ds.items():
            print(f"display {i}{' (main)' if i == main_id else ''}: "
                  f"origin({r.x:.0f},{r.y:.0f}) size {r.w:.0f}x{r.h:.0f}")
        print(f"union: origin({vX:.0f},{vY:.0f}) size {vW:.0f}x{vH:.0f}")
        return
    wire = "new" if "--wire" in a and a[a.index("--wire") + 1] == "new" else "old"
    size = float(a[a.index("--size") + 1]) if "--size" in a else 30.0
    did, fx, fy = int(a[0]), float(a[1]), float(a[2])
    r = ds[did]
    cx, cy = r.x + fx * r.w, r.y + fy * r.h

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    seq = [int(time.time()) % 100000 * 1000]

    warp = "--warp" in a

    def send(p, x, y):
        if warp:
            cg.CGWarpMouseCursorPosition(CGPoint(x, y))
        # == PressureCore.mapToVirtual + main.swift send()
        xf, yf = int((x - vX) * 8), int(((vY + vH) - y) * 8)
        line = f"{seq[0]} {p} {xf} {yf} {int(vW * 8)} {int(vH * 8)}"
        if wire == "new":
            line += f" {int(vX * 8)} {int(vY * 8)}"
        sock.sendto(line.encode(), ("127.0.0.1", 47800))
        seq[0] += 1
        time.sleep(0.008)

    def stroke(x0, y0, x1, y1, steps=25):
        for i in range(4):
            send(0, x0, y0)                       # hover in first
        for i in range(steps + 1):
            t = i / steps
            send(2500, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t)
        for i in range(4):
            send(0, x1, y1)                       # lift
        time.sleep(0.25)                          # past the DLL's tip debounce

    if "--hover" in a:
        for i in range(8):
            send(0, cx, cy)
        time.sleep(0.15)
    elif "--tap" in a:
        for i in range(6):
            send(0, cx, cy)
        for i in range(6):
            send(2500, cx, cy)
        for i in range(6):
            send(0, cx, cy)
        time.sleep(0.3)
    else:
        stroke(cx - size, cy, cx + size, cy)
        stroke(cx, cy - size, cx, cy + size)
        send(0, cx, cy)
    if "--quiet" not in a:
      print(f"drew + at global ({cx:.0f},{cy:.0f}) on display {did}, wire={wire}, "
            f"union origin({vX:.0f},{vY:.0f}) size {vW:.0f}x{vH:.0f}")


if __name__ == "__main__":
    main()
