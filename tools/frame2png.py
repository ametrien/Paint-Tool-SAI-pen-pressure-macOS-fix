#!/usr/bin/env python3
"""frame2png.py — turn a raw .frame dumped by the timelapse recorder into a PNG.

DEV TOOL. The shipping pipeline hands BGRA straight to AVAssetWriter without a
conversion; this exists so a frame can be eyeballed during bring-up ("is this
actually my drawing, and are the colours right?").

    python3 tools/frame2png.py <in.frame> [out.png]

Header layout mirrors TL_FRAME_HDR in wintab-src/timelapse_win.h.
"""
import struct
import sys
import zlib
from pathlib import Path

HDR = struct.Struct("<8sIIIIQQ")   # magic, w, h, stride, format, seq, tick_ms


def write_png(path, width, height, rgb_rows):
    """Minimal PNG writer — avoids depending on Pillow just to look at a frame."""
    raw = b"".join(b"\x00" + row for row in rgb_rows)      # filter type 0 per row

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6))
    png += chunk(b"IEND", b"")
    Path(path).write_bytes(png)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_suffix(".png")

    blob = src.read_bytes()
    magic, w, h, stride, fmt, seq, tick = HDR.unpack_from(blob, 0)
    magic = magic.rstrip(b"\x00").decode("ascii", "replace")
    print(f"{src.name}: magic={magic!r} {w}x{h} stride={stride} format={fmt} "
          f"seq={seq} tick={tick}ms")
    if magic != "SAITLF1":
        print("  !! unexpected magic — wrong file or the header layout drifted")
        return 1

    px = blob[HDR.size:]
    want = stride * h
    if len(px) < want:
        print(f"  !! truncated: have {len(px)} bytes, need {want}")
        return 1

    # BGRA -> RGB. If the image comes out looking colour-swapped, THIS is the
    # line to question before suspecting the reader: SAI stores BGRA and that is
    # what the tile walk copies through untouched.
    rows = []
    for y in range(h):
        row = px[y * stride: y * stride + w * 4]
        rows.append(bytes(b for i in range(0, len(row), 4)
                          for b in (row[i + 2], row[i + 1], row[i])))
    write_png(dst, w, h, rows)
    print(f"  wrote {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
