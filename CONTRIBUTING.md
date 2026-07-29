# Contributing

Thanks for helping bring pen pressure to PaintTool SAI on macOS! This is a small,
practical project — contributions of all sizes are welcome, especially **testing on
hardware I don't have**.

## Ways to help (most useful first)

- **Test on other tablets / Macs** and report results in an Issue: your tablet model,
  macOS version, Mac chip, and whether pressure + hover + mouse coexistence work. The bridge
  reads *standard* tablet events, so many non-Wacom WinTab tablets should work — but only USB
  Wacom + Apple Silicon is verified so far.
- **Tilt / rotation support** — currently only pressure is forwarded (the test tablet has no
  tilt). Adding tilt means reading the tablet's tilt fields in the helper and putting them in
  the WinTab packet.
- **The Wine window focus bug** — after app-switching, SAI's window can get stuck ignoring
  input (a `winemac.drv` issue; workaround is a Spaces swipe). A real fix would likely be a
  Wine-side patch. Ideas/patches welcome.
- **An app icon** and README screenshots/GIFs.
- Docs, typos, clearer setup steps.

## Reporting a bug / requesting a feature

Open an **Issue**. For bugs, include: what you did, what happened, tablet + macOS + Mac model,
and — if drawing-related — turn on logging and attach the log:
```bash
# helper console:
WT_VERBOSE=1 ./wacom-helper/wacom-pressure-helper
# DLL log (writes <prefix>/drive_c/wtlog.txt):
WT_DEBUG=1 bash ./launch-sai2-pressure.sh
```

## Submitting a change (Pull Request)

1. **Fork** this repo and clone your fork.
2. Create a branch: `git checkout -b my-fix`.
3. Make your change and **build + test it** (see below).
4. Commit, push to your fork, and open a **Pull Request** against `main`.
5. Describe what it does and how you tested it. Small, focused PRs get merged fastest.

## Building & testing

You need: **Wine** (Gcenx Staging in `/Applications`), your own **SAI2** + license, a **tablet**,
plus `mingw-w64` (for the DLL) and Xcode command-line tools (for the helper).

```bash
# custom wintab32.dll
cd wintab-src
x86_64-w64-mingw32-gcc -shared -O2 -o wintab32.dll wintab32.c wintab32_res.o wintab32.def \
    -lgdi32 -luser32 -lws2_32 -municode

# native helper
cd ../wacom-helper && swiftc -O -o wacom-pressure-helper main.swift PressureCore.swift

# the .app wrapper
bash make-app.sh
```
Then install the DLL into your prefix and run the helper + SAI (see the README), and **draw**
to confirm your change end-to-end. Please don't submit drawing-behaviour changes you haven't
tested with a real pen.

## Style / philosophy

- **Keep it simple and dependency-free.** The whole point is a tiny, auditable bridge — plain
  C for the DLL, plain Swift for the helper, no frameworks.
- Match the surrounding code; comment *why*, not *what*.
- Don't commit anything proprietary: never add SAI binaries, installers, or `.slc` licenses
  (the `.gitignore` blocks these — keep it that way).

## Legal

Contributions are accepted under this project's **MIT License**. PaintTool SAI itself is
proprietary (SYSTEMAX); this project never includes it. By submitting a PR you agree your
contribution may be distributed under MIT.
