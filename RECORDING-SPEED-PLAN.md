# Recording speed plan (follow-up to issue #39)

Make timelapse recording cheap enough that drawing feels the same with it on as with it off,
especially with *Sharp text on Retina screens* turned on.

This plan is written for implementing agents. Follow it in order. Every line reference was checked
against `main` at commit `f4d9aa3` (the 0.3.8 release); re-check before editing if `main` has moved.

---

## 1. What we know (measured) and what we suspect (not measured)

**Measured** on Anastasia's MacBook Pro (M3 Pro), laptop screen only, Retina on, same kind of
scribbling, read from the bridge counters (`recv` = pen points our DLL received, `posted` = points
handed to SAI; the difference is points the DLL had to merge because SAI was too busy to take them):

| Session              | recv | posted | merged          |
|----------------------|------|--------|-----------------|
| Recording **on**     | 1211 | 1109   | 102 (**8%**)    |
| Recording **off**    | 1316 | 1310   | 6 (**0.5%**)    |

Merging happens when SAI has 3 points it has not picked up yet (`POST_WINDOW` in
`wintab-src/wintab32.c:230`, rule in `wtc_should_post`, `wintab-src/wintab_core.h:266`). So with
recording on, SAI's own thread is busy often enough to fall behind the pen. Anastasia also felt
strokes were quicker with recording off.

**Not measured.** Which part of recording costs. Suspects, from reading the code:

1. **Timing.** A capture starts about 0.27 s after each stroke ends (150 ms debounce + 120 ms
   settle), so during quick scribbles it usually runs while the next stroke is being drawn.
2. **Memory checks.** Before every read of SAI's memory, `tl_range_readable` calls `VirtualQuery`
   unless the read falls in the one cached range. Each tile costs two reads (tile pointer, tile
   pixels) in different allocations, so the one-entry cache keeps missing: likely hundreds of
   `VirtualQuery` calls per capture. In Wine this may take a process-wide memory lock that SAI's
   thread also needs when it allocates memory.
3. **File handling.** Create, write 3 MB, close, rename per frame. File create/rename go through
   `wineserver`, which also delivers every window message SAI receives, including our pen points.
4. **Fingerprint.** `tlc_hash` walks the whole ~3 MB frame one byte at a time (~10 ms under
   Rosetta). It runs on our own thread, so it probably does not block SAI.

Do not state any of these as the cause in commits, comments or the changelog until the timing
from package 1 shows it.

---

## 2. How recording works today (where to edit)

All recording code runs inside SAI's process, in our DLL.

| What | Where |
|---|---|
| Pure, natively tested core (no Windows headers allowed) | `wintab-src/timelapse_core.h` |
| Windows side, `#include`d into `wintab32.c` (single translation unit) | `wintab-src/timelapse_win.h` |
| Unit tests for the core (compiled with `cc -Wall -Wextra -Werror` + ASan/UBSan) | `tests/test_timelapse_core.c` |
| Test runner | `tests/run-tests.sh` |

Key spots in `wintab-src/timelapse_win.h`:

- `tl_range_readable` (line 119): `VirtualQuery` walk with a single cached range `g_tl_ok_lo/hi`
  (line 117). **That cache is never cleared**, see the safety note in package 3.
- `tl_read` (147): range check, then `memcpy`.
- `tl_veh` (157): vectored exception handler. It only **logs and disables** recording and returns
  `EXCEPTION_CONTINUE_SEARCH`, so a fault in our thread is **not handled**: it would take SAI down.
  The only real protection is never reading memory that is not readable.
- `tl_capture_once` (336): pick canvas, pick mip level, `tlc_read_level`, `tlc_hash` of the whole
  frame, per-canvas dedup slot (`g_tl_seen`, `TL_MAX_TRACKED` = 8), `tl_enforce_budget`, `tl_write_frame`.
- `tl_thread` (396): waits on `g_tl_evt` (auto-reset event, created at 518), then
  `Sleep(TL_SETTLE_MS)` (120), then `tl_capture_once()`.
- `tl_on_pressure` (452): feeds `tlc_stroke_update` (debounce `TL_DEFAULT_DEBOUNCE` = 150 ms) and
  sets the event when a stroke ends.
- `tl_on_mouse_up` (474): sets the event immediately (needed for mouse/trackpad users; pen taps
  also produce mouse-ups).
- `tl_startup` (480): reads env vars, creates the event and the thread (520), logs one
  `tl: recording enabled ...` line.

Callers in `wintab-src/wintab32.c`:

- Producer thread (ours, not SAI's): `tl_on_pressure(s.press)` for every pen sample (~1017), and
  `tl_on_pressure(0)` on the ~10 Hz idle tick (~1038). Hover samples have pressure 0.
- Click hook on SAI's UI thread: `tl_on_mouse_up()` on `WM_LBUTTONUP` (~884). Keep it cheap.
- `log_line` (153) writes only when DLL logging is on (Developer mode). Log file: `C:\wtlog.txt`,
  i.e. `~/SAI2-pressure/drive_c/wtlog.txt` on the Mac. **It is overwritten each time SAI starts.**

In `wintab-src/timelapse_core.h`: `tlc_tilemap_read` (213), `tlc_pick_level` (248),
`tlc_read_level` (283), `tlc_hash` (335, FNV-1a, byte at a time), `TLC_SLOT` / `tlc_hash_slot` (371),
`TLC_STROKE` / `tlc_stroke_update` (~410 / 421).

In `tests/test_timelapse_core.c`: `fake_read` (37, strict fake address space), `build_canvas` (78,
builds a canvas with a tile map, a tile pointer tree and optional hole tile), stroke tests (~168).

**The DLL binary is committed** (`wintab-src/wintab32.dll`) and the release workflow does not
rebuild it: whatever is committed ships. After changing the DLL source, rebuild it (section 5) and
commit the new binary together with the source.

---

## 3. Ground rules for implementing agents

- **Never launch SAI, Wine GUI apps or the app, never move the cursor or inject input.**
  Anastasia does all device testing. Prepare builds and instructions; she runs them.
- **Tests must be thorough and explicit**, and each must be **proven to fail**: temporarily
  reintroduce the bug it guards against, run it, see it fail, restore. Put a comment at each
  fragile spot naming what breaks if it is changed (look at the existing `THE TRAP` comments in
  `wintab-src/wintab_core.h` and `wintab-src/timelapse_core.h` for the house style).
- Keep `timelapse_core.h` portable C with no Windows headers; it is compiled natively by the tests.
- Keep the single-translation-unit build (`timelapse_win.h` is included, not compiled separately).
- Work on a branch: `git switch -c faster-recording` from an up-to-date `main`.
  **Do not commit or push unless Anastasia asks.**
- Packages 2, 3 and 4 all edit the same three files. **Run them one after another**, not in
  parallel. Each package ends with `bash tests/run-tests.sh` passing.
- No user-visible text changes are planned. If any are needed: short, plain words, no em dashes.

---

## 4. Work packages (in order)

### Package 1: timing in the log (do first)

Goal: every capture logs where its time went, so the effect of each later package is measured,
not guessed.

In `timelapse_win.h`:

- Add a microsecond clock using `QueryPerformanceCounter` / `QueryPerformanceFrequency`.
- Add a per-capture counter `g_tl_vq_calls`, incremented in `tl_range_readable` for every
  `VirtualQuery` call. Reset it at the start of each capture.
- In `tl_capture_once`, time: the read (tile map + tiles), the fingerprint, the write (budget +
  `tl_write_frame`), and the total. `tl_thread` passes in how long the capture waited after its
  trigger (0 for now; package 2 makes this real).
- Log exactly one line per capture, after the existing `tl: frame ...` / `tl: no pixel change`
  line, in this format (keep it grep-friendly):

  ```
  tl: capture waited=1012ms read=14.2ms hash=9.8ms write=6.1ms total=31.0ms tiles=12/192 vq=37 verify=0 result=written
  ```

  `tiles=read/total` (until package 4 every tile is read), `verify` is 0 until package 4,
  `result` is one of `written`, `nochange`, `failed`.

No unit tests for this package (it is Win32 timing), but the DLL must build cleanly.

**Optional checkpoint:** build the DLL and a test app (section 5) with only this package, and ask
Anastasia for one baseline session (section 6). That gives "before" numbers for each step.

### Package 2: capture only when the pen rests

Goal: never capture while someone is drawing. Capture once the pen has rested for a moment.

**Core** (`timelapse_core.h`), add:

```c
/* Milliseconds to wait before capturing, or 0 to capture now.
 *   now, last_activity, pending_since: GetTickCount() values (wrap-safe, unsigned subtraction)
 *   pen_down: 1 while the pen is pressing
 *   quiet_ms: how long the pen must rest
 *   max_wait_ms: after this long pending, capture at the next moment the pen is up,
 *                even without a full rest, so nonstop drawing still gets frames */
static uint32_t tlc_capture_wait(uint32_t now, uint32_t last_activity, uint32_t pending_since,
                                 int pen_down, uint32_t quiet_ms, uint32_t max_wait_ms);
```

Rules:

1. `pen_down` → never 0. Return a short poll interval (`TLC_CAPTURE_POLL_MS`, 50).
2. `now - last_activity >= quiet_ms` → 0.
3. `now - pending_since >= max_wait_ms` (and pen up) → 0.
4. Otherwise return the smaller of the two remaining times.

All differences are `uint32_t` subtractions so the 49.7-day `GetTickCount` wrap is harmless.

**Windows side** (`timelapse_win.h`):

- Globals: `static volatile LONG g_tl_last_activity;` and `static volatile LONG g_tl_pen_down;`.
- `tl_on_pressure(press)`: if `press > 0`, `InterlockedExchange` the current `GetTickCount()` into
  `g_tl_last_activity` and set `g_tl_pen_down = 1`; otherwise set `g_tl_pen_down = 0`.
  **Do not** treat pressure 0 as activity: the idle tick calls `tl_on_pressure(0)` ten times a
  second and hover samples have pressure 0. Keep the existing `tlc_stroke_update` call unchanged
  (it is still the trigger). This runs on the hot path, so nothing heavier than one tick read and
  one interlocked write.
- `tl_on_mouse_up()`: also record `g_tl_last_activity` (mouse and trackpad users).
- `tl_thread` new loop:

  ```c
  for (;;) {
      DWORD w = WaitForSingleObject(g_tl_evt, g_tl_interval ? g_tl_interval : INFINITE);
      if (w != WAIT_OBJECT_0 && w != WAIT_TIMEOUT) break;
      if (g_tl_disabled) break;
      if (w == WAIT_TIMEOUT) {                 /* WT_TIMELAPSE_INTERVAL test aid: old behaviour */
          Sleep(TL_SETTLE_MS); tl_capture_once(0); continue;
      }
      DWORD pending_since = GetTickCount();
      for (;;) {                               /* wait until the pen rests */
          if (g_tl_disabled) return 0;
          uint32_t rem = tlc_capture_wait(GetTickCount(), (uint32_t)g_tl_last_activity,
                                          pending_since, (int)g_tl_pen_down,
                                          g_tl_quiet_ms, g_tl_max_wait_ms);
          if (!rem) break;
          Sleep(rem);
      }
      /* Triggers that arrived while we waited are covered by this capture: it reads the
       * canvas after all of them. Clear the auto-reset event so they do not cause a second,
       * pointless capture straight after. */
      WaitForSingleObject(g_tl_evt, 0);
      tl_capture_once(GetTickCount() - pending_since);
  }
  ```

- Defaults: `g_tl_quiet_ms = 1000` (env `WT_TIMELAPSE_QUIET_MS`, accept 0 to 10000; values below
  `TL_SETTLE_MS` are raised to it, so SAI always has time to finish compositing), and
  `g_tl_max_wait_ms = 10000` (env `WT_TIMELAPSE_MAX_WAIT_MS`, accept 1000 to 120000). Add both to
  the `tl: recording enabled` line.

**Tests** (in `tests/test_timelapse_core.c`):

- Rested long enough → 0; just under → the exact remainder; exactly at `quiet_ms` → 0.
- Activity during the wait pushes the capture back (simulate: trigger, activity 400 ms later,
  check the wait is measured from the activity).
- `pen_down` always returns non-zero, **even past `max_wait_ms`** (the forced capture must never
  happen mid-stroke).
- Past `max_wait_ms` with pen up → 0 even though the rest is shorter than `quiet_ms`.
- Wrap: `now` just after 0, `last_activity` / `pending_since` just before `UINT32_MAX`.
- Replay: 5 s of strokes every 300 ms (300 ms pressure, 0 between), then a 2 s rest. Step time in
  10 ms ticks. Assert no capture fires while any stroke is in progress, and exactly one fires
  about 1000 ms into the rest.
- Replay: 30 s of nonstop strokes with only 100 ms gaps. Assert captures fire at most once per
  `max_wait_ms` and only at pen-up moments.

Prove: remove the `pen_down` guard from the forced path → the "never mid-stroke" tests fail; use a
signed or `>` comparison → the wrap or boundary test fails.

### Package 3: fewer memory checks

Goal: answer "is this readable?" from memory already checked, instead of asking Wine every time.

**Core**, add a small region cache:

```c
#define TLC_REGION_SLOTS 32
typedef struct { uint64_t lo[TLC_REGION_SLOTS], hi[TLC_REGION_SLOTS]; uint32_t n, next; } TLC_REGIONS;
static void tlc_regions_clear(TLC_REGIONS *r);
/* 1 if [addr, addr+len) lies entirely inside ONE cached region [lo, hi). Overflow-safe. */
static int  tlc_regions_covers(const TLC_REGIONS *r, uint64_t addr, size_t len);
/* Remember [lo, hi). Ignores lo >= hi and exact duplicates. When full, replaces round-robin. */
static void tlc_regions_add(TLC_REGIONS *r, uint64_t lo, uint64_t hi);
```

**Windows side:**

- Replace `g_tl_ok_lo/hi` with `static TLC_REGIONS g_tl_regions;`.
- `tl_range_readable`: if `tlc_regions_covers` → 1. Otherwise do the existing `VirtualQuery` walk
  unchanged, and `tlc_regions_add` **every** region it accepts (committed, readable, not a guard
  page), not only a region that covers the whole read.
- **Safety: clear the cache at the start of every capture** (`tlc_regions_clear` at the top of
  `tl_capture_once`). Today's single cached range is never cleared, so after SAI frees that memory
  a later capture would `memcpy` from it, fault, and (because `tl_veh` does not handle the fault)
  crash SAI with the drawing unsaved. Clearing per capture limits that window to the few
  milliseconds of one capture, which is no worse than the gap between `VirtualQuery` and `memcpy`
  that always existed. Write this as a `THE TRAP` comment at the clear.

**Tests:**

- Covers: fully inside; touching the end exactly (`addr + len == hi` → covered); one byte past
  (not covered); straddling two adjacent cached regions (not covered, so it falls back to
  `VirtualQuery`); `len == 0`; `addr + len` overflowing near `UINT64_MAX` (not covered, no wrap).
- Add: rejects `lo >= hi`; ignores duplicates; when full, the oldest entry is replaced and the
  newest are still found; `clear` forgets everything.

Prove: make the end check inclusive (`<= hi` on the last byte) → the "one byte past" test fails;
drop the overflow check → the overflow test fails.

### Package 4: skip unchanged tiles (with a safety check)

Goal: read only the tiles that changed since the last capture of the same canvas.

**Hypothesis (unverified):** when SAI changes a tile it gives it a new memory block (likely
copy-on-write for undo), so a tile whose pointer has not changed has not changed. If that is false
for some tool, skipping by pointer would record stale tiles. The design below stays correct
either way: it checks the hypothesis while recording and stops skipping if it is ever wrong.

**Core**, add:

```c
typedef struct {
    uint64_t  canvas;        /* what the cache describes; ntiles == 0 means empty */
    int       level;
    uint32_t  width, height, tile_w, tile_h, count_x, count_y, ntiles;
    uint64_t *ptr;           /* caller-owned, cap entries: tile pointer at last read (0 = hole) */
    uint64_t *hash;          /* caller-owned, cap entries: hash of the tile's VISIBLE pixels */
    uint32_t  cap;
} TLC_TILECACHE;

typedef struct {
    uint32_t tiles_total, tiles_read, tiles_skipped, inplace_changes;
    int      full;           /* 1 if every tile was read (first read, canvas/level/size change) */
    uint64_t frame_hash;     /* hash of the per-tile hash array: the new dedup fingerprint */
} TLC_READSTATS;

static int tlc_read_level_incremental(TLC_READ_FN rd, void *ctx, const TLC_LAYOUT *L,
        uint64_t canvas, int level, uint8_t *dst, size_t dst_cap,
        uint8_t *tile_scratch, size_t scratch_cap,
        TLC_TILECACHE *cache, int verify,
        uint32_t *out_w, uint32_t *out_h, TLC_READSTATS *st);
```

Algorithm:

1. `tlc_tilemap_read`; same size checks as `tlc_read_level`.
2. `full` if the cache is empty, or canvas, level, width, height, tile size or tile counts differ,
   or `count_x * count_y > cap`. A full read rewrites every pixel of `dst`.
3. For each tile, in the same order as `tlc_read_level` (read the row pointer, then the tile
   pointer; reading a whole row of tile pointers with one `rd` call is a good optional saving):
   - **Hole** (pointer 0): fill the visible part with `0xff`, as today; tile hash is a fixed
     constant `TLC_HOLE_HASH`. If not `full` and the cached pointer is also 0, count it as skipped.
   - **Same pointer, not `full`, not `verify`:** skip. Its pixels in `dst` are still there from the
     last read. `tiles_skipped++`.
   - **Otherwise:** read the tile, copy its visible part into `dst`, hash the **visible part only**
     (`cw` bytes x 4 per row for `chh` rows; never the padding past the canvas edge, which can hold
     anything and would make every capture look changed). `tiles_read++`. If not `full`, the
     pointer equals the cached one and the hash differs, then `inplace_changes++` (the hypothesis
     was wrong for this tile).
   - Store the pointer and hash in the cache.
4. `frame_hash` = FNV-1a over the per-tile hash array (`ntiles * 8` bytes). This replaces the full
   frame hash for dedup, so a pointer that changed while the pixels did not still counts as no change.
5. On success fill the cache's description fields and return 1.
6. **On any failure, set `cache->ntiles = 0` before returning 0.** Otherwise the next capture would
   skip tiles whose pixels in `dst` were never written. `THE TRAP` comment here.

Add a row-aware hash helper (`tlc_hash_init` / `tlc_hash_update`) so visible rows can be hashed
without copying; keep `tlc_hash` unchanged for its existing users.

**Windows side:**

- Keep one `TLC_TILECACHE` for the last captured canvas. Grow its `ptr` / `hash` arrays on demand
  (like `tl_ensure_buf`). `g_tl_frame` must not be shared with anything else, because skipped
  tiles rely on the previous frame still being in it.
- In `tl_capture_once`, call `tlc_read_level_incremental` instead of `tlc_read_level`, and use
  `st.frame_hash` for the per-canvas dedup slot instead of `tlc_hash(g_tl_frame, ...)`. The slots
  only live in memory, so changing what they hold needs no migration.
- **Verify policy:** `verify = 1` for the first 5 captures of a session (`TL_VERIFY_FIRST`), then
  every 10th capture (`TL_VERIFY_EVERY`), and always once pointers are known to be unreliable.
- If `st.inplace_changes > 0`: set `g_tl_ptrs_unreliable = 1` for the session and log once:
  `tl: SAI changed N tile(s) in place; reading every tile from now on`. That frame is already
  correct (verify read every tile); every later capture reads every tile.
- Log `tiles=read/total` and `verify=` in the package 1 timing line.

**Tests** (fake address space; wrap `fake_read` in a counting reader that records how many reads
and bytes were requested):

1. First read is `full` and its frame is byte-identical to `tlc_read_level` on the same canvas.
2. Second read with nothing changed, `verify = 0`: zero tiles read, all skipped, same `frame_hash`,
   `dst` unchanged, and the counting reader saw only tile map and pointer reads.
3. Copy-on-write change (new block with new pixels, pointer swapped for one tile): exactly one tile
   read, frame byte-identical to `tlc_read_level` of the new state, `frame_hash` changed.
4. Pointer swapped, same pixels: one tile read, `frame_hash` unchanged (no new frame).
5. In-place change (same pointer, new bytes): with `verify = 0` the frame is stale (assert it,
   with a comment: this is the trap the verify pass exists for); with `verify = 1`,
   `inplace_changes == 1` and the frame is correct.
6. Holes: a tile becoming 0 turns white; 0 becoming a tile shows the tile.
7. Canvas switch, level switch, size change: each forces `full`.
8. Failure mid-read (a tile pointer pointing outside the fake memory): returns 0 and the cache is
   empty; after fixing the pointer, the next read is `full` and correct.
9. Padding: garbage in a partial edge tile's invisible padding changes between reads → no change
   reported.
10. Sweep: 200 random steps of copy-on-write changes, hole toggles and identical swaps with
    `verify = 0`; after every step the incremental frame equals a fresh `tlc_read_level` frame.

Prove: always skip (ignore the pointer comparison) → tests 3 and 10 fail; skip the invalidation on
failure → test 8 fails; hash the whole tile including padding → test 9 fails; let `verify` still
skip → test 5 fails.

### Package 5: lower the capture thread's priority

- In `tl_startup`, right after `CreateThread` succeeds:
  `SetThreadPriority(g_tl_thread, THREAD_PRIORITY_LOWEST)`. Log whether it succeeded, on the
  `tl: recording enabled` line.
- Not `THREAD_PRIORITY_IDLE`: with the pen resting, captures should still happen promptly.
- Whether Wine on macOS turns this into a real macOS priority is unknown. It is harmless either
  way; the package 1 timing shows whether it changes anything.
- No unit test (Win32 call). The DLL must build cleanly.

---

## 5. Build and package

From the repo root:

```bash
bash tests/run-tests.sh
```

Rebuild the DLL (same command as `.github/workflows/build.yml`):

```bash
cd wintab-src && x86_64-w64-mingw32-windres wintab32.rc -O coff -o wintab32_res.o && x86_64-w64-mingw32-gcc -shared -O2 -o wintab32.dll wintab32.c wintab32_res.o wintab32.def -lgdi32 -luser32 -lws2_32 -municode && cd ..
```

Build a **separate test app** (its own name and bundle ID, so macOS keeps its Input Monitoring
permission apart from the installed release, which must not be replaced):

```bash
SAIPP_VERSION=0.3.9-test SAIPP_APP_NAME="SAI Pen Pressure Retina Test" SAIPP_BUNDLE_ID=app.saipenpressure.mac.retinatest UNIVERSAL=0 bash make-app.sh
```

The result is `dist/SAI Pen Pressure Retina Test.app`. When it launches SAI it copies its own
DLL into the Wine prefix (`syncBridgeDLL`); opening the regular app afterwards copies the release
DLL back. Hand the test app to Anastasia with the steps in section 6. Do not open it yourself.

---

## 6. Device test (Anastasia runs this)

1. Laptop screen only: no mirroring, no AirPlay. Plugged in.
2. In the test app: Developer mode on (DLL log), recording on, *Sharp text on Retina screens* on.
3. Start SAI from the test app. Draw about a minute of quick scribbles with a few pauses.
4. Quit SAI. Before starting it again (the log is overwritten on start), tell the agent, or copy
   the problem report.

The agent then reads `~/SAI2-pressure/drive_c/wt_status.txt` and
`~/SAI2-pressure/drive_c/wtlog.txt` and reports:

- **Merged points:** `(recv - posted) / recv`. Before: 8% with recording on, 0.5% off.
  Target: close to the recording-off number.
- From the `tl: capture` lines: typical `waited`, `read`, `hash`, `write`, `total`, `vq`, and
  `tiles` read versus total.
- Whether `tl: SAI changed N tile(s) in place` appeared (if so, package 4 cannot skip tiles for
  this SAI build; packages 2 and 3 still help).
- Whether the session's timelapse video looks right: frames at the pauses, the final image
  complete, no patches of old drawing.
- How strokes felt compared to recording off.

---

## 7. Success criteria

- With recording and Retina on, merged points are near the recording-off level (about 1% or less),
  and strokes feel like recording off.
- No capture runs while the pen is pressing (check `waited` against stroke times in the log).
- Timelapse videos are still complete and correct.
- `bash tests/run-tests.sh` passes, including the new tests, each proven to fail without its fix.

## 8. Out of scope (for now)

- **A faster fingerprint.** After package 4 only changed tiles are hashed, so it barely matters.
- **Encoder priority.** The encoder is a separate macOS process that checks for frames once a
  second; lowering its priority is cheap, but it was not part of this request.
- **Passing frames through shared memory instead of 3 MB files**, if package 1 shows writing is
  still expensive after packages 2 to 5.
- **The Retina frame-copy cost itself** (Wine copying SAI's whole window). A separate investigation.
