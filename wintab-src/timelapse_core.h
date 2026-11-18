/*
 * timelapse_core.h — the PURE logic of the canvas timelapse reader, extracted
 * so it can be unit-tested natively (clang on macOS, no mingw, no Wine, no SAI,
 * no tablet). timelapse.c includes this and keeps only the OS glue (threads,
 * SEH, VirtualQuery, file output).
 *
 * Everything here is deterministic input -> output. If you change behaviour
 * here, add/adjust a case in tests/test_timelapse_core.c.
 *
 * ---------------------------------------------------------------------------
 * THE READ SEAM — why every memory access goes through a function pointer
 * ---------------------------------------------------------------------------
 * In production this code runs INSIDE sai2.exe (wintab32.dll is loaded by SAI
 * as its tablet driver), so a "remote" read is really just a memcpy. It could
 * therefore have been written as plain pointer dereferences — and that version
 * would be completely untestable, because exercising it would require a running
 * SAI with a canvas open.
 *
 * Routing reads through TLC_READ_FN buys two things:
 *
 *   1. Tests build a synthetic address space in malloc'd memory and point the
 *      reader at it. The whole tile walk is then verifiable under ASan with no
 *      SAI involved — which is how most of this file was developed.
 *   2. Production supplies a VALIDATED read (VirtualQuery first, then memcpy).
 *      That distinction matters far more in-process than out: an external
 *      reader gets a harmless error return on a bad pointer, but in-process a
 *      bad pointer is an access violation that takes SAI — and the artist's
 *      unsaved work — down with it.
 *
 * A read function returns 1 on success, 0 on failure. EVERY caller must check.
 * On failure the reader's contract is to fail the whole operation, never to
 * continue with partially-populated data.
 *
 * ---------------------------------------------------------------------------
 * OFFSETS ARE DATA, NOT CONSTANTS
 * ---------------------------------------------------------------------------
 * SAI moves these every release, so they live in a TLC_LAYOUT table rather than
 * being baked into the code. A new build should be a table entry (ultimately a
 * line in sai_offsets.ini), never a code change. Derive new values with
 * tools/sai-offset-scan; see TIMELAPSE-PLAN.md.
 */
#ifndef TIMELAPSE_CORE_H
#define TIMELAPSE_CORE_H

#include <stdint.h>
#include <string.h>
#include <stdio.h>     /* snprintf, for tlc_format_status */

/* ---------------------------------------------------------------------------
 * Sanity ceilings. These are GUARDS, not facts about SAI: their job is to turn
 * "the offsets are wrong for this build" into a clean refusal instead of a walk
 * through garbage pointers. Prefer rejecting a legitimate monster canvas over
 * dereferencing rubbish inside SAI's process.
 * ------------------------------------------------------------------------- */
#define TLC_MAX_DIM    100000   /* px per side; SAI's own limit is far lower  */
#define TLC_MAX_TILES  65536    /* count_x * count_y                          */
#define TLC_MAX_LEVELS 16       /* mip levels we will consider                */

/* Level-0 tile size, used ONLY by the plausibility check to cross-validate the
 * tile counts against the canvas dimensions. The actual size used for reading
 * is read from the tile map at +0x20 (SAI states it explicitly), so a build that
 * changes it still reads correctly — it would merely trip this guard and disable
 * the feature, which is the failure mode we want. */
#define TLC_TILE_ASSUMED 256

typedef int (*TLC_READ_FN)(void *ctx, uint64_t addr, void *dst, size_t len);

/* Field offsets for one SAI build. Verified values for the build we target are
 * in TLC_LAYOUT_2026_07_27 below. */
typedef struct {
    uint64_t session_offset;   /* image_base + this -> pointer to list head    */

    /* SAICanvas */
    uint32_t c_next;           /* next_canvas                                  */
    uint32_t c_prev;           /* prev_canvas                                  */
    uint32_t c_width;
    uint32_t c_height;
    uint32_t c_tile_maps;      /* array of map_count entries                   */
    uint32_t c_map_count;      /* how many mip levels the array holds          */
    uint32_t c_tile_count_x;
    uint32_t c_tile_count_y;
    uint32_t c_name;           /* UTF-16LE                                     */

    /* SAICanvasTileMap */
    uint32_t t_tree;           /* -> rows -> tiles                             */
    uint32_t t_width;
    uint32_t t_height;
    uint32_t t_count_x;
    uint32_t t_count_y;
    uint32_t t_tile_w;
    uint32_t t_tile_h;
} TLC_LAYOUT;

/* sai2.exe Ver.2 (64bit) Alpha.2026.07.27, md5 96b7a5b218b6953647405874528936e1.
 * Derived with tools/sai-offset-scan against a live process and confirmed on
 * five canvases of deliberately awkward geometry (99x12121, 7777x33, 3331x779,
 * 1291x579, 199x878) so the tile-grid match could not be coincidence. */
static const TLC_LAYOUT TLC_LAYOUT_2026_07_27 = {
    /* session_offset */ 0x471380,
    /* c_next        */ 0x000,
    /* c_prev        */ 0x008,
    /* c_width       */ 0x028,
    /* c_height      */ 0x02c,
    /* c_tile_maps   */ 0x048,
    /* c_map_count   */ 11,
    /* c_tile_count_x*/ 0x180,
    /* c_tile_count_y*/ 0x184,
    /* c_name        */ 0x8f8,
    /* t_tree        */ 0x08,
    /* t_width       */ 0x10,
    /* t_height      */ 0x14,
    /* t_count_x     */ 0x18,
    /* t_count_y     */ 0x1c,
    /* t_tile_w      */ 0x20,
    /* t_tile_h      */ 0x24,
};

/* --- small typed reads ---------------------------------------------------- */

static int tlc_u32(TLC_READ_FN rd, void *ctx, uint64_t addr, uint32_t *out) {
    return rd(ctx, addr, out, 4);
}
static int tlc_u64(TLC_READ_FN rd, void *ctx, uint64_t addr, uint64_t *out) {
    return rd(ctx, addr, out, 8);
}

static uint32_t tlc_ceil_div(uint32_t a, uint32_t b) {
    return b ? (a + b - 1) / b : 0;
}

/* --- canvas -------------------------------------------------------------- */

typedef struct {
    uint64_t addr;
    int32_t  width, height;
    uint32_t tile_count_x, tile_count_y;
} TLC_CANVAS;

/* Is this address plausibly a SAICanvas?
 *
 * This is the guard that stands between a wrong session_offset and a walk
 * through arbitrary memory inside SAI's process. It must reject confidently:
 * returning 1 for a non-canvas means the reader proceeds to dereference
 * whatever the "tile tree" pointer happens to contain.
 *
 * The strongest single signal is that the tile counts equal ceil(dim/256).
 * A struct that merely happens to hold two plausible int32s at +0x28 will
 * almost never also hold their exact tile-grid at +0x180 — during offset
 * derivation the navigator panel cached the canvas dimensions and would have
 * passed a dimensions-only check. See tests/test_timelapse_core.c. */
static int tlc_canvas_read(TLC_READ_FN rd, void *ctx, const TLC_LAYOUT *L,
                           uint64_t addr, TLC_CANVAS *out) {
    uint32_t w = 0, h = 0, cx = 0, cy = 0;
    if (!addr) return 0;
    if (!tlc_u32(rd, ctx, addr + L->c_width,        &w))  return 0;
    if (!tlc_u32(rd, ctx, addr + L->c_height,       &h))  return 0;
    if (!tlc_u32(rd, ctx, addr + L->c_tile_count_x, &cx)) return 0;
    if (!tlc_u32(rd, ctx, addr + L->c_tile_count_y, &cy)) return 0;

    if ((int32_t)w <= 0 || w > TLC_MAX_DIM) return 0;
    if ((int32_t)h <= 0 || h > TLC_MAX_DIM) return 0;
    if (cx == 0 || cy == 0) return 0;
    if ((uint64_t)cx * (uint64_t)cy > TLC_MAX_TILES) return 0;
    if (cx != tlc_ceil_div(w, TLC_TILE_ASSUMED)) return 0;
    if (cy != tlc_ceil_div(h, TLC_TILE_ASSUMED)) return 0;

    out->addr = addr;
    out->width = (int32_t)w; out->height = (int32_t)h;
    out->tile_count_x = cx;  out->tile_count_y = cy;
    return 1;
}

/* Head of the canvas list. NOTE: node [0] is SAI's internal ScratchPad, not a
 * user document — callers enumerating open documents must skip it. */
static int tlc_list_head(TLC_READ_FN rd, void *ctx, const TLC_LAYOUT *L,
                         uint64_t image_base, uint64_t *out) {
    return tlc_u64(rd, ctx, image_base + L->session_offset, out);
}

static int tlc_canvas_next(TLC_READ_FN rd, void *ctx, const TLC_LAYOUT *L,
                           uint64_t canvas, uint64_t *out) {
    return tlc_u64(rd, ctx, canvas + L->c_next, out);
}

/* Canvas name as ASCII (SAI stores UTF-16LE). Non-ASCII code units become '?'
 * — this is for logging and matching, never for display. Always NUL-terminates
 * when cap > 0. */
static int tlc_canvas_name(TLC_READ_FN rd, void *ctx, const TLC_LAYOUT *L,
                           uint64_t canvas, char *out, size_t cap) {
    size_t i;
    if (!cap) return 0;
    out[0] = 0;
    for (i = 0; i + 1 < cap; i++) {
        uint16_t u = 0;
        if (!rd(ctx, canvas + L->c_name + i * 2, &u, 2)) return 0;
        if (!u) break;
        out[i] = (u >= 32 && u < 127) ? (char)u : '?';
    }
    out[i] = 0;
    return 1;
}

/* --- tile maps ----------------------------------------------------------- */

typedef struct {
    uint64_t tree;
    uint32_t width, height;
    uint32_t count_x, count_y;
    uint32_t tile_w, tile_h;
} TLC_TILEMAP;

/* tile_maps[level] holds an address which holds the address of the tile map:
 * two dereferences, not one. */
static int tlc_tilemap_read(TLC_READ_FN rd, void *ctx, const TLC_LAYOUT *L,
                            uint64_t canvas, int level, TLC_TILEMAP *out) {
    uint64_t slot = 0, tm = 0;
    if (level < 0 || (uint32_t)level >= L->c_map_count) return 0;
    if (!tlc_u64(rd, ctx, canvas + L->c_tile_maps + (uint32_t)level * 8, &slot)) return 0;
    if (!slot) return 0;
    if (!tlc_u64(rd, ctx, slot, &tm)) return 0;
    if (!tm) return 0;

    if (!tlc_u64(rd, ctx, tm + L->t_tree,    &out->tree))    return 0;
    if (!tlc_u32(rd, ctx, tm + L->t_width,   &out->width))   return 0;
    if (!tlc_u32(rd, ctx, tm + L->t_height,  &out->height))  return 0;
    if (!tlc_u32(rd, ctx, tm + L->t_count_x, &out->count_x)) return 0;
    if (!tlc_u32(rd, ctx, tm + L->t_count_y, &out->count_y)) return 0;
    if (!tlc_u32(rd, ctx, tm + L->t_tile_w,  &out->tile_w))  return 0;
    if (!tlc_u32(rd, ctx, tm + L->t_tile_h,  &out->tile_h))  return 0;

    if (!out->tree) return 0;
    if (out->width == 0 || out->height == 0) return 0;
    if (out->width > TLC_MAX_DIM || out->height > TLC_MAX_DIM) return 0;
    if (out->tile_w == 0 || out->tile_h == 0) return 0;
    if (out->tile_w > 4096 || out->tile_h > 4096) return 0;
    if ((uint64_t)out->count_x * out->count_y > TLC_MAX_TILES) return 0;
    /* The grid must actually cover the level's dimensions, or the stitch would
     * read tiles that do not exist. */
    if (out->count_x != tlc_ceil_div(out->width,  out->tile_w)) return 0;
    if (out->count_y != tlc_ceil_div(out->height, out->tile_h)) return 0;
    return 1;
}

/* --- reading the full canvas, and shrinking it ourselves (2026-11-18) -----
 * SAI's reduced copies (levels 1 and up) are not always drawn: right after a
 * canvas is created they held a dark fill, and once mid-session level 2 went
 * blank and then showed only the newest stroke while the canvas itself was
 * whole. Level 0 is what SAI paints the strokes into, and a session read from
 * it (51 frames, 2026-11-18) had none of that. So recording reads level 0 and
 * shrinks it here to the size the artist chose on the Recording tab.
 *
 * Only a canvas too big to buffer (over max_bytes at level 0) falls back to a
 * reduced level: the smallest step down that fits. */
static int tlc_full_level(TLC_READ_FN rd, void *ctx, const TLC_LAYOUT *L,
                          uint64_t canvas, uint64_t max_bytes) {
    int i, limit = (int)L->c_map_count;
    if (limit > TLC_MAX_LEVELS) limit = TLC_MAX_LEVELS;
    for (i = 0; i < limit; i++) {
        TLC_TILEMAP tm;
        if (!tlc_tilemap_read(rd, ctx, L, canvas, i, &tm)) break;
        if ((uint64_t)tm.width * tm.height * 4u <= max_bytes) return i;
    }
    return 0;   /* nothing fits or nothing reads: the caller's checks refuse it */
}

/* The size a w x h frame is shrunk to: its longer side at most `target`, the
 * same shape, never enlarged. */
static void tlc_shrink_size(uint32_t w, uint32_t h, uint32_t target, uint32_t *ow, uint32_t *oh) {
    if (!target || (w <= target && h <= target)) { *ow = w; *oh = h; return; }
    if (w >= h) {
        *ow = target;
        *oh = (uint32_t)(((uint64_t)h * target + w / 2) / w);
    } else {
        *oh = target;
        *ow = (uint32_t)(((uint64_t)w * target + h / 2) / h);
    }
    if (!*ow) *ow = 1;
    if (!*oh) *oh = 1;
}

/* Shrink a BGRA image by averaging every source pixel that falls in each
 * destination pixel (a box filter). Thin lines stay visible as lighter lines
 * instead of vanishing, which is what plain skipping of pixels would do. Each
 * source pixel is read once. ow and oh must not be larger than w and h. */
static void tlc_downscale_bgra(const uint8_t *src, uint32_t w, uint32_t h,
                               uint8_t *dst, uint32_t ow, uint32_t oh) {
    uint32_t oy, ox, c;
    for (oy = 0; oy < oh; oy++) {
        uint32_t y0 = (uint32_t)((uint64_t)oy * h / oh);
        uint32_t y1 = (uint32_t)((uint64_t)(oy + 1) * h / oh);
        if (y1 <= y0) y1 = y0 + 1;
        for (ox = 0; ox < ow; ox++) {
            uint32_t x0 = (uint32_t)((uint64_t)ox * w / ow);
            uint32_t x1 = (uint32_t)((uint64_t)(ox + 1) * w / ow);
            uint64_t sum[4] = { 0, 0, 0, 0 }, n;
            uint32_t y, x;
            if (x1 <= x0) x1 = x0 + 1;
            for (y = y0; y < y1; y++) {
                const uint8_t *p = src + ((size_t)y * w + x0) * 4u;
                for (x = x0; x < x1; x++, p += 4) {
                    sum[0] += p[0]; sum[1] += p[1]; sum[2] += p[2]; sum[3] += p[3];
                }
            }
            n = (uint64_t)(y1 - y0) * (x1 - x0);
            for (c = 0; c < 4; c++)
                dst[((size_t)oy * ow + ox) * 4u + c] = (uint8_t)((sum[c] + n / 2) / n);
        }
    }
}

/* --- pixels -------------------------------------------------------------- */

/* Stitch one mip level into a tightly-packed BGRA buffer of exactly
 * width x height pixels.
 *
 * BGRA is passed through unconverted on purpose: it is what SAI stores and what
 * AVAssetWriter accepts (kCVPixelFormatType_32BGRA), so the frame crosses the
 * whole pipeline without a colour conversion.
 *
 * Cropping is done during the copy rather than by stitching a padded image and
 * trimming afterwards — the padded buffer for a large canvas is many megabytes
 * that would exist only to be discarded.
 *
 * A NULL tile pointer means SAI has not allocated that tile; it is blank, and
 * we fill it white. Silently leaving such a region uninitialised would produce
 * frames with garbage blocks that look like a decoding bug.
 *
 * `tile_scratch` must hold tile_w * tile_h * 4 bytes. The core allocates
 * nothing: it runs on a thread inside SAI, where a failed allocation mid-stroke
 * is a far worse outcome than a caller-provided buffer.
 */
static int tlc_read_level(TLC_READ_FN rd, void *ctx, const TLC_LAYOUT *L,
                          uint64_t canvas, int level,
                          uint8_t *dst, size_t dst_cap,
                          uint8_t *tile_scratch, size_t scratch_cap,
                          uint32_t *out_w, uint32_t *out_h) {
    TLC_TILEMAP tm;
    uint32_t ty, tx, need_tile;
    size_t need;

    if (!tlc_tilemap_read(rd, ctx, L, canvas, level, &tm)) return 0;

    need = (size_t)tm.width * (size_t)tm.height * 4u;
    if (need > dst_cap) return 0;
    need_tile = tm.tile_w * tm.tile_h * 4u;
    if (need_tile > scratch_cap) return 0;

    for (ty = 0; ty < tm.count_y; ty++) {
        uint64_t row = 0;
        if (!tlc_u64(rd, ctx, tm.tree + (uint64_t)ty * 8, &row)) return 0;

        for (tx = 0; tx < tm.count_x; tx++) {
            uint64_t tile = 0;
            uint32_t x0 = tx * tm.tile_w, y0 = ty * tm.tile_h;
            uint32_t cw, chh, r;

            if (x0 >= tm.width || y0 >= tm.height) continue;
            cw  = tm.width  - x0; if (cw  > tm.tile_w) cw  = tm.tile_w;
            chh = tm.height - y0; if (chh > tm.tile_h) chh = tm.tile_h;

            if (row && tlc_u64(rd, ctx, row + (uint64_t)tx * 8, &tile) && tile) {
                if (!rd(ctx, tile, tile_scratch, need_tile)) return 0;
                for (r = 0; r < chh; r++)
                    memcpy(dst + (((size_t)(y0 + r) * tm.width) + x0) * 4,
                           tile_scratch + (size_t)r * tm.tile_w * 4,
                           (size_t)cw * 4);
            } else {
                for (r = 0; r < chh; r++)
                    memset(dst + (((size_t)(y0 + r) * tm.width) + x0) * 4,
                           0xff, (size_t)cw * 4);
            }
        }
    }
    if (out_w) *out_w = tm.width;
    if (out_h) *out_h = tm.height;
    return 1;
}

/* --- dedup --------------------------------------------------------------- */

/* FNV-1a. Not cryptographic and does not need to be: it only has to distinguish
 * "this stroke changed the canvas" from "it did not", so undo, pan, zoom and
 * toolbar clicks never reach the encoder. */
static uint64_t tlc_hash(const uint8_t *p, size_t n) {
    uint64_t h = 1469598103934665603ULL;
    size_t i;
    for (i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}

/* --- keeping the frame folder bounded ------------------------------------ */

/* Should the frame at `index` (chronological, 0-based) be deleted when the
 * folder is over budget, given `total` frames present?
 *
 * Frames are raw BGRA at roughly 3 MB each, so a long session would otherwise
 * fill a disk. The obvious response — delete the oldest — is the wrong one: it
 * eats the START of the drawing, which is the part worth watching. Deleting
 * every SECOND frame halves the size while still spanning the whole session at
 * coarser granularity, and can repeat, each pass halving again.
 *
 * Two rules that are easy to get wrong and impossible to notice by eye:
 *
 *   - the LAST frame is never deleted. It is the current state of the canvas,
 *     and a timelapse missing its final image looks broken rather than coarse.
 *   - below four frames nothing is deleted, because halving a handful of frames
 *     destroys the recording to reclaim almost nothing.
 *
 * This is the only part of the feature that deletes a user's data, which is why
 * it lives here and not inline in the directory walk. See
 * tests/test_timelapse_core.c. */
static int tlc_should_thin(int index, int total) {
    if (total < 4) return 0;
    if (index >= total - 1) return 0;          /* never the newest */
    return (index & 1) != 0;
}

/* --- per-canvas dedup state ---------------------------------------------- */

typedef struct { uint64_t canvas, hash; } TLC_SLOT;

/* Find (or claim) the slot holding the last frame hash for `canvas`.
 *
 * Dedup state MUST be per canvas. A single global last-hash compared each open
 * document against the other, so every switch between two canvases looked like
 * a change and produced a frame, while a genuine no-op stroke straight after a
 * switch could be dropped.
 *
 * When every slot is taken the first is evicted and its hash reset, so the next
 * frame for that canvas is always written rather than compared against another
 * canvas's hash. Worst case is one redundant frame; the alternative — reusing a
 * stale hash — would silently skip a real one. */
static uint64_t *tlc_hash_slot(TLC_SLOT *slots, int count, uint64_t canvas) {
    int i;
    for (i = 0; i < count; i++)
        if (slots[i].canvas == canvas) return &slots[i].hash;
    for (i = 0; i < count; i++)
        if (!slots[i].canvas) { slots[i].canvas = canvas; slots[i].hash = 0; return &slots[i].hash; }
    slots[0].canvas = canvas;
    slots[0].hash = 0;
    return &slots[0].hash;
}

/* --- stroke detection ---------------------------------------------------- */

/* When does a stroke END? We are the tablet driver, so unlike a screen-capture
 * timelapse we do not have to infer this from global mouse events — pressure
 * returning to zero IS the signal.
 *
 * The subtlety is that pressure dips through zero MID-STROKE: a light pass, or
 * a pen lifted slightly while still drawing, reads 0 for a few samples. Ending
 * the stroke there would split one brush stroke into several frames and make
 * the timelapse stutter. So zero must PERSIST for debounce_ms before it counts.
 * The same reasoning drives WT_UP_LATCH in the helper; keep the two in mind
 * together if you tune either.
 *
 * Returns 1 exactly once per completed stroke. */
typedef struct {
    int      pen_down;
    uint32_t last_nonzero_ms;
    uint32_t debounce_ms;
} TLC_STROKE;

static void tlc_stroke_init(TLC_STROKE *s, uint32_t debounce_ms) {
    s->pen_down = 0;
    s->last_nonzero_ms = 0;
    s->debounce_ms = debounce_ms;
}

static int tlc_stroke_update(TLC_STROKE *s, int pressure, uint32_t now_ms) {
    if (pressure > 0) {
        s->pen_down = 1;
        s->last_nonzero_ms = now_ms;
        return 0;
    }
    if (s->pen_down && (uint32_t)(now_ms - s->last_nonzero_ms) >= s->debounce_ms) {
        s->pen_down = 0;
        return 1;
    }
    return 0;
}

/* ===========================================================================
 * RECORDING SPEED (RECORDING-SPEED-PLAN.md). Measured with Retina on: SAI fell
 * behind on 8% of pen points with recording on and 0.5% with it off. The
 * pieces below make a capture wait for the pen to rest, ask Wine about memory
 * far less often, and read only the tiles that changed.
 * ========================================================================= */

/* --- capture scheduling (package 2) -------------------------------------- */

#define TLC_CAPTURE_POLL_MS 50   /* re-check interval while the pen presses */

/* Milliseconds to wait before capturing, or 0 to capture now. All inputs are
 * GetTickCount() values; differences are unsigned, so the 49.7-day wrap is
 * harmless.
 *
 * THE TRAP: never return 0 while the pen presses, not even past max_wait_ms.
 * A capture that runs during a stroke is the lag this whole change removes.
 * max_wait_ms only lets nonstop drawing get a frame at a moment BETWEEN
 * strokes (pen up), without waiting for a full rest. */
static uint32_t tlc_capture_wait(uint32_t now, uint32_t last_activity, uint32_t pending_since,
                                 int pen_down, uint32_t quiet_ms, uint32_t max_wait_ms) {
    uint32_t idle, waited, rem_quiet, rem_max;
    if (pen_down) return TLC_CAPTURE_POLL_MS;
    /* Activity stamped by another thread just after `now` was read would wrap
     * to a huge idle time and look like a long rest. Treat it as "just now". */
    idle   = ((int32_t)(now - last_activity) < 0) ? 0 : now - last_activity;
    waited = ((int32_t)(now - pending_since) < 0) ? 0 : now - pending_since;
    if (idle >= quiet_ms || waited >= max_wait_ms) return 0;
    rem_quiet = quiet_ms - idle;
    rem_max   = max_wait_ms - waited;
    return rem_quiet < rem_max ? rem_quiet : rem_max;
}

/* --- remembered readable memory (package 3) ------------------------------ */

#define TLC_REGION_SLOTS 32

/* Memory areas already confirmed readable, so a read inside one needs no
 * VirtualQuery. The Windows side clears this at the start of EVERY capture;
 * see the trap at that call. */
typedef struct {
    uint64_t lo[TLC_REGION_SLOTS], hi[TLC_REGION_SLOTS];  /* [lo, hi) */
    uint32_t n, next;
} TLC_REGIONS;

static void tlc_regions_clear(TLC_REGIONS *r) { r->n = 0; r->next = 0; }

/* 1 only if all of [addr, addr+len) lies inside ONE remembered area. A read
 * straddling two areas is not covered: it goes back to VirtualQuery, which
 * is slower but never wrong. */
static int tlc_regions_covers(const TLC_REGIONS *r, uint64_t addr, size_t len) {
    uint64_t end;
    uint32_t i;
    if (!len) return 0;
    if (addr > UINT64_MAX - (uint64_t)len) return 0;   /* no wrap past the top */
    end = addr + (uint64_t)len;
    for (i = 0; i < r->n; i++)
        if (addr >= r->lo[i] && end <= r->hi[i]) return 1;
    return 0;
}

/* Remember [lo, hi). Empty or inverted ranges and exact duplicates are
 * ignored; when full, the oldest entry is replaced. */
static void tlc_regions_add(TLC_REGIONS *r, uint64_t lo, uint64_t hi) {
    uint32_t i;
    if (lo >= hi) return;
    for (i = 0; i < r->n; i++)
        if (r->lo[i] == lo && r->hi[i] == hi) return;
    if (r->n < TLC_REGION_SLOTS) {
        r->lo[r->n] = lo; r->hi[r->n] = hi; r->n++;
        return;
    }
    r->lo[r->next] = lo; r->hi[r->next] = hi;
    r->next = (r->next + 1) % TLC_REGION_SLOTS;
}

/* --- reading only changed tiles (package 4) ------------------------------ */

#define TLC_HASH_INIT 1469598103934665603ULL
#define TLC_HOLE_HASH 0x686f6c65686f6c65ULL   /* stands for "no tile here" */

/* FNV-1a, continuable, so a tile's visible rows can be hashed in place. */
static uint64_t tlc_hash_update(uint64_t h, const uint8_t *p, size_t n) {
    size_t i;
    for (i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}

/* What the last successful read of one canvas level saw, per tile. ptr and
 * hash are caller-owned arrays of `cap` entries. ntiles == 0 means empty. */
typedef struct {
    uint64_t  canvas;
    int       level;
    uint32_t  width, height, tile_w, tile_h, count_x, count_y, ntiles;
    uint64_t *ptr;    /* tile block address (0 = hole) */
    uint64_t *hash;   /* hash of the tile's VISIBLE pixels */
    uint32_t  cap;
} TLC_TILECACHE;

typedef struct {
    uint32_t tiles_total, tiles_read, tiles_skipped, inplace_changes;
    int      full;         /* every tile was read */
    uint64_t frame_hash;   /* hash of the per-tile hashes: the dedup fingerprint */
} TLC_READSTATS;

/* Like tlc_read_level, but a tile whose block address is unchanged since the
 * last read of the same canvas level is not read again: its pixels are still
 * in `dst` from last time.
 *
 * This rests on a guess about SAI: that a changed tile gets a NEW block
 * (copy-on-write for undo). If SAI ever changes a block in place, skipping by
 * address would record a stale tile. `verify` reads every tile anyway and
 * counts same-address tiles whose pixels changed in `inplace_changes`, so the
 * caller can stop trusting addresses for the rest of the session.
 *
 * `dst` must be the same buffer, untouched since the last successful call. */
static int tlc_read_level_incremental(TLC_READ_FN rd, void *ctx, const TLC_LAYOUT *L,
                                      uint64_t canvas, int level,
                                      uint8_t *dst, size_t dst_cap,
                                      uint8_t *tile_scratch, size_t scratch_cap,
                                      TLC_TILECACHE *cache, int verify,
                                      uint32_t *out_w, uint32_t *out_h, TLC_READSTATS *st) {
    TLC_TILEMAP tm;
    uint32_t ty, tx, need_tile, n;
    size_t need;
    int full;

    memset(st, 0, sizeof *st);
    if (!tlc_tilemap_read(rd, ctx, L, canvas, level, &tm)) goto fail;
    need = (size_t)tm.width * (size_t)tm.height * 4u;
    if (need > dst_cap) goto fail;
    need_tile = tm.tile_w * tm.tile_h * 4u;
    if (need_tile > scratch_cap) goto fail;
    n = tm.count_x * tm.count_y;
    if (!cache->ptr || !cache->hash || n > cache->cap) goto fail;

    full = !cache->ntiles || cache->canvas != canvas || cache->level != level ||
           cache->width != tm.width || cache->height != tm.height ||
           cache->tile_w != tm.tile_w || cache->tile_h != tm.tile_h ||
           cache->count_x != tm.count_x || cache->count_y != tm.count_y;

    /* THE TRAP: mark the cache empty BEFORE touching anything. If this read
     * fails halfway, `dst` holds a mix of old and new tiles, and a cache that
     * still claimed to describe it would let the next read skip tiles whose
     * pixels were never written. Only a complete read sets ntiles again. */
    cache->ntiles = 0;
    st->full = full;
    st->tiles_total = n;

    for (ty = 0; ty < tm.count_y; ty++) {
        uint64_t row = 0;
        if (!tlc_u64(rd, ctx, tm.tree + (uint64_t)ty * 8, &row)) goto fail;

        for (tx = 0; tx < tm.count_x; tx++) {
            uint32_t i = ty * tm.count_x + tx;
            uint64_t tile = 0, h;
            uint32_t x0 = tx * tm.tile_w, y0 = ty * tm.tile_h;
            uint32_t cw, chh, r;

            if (x0 >= tm.width || y0 >= tm.height) {
                cache->ptr[i] = 0; cache->hash[i] = TLC_HOLE_HASH;
                continue;
            }
            cw  = tm.width  - x0; if (cw  > tm.tile_w) cw  = tm.tile_w;
            chh = tm.height - y0; if (chh > tm.tile_h) chh = tm.tile_h;

            /* Same rule as tlc_read_level: an unreadable or zero tile
             * pointer is a hole, drawn white. */
            if (!row || !tlc_u64(rd, ctx, row + (uint64_t)tx * 8, &tile)) tile = 0;

            if (!tile) {
                if (!full && cache->ptr[i] == 0) { st->tiles_skipped++; continue; }
                for (r = 0; r < chh; r++)
                    memset(dst + (((size_t)(y0 + r) * tm.width) + x0) * 4,
                           0xff, (size_t)cw * 4);
                cache->ptr[i] = 0; cache->hash[i] = TLC_HOLE_HASH;
                continue;
            }
            if (!full && !verify && tile == cache->ptr[i]) { st->tiles_skipped++; continue; }

            if (!rd(ctx, tile, tile_scratch, need_tile)) goto fail;
            /* Hash only what is visible. A partial edge tile's padding past
             * the canvas edge can hold anything; hashing it would make every
             * capture look changed. */
            h = TLC_HASH_INIT;
            for (r = 0; r < chh; r++) {
                const uint8_t *src = tile_scratch + (size_t)r * tm.tile_w * 4;
                memcpy(dst + (((size_t)(y0 + r) * tm.width) + x0) * 4, src, (size_t)cw * 4);
                h = tlc_hash_update(h, src, (size_t)cw * 4);
            }
            st->tiles_read++;
            if (!full && tile == cache->ptr[i] && h != cache->hash[i]) st->inplace_changes++;
            cache->ptr[i] = tile; cache->hash[i] = h;
        }
    }

    st->frame_hash = tlc_hash_update(TLC_HASH_INIT, (const uint8_t *)cache->hash, (size_t)n * 8u);
    cache->canvas = canvas; cache->level = level;
    cache->width = tm.width; cache->height = tm.height;
    cache->tile_w = tm.tile_w; cache->tile_h = tm.tile_h;
    cache->count_x = tm.count_x; cache->count_y = tm.count_y;
    cache->ntiles = n;
    if (out_w) *out_w = tm.width;
    if (out_h) *out_h = tm.height;
    return 1;

fail:
    cache->ntiles = 0;
    return 0;
}

/* ---------------------------------------------------------------------------
 * FINDING THE CANVAS LIST IN A BUILD WE HAVE NO TABLE ENTRY FOR (issue #56)
 * ---------------------------------------------------------------------------
 * Every SAI update moves session_offset, the one place in sai2.exe's own data
 * that holds the address of the canvas list. The canvas fields themselves
 * stayed where they were from Alpha.2026.07.27 to Alpha.2026.10.19. So for an
 * unknown build we look for that one place ourselves instead of needing a new
 * table entry, and the artist does nothing.
 *
 * What makes a slot the list head, and not just any pointer to a canvas:
 *
 *   1. It points at a well-formed list (tlc_list_length): every node passes
 *      tlc_canvas_read, has a level-0 tile map of exactly its own size and a
 *      name, and every node's prev points back at the node before it.
 *   2. Nothing comes before what it points at (tlc_is_list_head). SAI also
 *      keeps statics for the CURRENT canvas (TIMELAPSE-PLAN.md lists four in
 *      07.27). One pointing at an open drawing passes test 1 as a shorter
 *      list, but that drawing's prev is a canvas whose next is the drawing.
 *      Walking from there would skip the drawing as if it were the scratch
 *      pad, which is why this rule exists.
 *   3. Of the slots left, the one with the longest list wins.
 *
 * A "current canvas" static that points at the scratch pad (nothing open yet,
 * or the artist is on the scratch pad) is indistinguishable from the head at
 * that moment: same value. Either then gives the same list, so the lowest
 * such slot is taken. When it later moves to a drawing it fails rule 2, the
 * caller sees that (tlc_is_list_head on every capture) and searches again.
 * ------------------------------------------------------------------------- */

#define TLC_LIST_MAX_NODES 64     /* more open canvases than this is not SAI   */
#define TLC_NAME_MAX_UNITS 260    /* MAX_PATH; SAI's name field is about this  */

/* A canvas that is a full member of a list: it validates, its level-0 tile map
 * is the same size, and it has a non-empty, terminated name. */
static int tlc_canvas_node_ok(TLC_READ_FN rd, void *ctx, const TLC_LAYOUT *L, uint64_t addr) {
    TLC_CANVAS cv;
    TLC_TILEMAP tm;
    uint16_t u = 0;
    uint32_t i;
    if (!tlc_canvas_read(rd, ctx, L, addr, &cv)) return 0;
    if (!tlc_tilemap_read(rd, ctx, L, addr, 0, &tm)) return 0;
    if (tm.width != (uint32_t)cv.width || tm.height != (uint32_t)cv.height) return 0;
    for (i = 0; i < TLC_NAME_MAX_UNITS; i++) {
        if (!rd(ctx, addr + L->c_name + (uint64_t)i * 2, &u, 2)) return 0;
        if (u == 0) break;
        if (u < 32) return 0;                 /* control characters: not a name */
    }
    return i > 0 && i < TLC_NAME_MAX_UNITS;   /* empty or unterminated: no     */
}

/* How many canvases the list starting at `head` holds, or 0 if it is not a
 * well-formed list (a bad node, a prev that does not point back, a loop). */
static int tlc_list_length(TLC_READ_FN rd, void *ctx, const TLC_LAYOUT *L, uint64_t head) {
    uint64_t cur = head, before = 0;
    int n;
    for (n = 0; cur; n++) {
        uint64_t next = 0, prev = 0;
        if (n >= TLC_LIST_MAX_NODES) return 0;   /* a loop, or not SAI's list   */
        if (!tlc_canvas_node_ok(rd, ctx, L, cur)) return 0;
        if (n > 0) {
            if (!tlc_u64(rd, ctx, cur + L->c_prev, &prev) || prev != before) return 0;
        }
        if (!tlc_canvas_next(rd, ctx, L, cur, &next)) return 0;
        before = cur;
        cur = next;
    }
    return n;
}

/* Is `node` the first canvas of its list? True when its prev is empty, or when
 * whatever prev points at does not link forward to it. */
static int tlc_is_list_head(TLC_READ_FN rd, void *ctx, const TLC_LAYOUT *L, uint64_t node) {
    uint64_t prev = 0, prev_next = 0;
    TLC_CANVAS cv;
    if (!tlc_u64(rd, ctx, node + L->c_prev, &prev)) return 0;
    if (!prev) return 1;
    if (!tlc_canvas_read(rd, ctx, L, prev, &cv)) return 1;
    if (!tlc_canvas_next(rd, ctx, L, prev, &prev_next)) return 1;
    return prev_next != node;
}

/* The anchor still holds the head of a well-formed list. Cheap enough to run
 * before every capture: it reads the list the capture walks anyway. */
static int tlc_anchor_ok(TLC_READ_FN rd, void *ctx, const TLC_LAYOUT *L,
                         uint64_t image_base, uint64_t offset) {
    uint64_t head = 0;
    if (!tlc_u64(rd, ctx, image_base + offset, &head) || !head) return 0;
    return tlc_list_length(rd, ctx, L, head) > 0 && tlc_is_list_head(rd, ctx, L, head);
}

enum {
    TLC_FIND_NOTHING   = 0,   /* no slot points at a canvas list              */
    TLC_FIND_FOUND     = 1,   /* one list, and offset is the slot holding it  */
    TLC_FIND_AMBIGUOUS = 2,   /* two different lists of the same length       */
};

typedef struct {
    int      status;          /* TLC_FIND_*                                    */
    uint64_t offset;          /* from image_base, when FOUND                   */
    int      nodes;           /* canvases in that list, scratch pad included   */
    int      slots;           /* slots that held that same head                */
    unsigned long checked;    /* slots looked at, for the log                  */
} TLC_FOUND;

/* Search the 8-byte slots of [lo, hi) ranges (the image's writable data
 * sections) for the list head. `ranges` holds nranges lo/hi pairs. Values that
 * cannot be a heap pointer are skipped before any read, which is most of them. */
static int tlc_find_session(TLC_READ_FN rd, void *ctx, const TLC_LAYOUT *L,
                            uint64_t image_base, uint64_t image_end,
                            const uint64_t *ranges, int nranges, TLC_FOUND *out) {
    uint64_t best_head = 0;
    int r, best = 0, tie = 0;
    memset(out, 0, sizeof *out);
    for (r = 0; r < nranges; r++) {
        uint64_t lo = (ranges[2 * r] + 7) & ~(uint64_t)7, hi = ranges[2 * r + 1], a;
        for (a = lo; a + 8 <= hi; a += 8) {
            uint64_t v = 0;
            int n;
            out->checked++;
            if (!tlc_u64(rd, ctx, a, &v)) continue;
            if (v < 0x10000 || (v & 7) || v >= 0x800000000000ULL) continue;
            if (v >= image_base && v < image_end) continue;   /* canvases live on the heap */
            if (v == best_head) {                 /* another slot, same head   */
                out->slots++;
                continue;
            }
            n = tlc_list_length(rd, ctx, L, v);
            if (n == 0 || n < best || !tlc_is_list_head(rd, ctx, L, v)) continue;
            if (n == best) { tie = 1; continue; }  /* a different list, as long */
            best = n; best_head = v; tie = 0;
            out->offset = a - image_base; out->nodes = n; out->slots = 1;
        }
    }
    if (!best) return out->status = TLC_FIND_NOTHING;
    if (tie) { out->offset = 0; return out->status = TLC_FIND_AMBIGUOUS; }
    return out->status = TLC_FIND_FOUND;
}

/* Is `canvas` one of the open canvases in the list at `head`? A "current
 * canvas" hint is used only when it is: a canvas that was closed but not yet
 * freed still validates on its own (TIMELAPSE-PLAN.md, "How the anchor was
 * confirmed"), and a hint read from the wrong place could point anywhere. */
static int tlc_list_contains(TLC_READ_FN rd, void *ctx, const TLC_LAYOUT *L,
                             uint64_t head, uint64_t canvas) {
    int n;
    for (n = 0; head && n < TLC_LIST_MAX_NODES; n++) {
        uint64_t next = 0;
        if (head == canvas) return 1;
        if (!tlc_canvas_next(rd, ctx, L, head, &next)) return 0;
        head = next;
    }
    return 0;
}

/* --- builds we have checked by hand --------------------------------------
 * Known by two numbers from sai2.exe's PE header, which the DLL reads from
 * memory without opening the file: the link time stamp and SizeOfImage. A
 * known build uses its row; anything else is found by tlc_find_session. A row
 * is also only trusted while tlc_anchor_ok agrees, so a wrong row costs one
 * search, not a silent recording of nothing. */
typedef struct {
    uint32_t    stamp;           /* IMAGE_FILE_HEADER.TimeDateStamp            */
    uint32_t    image_size;      /* IMAGE_OPTIONAL_HEADER.SizeOfImage          */
    uint64_t    session_offset;
    const char *name;
} TLC_KNOWN_BUILD;

static const TLC_KNOWN_BUILD TLC_KNOWN_BUILDS[] = {
    /* md5 96b7a5b218b6953647405874528936e1; see TLC_LAYOUT_2026_07_27 */
    { 0x6a66dba6u, 0x51d000u, 0x471380u, "Alpha.2026.07.27" },
    /* Found by tlc_find_session in a real 10.19 and recorded there
     * (2026-11-18); the same offset art-timelapse uses, found independently. */
    { 0x6ad549f7u, 0x527000u, 0x47a380u, "Alpha.2026.10.19" },
};

static const TLC_KNOWN_BUILD *tlc_known_build(uint32_t stamp, uint32_t image_size) {
    size_t i;
    for (i = 0; i < sizeof TLC_KNOWN_BUILDS / sizeof TLC_KNOWN_BUILDS[0]; i++)
        if (TLC_KNOWN_BUILDS[i].stamp == stamp && TLC_KNOWN_BUILDS[i].image_size == image_size)
            return &TLC_KNOWN_BUILDS[i];
    return NULL;
}

/* --- what the app is told -------------------------------------------------
 * Lines appended to wt_status.txt, so the app can say in words whether
 * recording can see SAI's canvases. Recording failing silently is how a whole
 * evening was lost (issue #56).
 *
 *   tl=off        recording is not on for this SAI
 *   tl=waiting    on, but not looked for yet (no stroke since SAI started)
 *   tl=known      a build in TLC_KNOWN_BUILDS, its row checked out
 *   tl=found      a build we had no row for; the search found the list
 *   tl=none       searched, and no canvas list anywhere: unsupported build
 *   tl=ambiguous  searched, and two lists matched; nothing recorded
 *   tl_offset=0x… the slot in use, for known and found
 */
enum { TLC_TL_OFF, TLC_TL_WAITING, TLC_TL_KNOWN, TLC_TL_FOUND, TLC_TL_NONE, TLC_TL_AMBIGUOUS };

static const char *tlc_tl_state_name(int state) {
    switch (state) {
    case TLC_TL_WAITING:   return "waiting";
    case TLC_TL_KNOWN:     return "known";
    case TLC_TL_FOUND:     return "found";
    case TLC_TL_NONE:      return "none";
    case TLC_TL_AMBIGUOUS: return "ambiguous";
    default:               return "off";
    }
}

/* Same contract as wtc_format_status: the length written, or 0 and an empty
 * string when it does not fit. */
static int tlc_format_status(char *out, size_t cap, int state, uint64_t offset) {
    int n;
    if (!out || cap == 0) return 0;
    if (state == TLC_TL_KNOWN || state == TLC_TL_FOUND)
        n = snprintf(out, cap, "tl=%s\ntl_offset=%#llx\n", tlc_tl_state_name(state),
                     (unsigned long long)offset);
    else
        n = snprintf(out, cap, "tl=%s\n", tlc_tl_state_name(state));
    if (n < 0 || (size_t)n >= cap) { out[0] = '\0'; return 0; }
    return n;
}

#endif /* TIMELAPSE_CORE_H */
