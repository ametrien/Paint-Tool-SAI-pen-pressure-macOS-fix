# Canvas timelapse — design plan

Status: **planning / Phase 0**. Branch: `feature/canvas-timelapse`.

Goal: record a timelapse of a SAI session by reading SAI's canvas out of memory, so the
video shows the **true flat canvas** — no UI, no zoom, no pan, no rotation — with one frame
per brush stroke.

Prior art: [cromachina/art-timelapse](https://github.com/cromachina/art-timelapse) does this
on Windows/Linux by reading `sai2.exe` from **outside** the process. That project is GPL-3.0;
this one is MIT. See [Licensing](#licensing) — we do not copy its offset table.

---

## Why our approach differs

art-timelapse reads SAI from another process, and pays for it: `task_for_pid`, a debugger
entitlement, Screen Recording and Accessibility grants, region scanning to find the module
base, and global mouse hooks to guess when a stroke ended.

We already run code **inside** `sai2.exe` — `wintab32.dll` is loaded by SAI as its tablet
driver. From in there:

- reading the canvas is a plain pointer dereference — no mach VM, no entitlement, no prompt;
- the module base is `GetModuleHandle(NULL)`, one call, no region scanning;
- we *are* the input path, so pen-up is known exactly rather than inferred.

The cost of being in-process: a bad pointer crashes SAI and can destroy unsaved artwork.
That single fact drives most of the safety design below.

---

## MVP definition

**Done when:** drawing in SAI for 10 minutes with `WT_TIMELAPSE=1` produces a playable `.mov`
in `~/Movies/SAI Timelapse/` showing the artwork building up — one frame per stroke, full flat
canvas, no UI, correct colours — and SAI never crashes. Feature off by default.

**Non-goals for MVP:** no GUI, no export/resample pass, no multi-canvas selection, no PSD
mode, no pause/resume, no layer isolation, one SAI build supported.

---

## Architecture

```
┌──────────────── sai2.exe (under Wine) ─────────────────┐
│  SAI canvas tile tree                                   │
│         ▲ in-process read (memcpy behind a seam)        │
│  wintab32.dll                                           │
│    ├─ existing: pressure producer thread (UDP 47800)    │
│    └─ NEW timelapse.c   [own thread, opt-in, SEH-guarded]
│         ├─ stroke-end trigger (pressure → 0, debounced) │
│         ├─ walk base + session_offset → canvas          │
│         ├─ pick mip level, stitch 256×256 tiles         │
│         ├─ dedup hash (drops undo/pan/no-op strokes)    │
│         └─ write frame file, atomic rename              │
└─────────────────────────┬───────────────────────────────┘
                          │  frames dir in the prefix
                          ▼
        ┌──── sai-timelapse-encoder (Swift, separate binary) ────┐
        │  watch dir → AVAssetWriter (H.264) → segmented .mov    │
        └─────────────────────────────────────────────────────────┘
```

Separate encoder **process**, not a module in the helper: the helper's job is realtime input,
and an encoder doing GPU work and disk I/O alongside it invites jitter on the pressure path.
It also means the encoder can be tested standalone against a folder of synthetic frames.

---

## Derived offsets — sai2.exe Alpha.2026.07.27

MD5 `96b7a5b218b6953647405874528936e1`. Derived independently with
`tools/sai-offset-scan` against a live process (see [Licensing](#licensing)) — **not** copied
from art-timelapse, whose newest entry is the 2026.07.12 build.

| | Value |
|---|---|
| PE image base | `0x140000000` (`SizeOfImage 0x51d000`) — confirmed |
| `session_offset` | `0x471380` — confirmed; holds a pointer to the canvas list head |

> **How the anchor was confirmed.** A structural scan (`--canvases`) found three canvas
> objects, but the walk from `0x471380` reached only two — `NewCanvas2` had every link field
> zero. That looked like a broken walk. It wasn't: `NewCanvas2` had been **closed** earlier in
> the session and its object simply hadn't been freed yet. With only `anotheronecanvasss`
> actually open, the two-node list `ScratchPad1 → anotheronecanvasss` is complete.
>
> Also tested and rejected along the way: that `+0x010`/`+0x018` are a separate "user canvas"
> chain. They are zero on every canvas in this build.
>
> **Lesson for the reader:** a canvas object existing in memory does not mean it is open.
> Enumerate via the list; never by scanning for canvas-shaped objects.

Canvas struct layout:

| Field | Offset | How it was verified |
|---|---|---|
| `next_canvas` | `+0x000` | 3-node walk reaching both open documents |
| `prev_canvas` | `+0x008` | backward links consistent with forward |
| `width` | `+0x028` | three canvases at different sizes |
| `height` | `+0x02c` | three canvases at different sizes |
| `tile_maps[11]` | `+0x048` | 11 consecutive clustered pointers = 11 mip levels |
| `tile_count_x` | `+0x180` | 1×4, 6×3, 31×1 — all match `ceil(dim/256)` |
| `tile_count_y` | `+0x184` | as above |
| *(dims copy)* | `+0x170` | second width/height copy; useful for the sanity guard |
| `name` (UTF-16LE) | `+0x8f8` | three canvases with different names |

`tile_maps[i]` needs **two** dereferences: the field holds an address, which holds the address
of the tile map itself.

`SAICanvasTileMap` layout:

| Field | Offset | Notes |
|---|---|---|
| allocator / vtable | `+0x00` | points into the image (`image+0x256940`) |
| `tree` | `+0x08` | 2-level pointer tree of tiles |
| `width` / `height` | `+0x10` / `+0x14` | dimensions *at this mip level* |
| `count_x` / `count_y` | `+0x18` / `+0x1c` | tile grid at this level |
| tile size | `+0x20` / `+0x24` | `(256, 256)` — **read it, don't hardcode** |
| tile shift | `+0x28` / `+0x2c` | `(8, 8)` = log2(256) |

Confirming canvases, chosen for awkward geometry so a match cannot be coincidence:

| Canvas | Size | Tile grid |
|---|---|---|
| `ScratchPad1` | 199 × 878 | 1 × 4 |
| `anotheronecanvasss` | 1291 × 579 | 6 × 3 |
| `NewCanvas4` | 7777 × 33 | 31 × 1 |
| `NewCanvas1` | 99 × 12121 | 1 × 48 |
| `ahahahahii8ii` | 3331 × 779 | 14 × 4 |

**Phase 0 is complete.** Every offset needed to walk the canvas list and read pixels is
derived and verified.

Node `[0]` of the list is SAI's internal `ScratchPad1`, not a user document — skip it, the
same way art-timelapse's `collect_canvases(...)[1:]` does.

Four further statics (`0x4711d8`, `0x471388`, `0x471390`, `0x471398`) point at the *current*
canvas rather than the list head. Useful later for "record the active canvas", not for
enumeration.

**Still unverified:** the tile map fields (`tile_maps` around `+0x048`, tile counts around
`+0x180`/`+0x184`). Those are only needed once we read pixels, and are the next thing to
confirm.

---

## Phase 0 — the probe (gate)

Three assumptions are unverified. This phase tests all three cheaply, and is the only phase
where "it doesn't work" is a real possibility.

Behind `WT_TIMELAPSE_PROBE=1`, from inside the DLL:

1. `GetModuleHandle(NULL)` → log base address. **A:** Wine returns the `sai2.exe` PE base.
2. Walk `base + session_offset` → canvas list. **B:** offsets are right for this SAI build.
3. Log **canvas name + width/height only**. No pixel data.

Pass condition: logged name matches the open document, dimensions match
*Canvas → Change Resolution*.

Reuses the existing `log_line` / `wtlog.txt` infrastructure — no new plumbing.

### Deriving offsets ourselves

Dev-only mode `WT_TIMELAPSE_SCAN=1`. Being in-process makes this far easier than a normal
external pointer scan:

- open a canvas at a deliberately unique size (e.g. 1237 × 569);
- scan writable regions for that `int32` pair adjacent in memory → candidate canvas structs;
- scan for pointers to those, then static pointers to those → the session chain;
- subtract module base → `session_offset`.

Keeps us clean of the GPL table, and keeps paying off every SAI release.

**Note:** the 2026-07-12 Technical Preview (our primary target) has a canvas layout that
*diverges* from older builds. Design the table for per-build **field layouts** from day one,
not one integer per build.

---

## Phase 1 — canvas reader

**Status: done.** Files as built:

| File | Contents |
|---|---|
| `wintab-src/timelapse_core.h` | Pure logic — no Win32, no I/O. 40 tests, no SAI needed. |
| `wintab-src/timelapse_win.h` | Win32 glue: validated read, capture thread, frame files. |
| `tests/test_timelapse_core.c` | Synthetic address space; wired into `run-tests.sh`. |

Two deviations from the design, both forced:

**The glue is a header, not `timelapse.c`.** The build command is written out in
`README.md`, `CONTRIBUTING.md`, `TESTING.md`, `.github/workflows/build.yml` and the header of
`wintab32.c`. A second translation unit would need adding to all five, and whichever was
missed would hand somebody a link error. Included by `wintab32.c` instead, exactly as
`wintab_core.h` already is.

**`sai_offsets.ini` deferred.** Offsets are a `TLC_LAYOUT` struct for now — still data rather
than scattered constants, so moving it to a file later is mechanical. Not worth the file I/O
and parser inside SAI's process until there is a second build to support.

**Testability seam.** Every memory access goes through:

```c
typedef int (*read_fn)(void *ctx, uint64_t addr, void *dst, size_t len);
```

Production: a validated `memcpy` (we're in-process). Tests: a synthetic address space built
with `malloc`. This makes the whole tile walk unit-testable with no SAI, no Wine, no tablet —
same philosophy as `wintab_core.h`.

In `timelapse_core.h` (all pure, all tested): offset-table parsing, canvas plausibility
validation, mip-level selection, tile-tree walk and stitch, dedup hash, stroke debounce.

### Safety layers

Unlike art-timelapse, a bad pointer here kills SAI and unsaved work.

- **Opt-in** — `WT_TIMELAPSE=1`, default off (same convention as `WT_NO_CLICK_DEDUP`).
- **Validate before every read** — `VirtualQuery`; require committed + readable. An external
  reader gets a harmless error on a bad pointer; in-process we get an access violation, so
  this check is doing real work.
- **~~SEH backstop~~ — not possible.** `__try`/`__except` is an MSVC extension;
  `x86_64-w64-mingw32-gcc` rejects it (verified, not assumed). The defence is therefore
  inverted: rather than catching faults we make them impossible, via the `VirtualQuery`
  validation above plus the core's plausibility guards. A vectored exception handler
  (`AddVectoredExceptionHandler`, which *does* work) latches the feature off if a fault ever
  occurs, but does not attempt to resume — recovering would mean `longjmp` out of a VEH
  (undefined) or rewriting `RIP`, and adding a fragile mechanism to guard a case validated
  reads already prevent is a bad trade. `tl: FAULT` in the log is the signal to revisit.
- **Fault latch** — on any fault or failed check: log, disable permanently, never retry.
- **Plausibility caps** — dimensions in range, `count_x * count_y` under a ceiling, tile
  pointers non-null. A wrong `session_offset` must fail these, not walk garbage.
- **Dedicated thread** — never SAI's UI thread, never the pressure producer thread.

### Trigger

Stroke-end = pressure returns to zero past a debounce. Must respect the existing latch
behaviour in `PressureCore` (mid-stroke pressure dip), or one stroke becomes five frames.

### Cost control

Smallest mip level above target (default 1024 px), then hash to drop no-op strokes — undo,
pan and toolbar clicks produce byte-identical canvases and must never reach disk.

---

## Phase 2 — transport: file drop

DLL writes raw BGRA + small header into a frames dir in the prefix, as `.tmp` then **atomic
rename** so the consumer never sees a partial file.

Chosen over TCP for the MVP: no protocol, no connection lifecycle, no backpressure logic (the
filesystem is the buffer), survives an encoder restart, and debuggable by opening the file.
~2–3 MB per frame at 1024 px; the consumer deletes as it goes. Cap the dir, drop oldest if the
consumer stalls. TCP on 47801 is the optimisation if churn becomes real — not yet.

---

## Phase 3 — encoder

New Swift binary `sai-timelapse-encoder`, built alongside the helper in `make-app.sh`.

Watch frames dir → `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`, H.264, BGRA in
directly. PTS synthetic: `CMTime(value: frameIndex, timescale: 30)`. One captured frame = one
output frame; that *is* the timelapse compression.

**Segment rollover matters more than it looks:** an `AVAssetWriter` never given
`finishWriting()` is unplayable, so a crash loses the whole session rather than the tail. Roll
a new segment every ~500 frames. Round dimensions to even (H.264 requirement).

No new macOS permissions — reading a folder and writing to `~/Movies` needs nothing. A quiet
advantage over screen capture, which would have needed a Screen Recording grant (see the TCC
notes in `make-app.sh`).

---

## Testing

Third suite in `tests/run-tests.sh`: `tests/test_timelapse_core.c`, under ASan/UBSan like the
existing C tests. Against a synthetic address space:

- stitch a known 3×2 tile grid → exact pixel layout, including crop to `width`/`height` and
  the alpha drop;
- mip selection returns the smallest level above target;
- dedup: identical canvas → no frame;
- stroke debounce: normal stroke; mid-stroke pressure dip must **not** split; hover-only emits
  nothing; rapid taps;
- plausibility: absurd `count_x * count_y` is rejected.

For each: verify the test genuinely fails when the guard is removed, and leave a comment in the
code naming the trap it protects.

---

## Risk register

| # | Risk | Mitigation |
|---|---|---|
| 1 | Offsets wrong or unfindable | Phase 0 gates everything; scanner is the durable answer |
| 2 | Reader crashes SAI, loses artwork | Opt-in + `VirtualQuery` + SEH + fault latch + caps |
| 3 | `GetModuleHandle(NULL)` wrong under Wine | Covered by Phase 0 |
| 4 | Tile read stalls drawing | Separate thread; mip level; dedup before write |
| 5 | SAI update breaks offsets | Table in editable `.ini`, not compiled in |
| 6 | GPL contamination | Independently derived offsets, method documented |
| 7 | Disk churn | Bounded frames dir, drop oldest |

---

## Licensing

art-timelapse is **GPL-3.0**; this repo is **MIT**. We do not copy its offset table or struct
definitions. Offsets are derived independently via `WT_TIMELAPSE_SCAN`, and the method is
documented here so the provenance is clear.

---

## Order of work

1. Phase 0 probe → decision gate.
2. Offset scanner (if the probe needs it).
3. `timelapse_core.h` + tests against the synthetic address space — no SAI involved.
4. Wire into `timelapse.c`; dump one real frame; verify BGRA order and stride by eye.
5. Mip selection + dedup; confirm undo/pan produce nothing.
6. Encoder binary, standalone against synthetic frames.
7. End-to-end run; harden guards; docs + CHANGELOG.

Steps 1 and 4 hold the genuine unknowns. Everything after step 3 is testable without a tablet
or Wine.
