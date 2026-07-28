/*
 * test_timelapse_core.c — unit tests for timelapse_core.h, compiled NATIVELY
 * with clang on macOS — no mingw, no Wine, no SAI, no tablet, no sudo.
 *
 * The reader normally walks structures inside a running sai2.exe. Here we build
 * an equivalent structure in malloc'd memory and point the read seam at it, so
 * the tile walk, the guards and the stitch are all exercised for real. Under
 * ASan an off-by-one in the stitch is a hard failure rather than a wrong pixel
 * nobody notices.
 *
 * Run:  bash tests/run-tests.sh
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../wintab-src/timelapse_core.h"

static int failures = 0;
#define EXPECT(cond, name) do { \
    if (cond) printf("  ok   %s\n", name); \
    else { printf("  FAIL %s  (%s:%d)\n", name, __FILE__, __LINE__); failures++; } \
} while (0)

/* --- a fake address space ------------------------------------------------- */

#define FAKE_ORIGIN 0x100000000ULL
/* Must comfortably exceed session_offset (0x471380), since the test writes the
 * list-head pointer at image_base + session_offset. Sized at 4 MB first, which
 * put that write past the end of the buffer. */
#define FAKE_SIZE   (8u << 20)

typedef struct { uint8_t *buf; size_t len; } FAKE;

/* Deliberately strict: any read that strays outside the mapped range fails
 * rather than being clamped. Production's read does the same via VirtualQuery,
 * and code that ignores a failed read must not pass here either. */
static int fake_read(void *ctx, uint64_t addr, void *dst, size_t len) {
    FAKE *f = (FAKE *)ctx;
    uint64_t off;
    if (addr < FAKE_ORIGIN) return 0;
    off = addr - FAKE_ORIGIN;
    if (off + len > f->len) return 0;
    memcpy(dst, f->buf + off, len);
    return 1;
}

/* Bounds-checked so a test that lays out its fixture wrongly says so, rather
 * than corrupting the heap and failing somewhere unrelated. */
static void fake_bounds(const FAKE *f, uint64_t addr, size_t len, const char *what) {
    if (addr < FAKE_ORIGIN || (addr - FAKE_ORIGIN) + len > f->len) {
        printf("  FAIL fixture wrote outside the fake address space (%s at 0x%llx)\n",
               what, (unsigned long long)addr);
        exit(1);
    }
}
static void put32(FAKE *f, uint64_t addr, uint32_t v) {
    fake_bounds(f, addr, 4, "put32");
    memcpy(f->buf + (addr - FAKE_ORIGIN), &v, 4);
}
static void put64(FAKE *f, uint64_t addr, uint64_t v) {
    fake_bounds(f, addr, 8, "put64");
    memcpy(f->buf + (addr - FAKE_ORIGIN), &v, 8);
}
static void putname(FAKE *f, uint64_t addr, const char *s) {
    size_t i;
    for (i = 0; s[i]; i++) {
        uint16_t u = (uint16_t)(unsigned char)s[i];
        memcpy(f->buf + (addr - FAKE_ORIGIN) + i * 2, &u, 2);
    }
    memset(f->buf + (addr - FAKE_ORIGIN) + i * 2, 0, 2);
}

/* Lay out a canvas whose level-0 tile map is a count_x by count_y grid of
 * tile px tiles, cropped to w x h. Every tile is filled with a distinct byte so
 * the stitch can be checked pixel-by-pixel: tile (tx,ty) is filled with
 * 0x10 + ty*16 + tx. `hole_x`/`hole_y` name one tile whose pointer is left NULL
 * to exercise the blank-tile path (-1 for none). */
static uint64_t build_canvas(FAKE *f, uint64_t at, const char *name,
                             uint32_t w, uint32_t h, uint32_t tile,
                             int hole_x, int hole_y,
                             uint64_t *heap) {
    const TLC_LAYOUT *L = &TLC_LAYOUT_2026_07_27;
    uint32_t cx = tlc_ceil_div(w, tile), cy = tlc_ceil_div(h, tile);
    uint64_t tm, tree, slot;
    uint32_t ty, tx;

    put32(f, at + L->c_width,  w);
    put32(f, at + L->c_height, h);
    put32(f, at + L->c_tile_count_x, cx);
    put32(f, at + L->c_tile_count_y, cy);
    putname(f, at + L->c_name, name);

    /* tile map + its row/tile pointer tree */
    tm   = *heap; *heap += 0x100;
    tree = *heap; *heap += 8 * cy;
    put64(f, tm + L->t_tree, tree);
    put32(f, tm + L->t_width,   w);
    put32(f, tm + L->t_height,  h);
    put32(f, tm + L->t_count_x, cx);
    put32(f, tm + L->t_count_y, cy);
    put32(f, tm + L->t_tile_w,  tile);
    put32(f, tm + L->t_tile_h,  tile);

    for (ty = 0; ty < cy; ty++) {
        uint64_t row = *heap; *heap += 8 * cx;
        put64(f, tree + ty * 8, row);
        for (tx = 0; tx < cx; tx++) {
            uint64_t px;
            if ((int)tx == hole_x && (int)ty == hole_y) { put64(f, row + tx * 8, 0); continue; }
            px = *heap; *heap += (uint64_t)tile * tile * 4;
            put64(f, row + tx * 8, px);
            memset(f->buf + (px - FAKE_ORIGIN), (int)(0x10 + ty * 16 + tx),
                   (size_t)tile * tile * 4);
        }
    }

    /* tile_maps[0] is a pointer to a pointer to the map (two derefs). Higher
     * levels are halved, so tlc_pick_level has a pyramid to choose from. */
    slot = *heap; *heap += 8;
    put64(f, slot, tm);
    put64(f, at + L->c_tile_maps + 0 * 8, slot);
    {
        uint32_t lvl;
        uint32_t lw = w, lh = h;
        for (lvl = 1; lvl < L->c_map_count; lvl++) {
            uint64_t m2, t2, s2;
            uint32_t c2x, c2y, yy;
            lw = lw > 1 ? lw / 2 : 1; lh = lh > 1 ? lh / 2 : 1;
            c2x = tlc_ceil_div(lw, tile); c2y = tlc_ceil_div(lh, tile);
            m2 = *heap; *heap += 0x100;
            t2 = *heap; *heap += 8 * c2y;
            put64(f, m2 + L->t_tree, t2);
            put32(f, m2 + L->t_width,   lw);
            put32(f, m2 + L->t_height,  lh);
            put32(f, m2 + L->t_count_x, c2x);
            put32(f, m2 + L->t_count_y, c2y);
            put32(f, m2 + L->t_tile_w,  tile);
            put32(f, m2 + L->t_tile_h,  tile);
            for (yy = 0; yy < c2y; yy++) put64(f, t2 + yy * 8, 0);  /* blank */
            s2 = *heap; *heap += 8;
            put64(f, s2, m2);
            put64(f, at + L->c_tile_maps + lvl * 8, s2);
        }
    }
    return at;
}

int main(void) {
    const TLC_LAYOUT *L = &TLC_LAYOUT_2026_07_27;
    FAKE f;
    uint64_t heap = FAKE_ORIGIN + 0x10000;
    uint64_t image_base = FAKE_ORIGIN;
    uint64_t head, c1, c2;

    printf("timelapse_core tests:\n");

    f.buf = (uint8_t *)calloc(1, FAKE_SIZE);
    f.len = FAKE_SIZE;
    if (!f.buf) { printf("out of memory\n"); return 1; }

    /* --- stroke detection -------------------------------------------------
     * Pure logic, no memory involved. These decide how many frames a drawing
     * session produces, so they are worth more cases than they look. */
    {
        TLC_STROKE s;
        int fired;

        tlc_stroke_init(&s, 150);
        EXPECT(tlc_stroke_update(&s, 300, 0) == 0, "stroke: pressure down does not fire");
        EXPECT(tlc_stroke_update(&s, 400, 50) == 0, "stroke: still drawing does not fire");
        EXPECT(tlc_stroke_update(&s, 0, 100) == 0, "stroke: zero inside debounce does not fire");
        EXPECT(tlc_stroke_update(&s, 0, 260) == 1, "stroke: zero past debounce fires once");
        EXPECT(tlc_stroke_update(&s, 0, 500) == 0, "stroke: does not fire twice for one stroke");

        /* THE TRAP: pressure dipping through zero mid-stroke. Without the
         * debounce this splits one brush stroke into several frames. Drop
         * debounce_ms to 0 and this case goes red. */
        tlc_stroke_init(&s, 150);
        tlc_stroke_update(&s, 300, 0);
        fired  = tlc_stroke_update(&s, 0, 40);      /* momentary dip */
        fired |= tlc_stroke_update(&s, 250, 80);    /* pressure returns */
        fired |= tlc_stroke_update(&s, 300, 120);
        EXPECT(fired == 0, "stroke: mid-stroke dip through zero does NOT split the stroke");
        EXPECT(tlc_stroke_update(&s, 0, 400) == 1, "stroke: ends once after the dip recovers");

        /* Hovering never touches the canvas, so it must never make a frame. */
        tlc_stroke_init(&s, 150);
        fired  = tlc_stroke_update(&s, 0, 0);
        fired |= tlc_stroke_update(&s, 0, 1000);
        fired |= tlc_stroke_update(&s, 0, 5000);
        EXPECT(fired == 0, "stroke: hover-only never fires");

        tlc_stroke_init(&s, 50);
        tlc_stroke_update(&s, 200, 0);
        EXPECT(tlc_stroke_update(&s, 0, 100) == 1, "stroke: tap 1 fires");
        tlc_stroke_update(&s, 200, 200);
        EXPECT(tlc_stroke_update(&s, 0, 300) == 1, "stroke: tap 2 fires separately");
    }

    /* --- dedup hash ------------------------------------------------------- */
    {
        uint8_t a[64], b[64];
        memset(a, 0xab, sizeof a); memcpy(b, a, sizeof b);
        EXPECT(tlc_hash(a, sizeof a) == tlc_hash(b, sizeof b), "hash: identical buffers match");
        b[37] ^= 0x01;
        EXPECT(tlc_hash(a, sizeof a) != tlc_hash(b, sizeof b), "hash: one flipped bit differs");
    }

    /* --- canvas list + validation ----------------------------------------- *
     * Two canvases with deliberately non-multiple dimensions so the crop path
     * is exercised: 300x140 is a 2x1 grid of 256px tiles with 44px and 116px
     * of waste. */
    c1 = build_canvas(&f, FAKE_ORIGIN + 0x1000, "ScratchPad1", 300, 140, 256, -1, -1, &heap);
    c2 = build_canvas(&f, FAKE_ORIGIN + 0x2000, "MyDrawing",   300, 140, 256,  1,  0, &heap);
    put64(&f, c1 + L->c_next, c2);
    put64(&f, c2 + L->c_next, 0);
    put64(&f, c2 + L->c_prev, c1);
    put64(&f, image_base + L->session_offset, c1);

    EXPECT(tlc_list_head(fake_read, &f, L, image_base, &head) && head == c1,
           "list: head resolves through session_offset");
    {
        TLC_CANVAS cv;
        uint64_t nxt = 0;
        char nm[64];
        EXPECT(tlc_canvas_read(fake_read, &f, L, head, &cv) && cv.width == 300 && cv.height == 140,
               "list: head canvas reads back");
        EXPECT(tlc_canvas_name(fake_read, &f, L, head, nm, sizeof nm) && !strcmp(nm, "ScratchPad1"),
               "list: head is the scratch pad (callers must skip node 0)");
        EXPECT(tlc_canvas_next(fake_read, &f, L, head, &nxt) && nxt == c2, "list: next link walks");
        EXPECT(tlc_canvas_name(fake_read, &f, L, nxt, nm, sizeof nm) && !strcmp(nm, "MyDrawing"),
               "list: second node name");
        EXPECT(tlc_canvas_next(fake_read, &f, L, nxt, &nxt) && nxt == 0, "list: terminates at zero");
    }

    /* --- plausibility guards ---------------------------------------------- */
    {
        TLC_CANVAS cv;
        uint32_t saved = 0;

        EXPECT(!tlc_canvas_read(fake_read, &f, L, 0, &cv), "guard: null address rejected");
        EXPECT(!tlc_canvas_read(fake_read, &f, L, FAKE_ORIGIN + 0x8000, &cv),
               "guard: zeroed memory is not a canvas");
        EXPECT(!tlc_canvas_read(fake_read, &f, L, 0x900000000ULL, &cv),
               "guard: unmapped address fails instead of crashing");

        /* THE TRAP: a struct that merely holds two plausible int32s where the
         * dimensions live. During offset derivation the navigator panel cached
         * the canvas size and looked exactly like this. Only the tile-grid
         * cross-check rejects it — delete the ceil_div comparisons in
         * tlc_canvas_read and this goes green while the reader starts walking
         * whatever a UI struct happens to hold at +0x048. */
        put32(&f, FAKE_ORIGIN + 0x9000 + L->c_width,  300);
        put32(&f, FAKE_ORIGIN + 0x9000 + L->c_height, 140);
        put32(&f, FAKE_ORIGIN + 0x9000 + L->c_tile_count_x, 7);   /* should be 2 */
        put32(&f, FAKE_ORIGIN + 0x9000 + L->c_tile_count_y, 9);   /* should be 1 */
        EXPECT(!tlc_canvas_read(fake_read, &f, L, FAKE_ORIGIN + 0x9000, &cv),
               "guard: plausible dimensions with a wrong tile grid are rejected");

        /* An absurd grid must be refused before it can drive a huge loop. */
        memcpy(&saved, f.buf + (c1 + L->c_tile_count_x - FAKE_ORIGIN), 4);
        put32(&f, c1 + L->c_tile_count_x, 60000);
        EXPECT(!tlc_canvas_read(fake_read, &f, L, c1, &cv),
               "guard: count_x * count_y beyond the ceiling is rejected");
        put32(&f, c1 + L->c_tile_count_x, saved);
        EXPECT(tlc_canvas_read(fake_read, &f, L, c1, &cv), "guard: restored canvas valid again");
    }

    /* --- tile map + mip selection ----------------------------------------- */
    {
        TLC_TILEMAP tm;
        EXPECT(tlc_tilemap_read(fake_read, &f, L, c1, 0, &tm) &&
               tm.width == 300 && tm.height == 140 && tm.count_x == 2 && tm.count_y == 1 &&
               tm.tile_w == 256,
               "tilemap: level 0 reads through both dereferences");
        EXPECT(!tlc_tilemap_read(fake_read, &f, L, c1, -1, &tm), "tilemap: negative level rejected");
        EXPECT(!tlc_tilemap_read(fake_read, &f, L, c1, 99, &tm), "tilemap: level past map_count rejected");

        /* Levels halve: 300x140, 150x70, 75x35, ... */
        EXPECT(tlc_pick_level(fake_read, &f, L, c1, 1000) == 0,
               "mip: target larger than the canvas gives level 0");
        EXPECT(tlc_pick_level(fake_read, &f, L, c1, 100) == 1,
               "mip: picks the smallest level still at or above the target");
        EXPECT(tlc_pick_level(fake_read, &f, L, c1, 300) == 0, "mip: exact-size target stays at 0");
    }

    /* --- the stitch -------------------------------------------------------- */
    {
        static uint8_t dst[300 * 140 * 4];
        static uint8_t scratch[256 * 256 * 4];
        uint32_t w = 0, h = 0;

        EXPECT(tlc_read_level(fake_read, &f, L, c1, 0, dst, sizeof dst,
                              scratch, sizeof scratch, &w, &h) && w == 300 && h == 140,
               "stitch: level 0 succeeds with cropped dimensions");

        /* Tile (0,0) fills x<256, tile (1,0) fills the remaining 44px. If the
         * row stride were taken from the tile rather than the image, the second
         * tile would land in the wrong place — check both sides of the seam. */
        EXPECT(dst[(0 * 300 + 0) * 4] == 0x10, "stitch: first pixel from tile (0,0)");
        EXPECT(dst[(0 * 300 + 255) * 4] == 0x10, "stitch: last pixel before the seam");
        EXPECT(dst[(0 * 300 + 256) * 4] == 0x11, "stitch: first pixel after the seam is tile (1,0)");
        EXPECT(dst[(139 * 300 + 299) * 4] == 0x11, "stitch: bottom-right corner");
        EXPECT(dst[(139 * 300 + 0) * 4] == 0x10, "stitch: bottom-left stays in tile (0,0)");

        /* c2 has tile (1,0) missing: that region must be white, not garbage. */
        EXPECT(tlc_read_level(fake_read, &f, L, c2, 0, dst, sizeof dst,
                              scratch, sizeof scratch, &w, &h),
               "stitch: canvas with an unallocated tile still succeeds");
        EXPECT(dst[(10 * 300 + 0) * 4] == 0x10, "stitch: allocated tile still copied");
        EXPECT(dst[(10 * 300 + 260) * 4] == 0xff && dst[(10 * 300 + 299) * 4] == 0xff,
               "stitch: unallocated tile is filled white, not left uninitialised");

        /* An undersized destination must be refused, not overrun. Without the
         * dst_cap check ASan flags a heap overflow here. */
        EXPECT(!tlc_read_level(fake_read, &f, L, c1, 0, dst, 16,
                               scratch, sizeof scratch, &w, &h),
               "stitch: destination too small is refused");
        EXPECT(!tlc_read_level(fake_read, &f, L, c1, 0, dst, sizeof dst,
                               scratch, 16, &w, &h),
               "stitch: tile scratch too small is refused");
    }

    free(f.buf);
    if (failures) { printf("FAILED: %d test(s)\n", failures); return 1; }
    printf("All timelapse_core tests passed.\n");
    return 0;
}
