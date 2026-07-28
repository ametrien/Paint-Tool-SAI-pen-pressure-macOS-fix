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

/* Pick the SMALLEST mip level still at least `target` px on a side.
 *
 * This is the main cost control: for a 1024px timelapse frame of a 4000px
 * canvas we read roughly a sixteenth of the memory. Level 0 is always a valid
 * answer, so a canvas smaller than the target simply returns 0. */
static int tlc_pick_level(TLC_READ_FN rd, void *ctx, const TLC_LAYOUT *L,
                          uint64_t canvas, uint32_t target) {
    int best = 0, i;
    int limit = (int)L->c_map_count;
    if (limit > TLC_MAX_LEVELS) limit = TLC_MAX_LEVELS;
    for (i = 0; i < limit; i++) {
        TLC_TILEMAP tm;
        if (!tlc_tilemap_read(rd, ctx, L, canvas, i, &tm)) break;
        if (tm.width < target && tm.height < target) break;
        best = i;
    }
    return best;
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

#endif /* TIMELAPSE_CORE_H */
