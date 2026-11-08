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

/* --- helpers for the recording-speed tests --------------------------------- */

/* Counts reads, so a test can tell a skipped tile (no pixel read) from a read one. */
typedef struct { FAKE *f; unsigned long reads; } COUNTING;
static int counting_read(void *ctx, uint64_t addr, void *dst, size_t len) {
    COUNTING *c = (COUNTING *)ctx;
    c->reads++;
    return fake_read(c->f, addr, dst, len);
}
static uint64_t get64(FAKE *f, uint64_t addr) {
    uint64_t v = 0;
    fake_read(f, addr, &v, 8);
    return v;
}
/* Address of the pointer to tile (tx, ty) at level 0. */
static uint64_t tile_slot(FAKE *f, uint64_t canvas, uint32_t tx, uint32_t ty) {
    TLC_TILEMAP tm;
    if (!tlc_tilemap_read(fake_read, f, &TLC_LAYOUT_2026_07_27, canvas, 0, &tm)) return 0;
    return get64(f, tm.tree + (uint64_t)ty * 8) + (uint64_t)tx * 8;
}
/* A new tile block filled with `color`, the way SAI makes a changed copy. */
static uint64_t new_block(FAKE *f, uint64_t *heap, uint32_t tile, int color) {
    uint64_t px = *heap;
    *heap += (uint64_t)tile * tile * 4;
    fake_bounds(f, px, (size_t)tile * tile * 4, "new_block");
    memset(f->buf + (px - FAKE_ORIGIN), color, (size_t)tile * tile * 4);
    return px;
}
static uint32_t lcg(uint32_t *s) { *s = *s * 1664525u + 1013904223u; return *s >> 8; }

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

    /* --- thinning the frame folder ---------------------------------------
     * The ONLY code in this feature that deletes a user's data, so the rules
     * are pinned rather than eyeballed. */
    {
        int i, deleted, total;

        /* Below four frames, halving destroys the recording to reclaim almost
         * nothing, so nothing is touched. */
        for (total = 0; total < 4; total++) {
            int any = 0;
            for (i = 0; i < total; i++) if (tlc_should_thin(i, total)) any = 1;
            EXPECT(!any, "thin: fewer than four frames are left alone");
        }

        /* Every second frame, counting from the second. */
        EXPECT(!tlc_should_thin(0, 10) && tlc_should_thin(1, 10) &&
               !tlc_should_thin(2, 10) && tlc_should_thin(3, 10) &&
               tlc_should_thin(5, 10) && tlc_should_thin(7, 10),
               "thin: drops every second frame");

        /* THE TRAP: the newest frame is the current state of the canvas. Drop it
         * and the timelapse ends before the drawing does — it looks broken, not
         * merely coarse. Remove the `index >= total - 1` guard and this fails
         * for every odd total. */
        for (total = 4; total <= 21; total++)
            if (tlc_should_thin(total - 1, total)) {
                EXPECT(0, "thin: the newest frame is never deleted");
                break;
            }
        if (total > 21) EXPECT(1, "thin: the newest frame is never deleted");

        /* Roughly halves, and never empties the folder however often it runs —
         * the budget can be exceeded repeatedly in one long session. */
        total = 64;
        for (i = 0; i < 12 && total >= 4; i++) {
            int kept = 0, j;
            for (j = 0; j < total; j++) if (!tlc_should_thin(j, total)) kept++;
            EXPECT(kept < total && kept > 0, "thin: a pass removes some but not all");
            total = kept;
        }
        EXPECT(total >= 2, "thin: repeated passes never empty the folder");

        deleted = 0;
        for (i = 0; i < 100; i++) if (tlc_should_thin(i, 100)) deleted++;
        EXPECT(deleted == 49, "thin: 100 frames lose 49 (half, minus the newest)");
    }

    /* --- per-canvas dedup slots ------------------------------------------- */
    {
        TLC_SLOT slots[4];
        uint64_t *a, *b, *c;
        memset(slots, 0, sizeof slots);

        a = tlc_hash_slot(slots, 4, 0x1000);
        *a = 111;
        EXPECT(tlc_hash_slot(slots, 4, 0x1000) == a, "slots: same canvas returns the same slot");
        EXPECT(*tlc_hash_slot(slots, 4, 0x1000) == 111, "slots: the hash survives the lookup");

        b = tlc_hash_slot(slots, 4, 0x2000);
        /* THE TRAP: sharing one hash between canvases made every switch between
         * two documents look like a change, and could drop a real frame right
         * after a switch. Different canvases must never share a slot. */
        EXPECT(b != a, "slots: a different canvas gets a different slot");
        *b = 222;
        EXPECT(*a == 111 && *b == 222, "slots: canvases do not disturb each other");

        (void)tlc_hash_slot(slots, 4, 0x3000);
        (void)tlc_hash_slot(slots, 4, 0x4000);
        EXPECT(*tlc_hash_slot(slots, 4, 0x1000) == 111, "slots: a full table still finds an existing canvas");

        /* Beyond capacity the first slot is evicted. Its hash MUST reset: a
         * stale hash belonging to another canvas would silently skip a real
         * frame, which is worse than writing one redundant frame. */
        c = tlc_hash_slot(slots, 4, 0x9999);
        EXPECT(*c == 0, "slots: an evicted slot starts with no remembered hash");
        EXPECT(tlc_hash_slot(slots, 4, 0x9999) == c, "slots: the evicting canvas keeps its slot");
    }

    /* --- capture scheduling: only when the pen rests --------------------- */
    {
        uint32_t t, last = 0, pending = 0, n_cap = 0, cap_at[16];
        int down, is_pending = 0, ok_never_mid = 1;

        EXPECT(tlc_capture_wait(2000, 1000, 1000, 0, 1000, 10000) == 0, "rest: exactly quiet_ms -> capture");
        EXPECT(tlc_capture_wait(1999, 1000, 1000, 0, 1000, 10000) == 1, "rest: 1 ms short -> wait 1 ms");
        EXPECT(tlc_capture_wait(1500, 1000, 900, 0, 1000, 10000) == 500, "rest: waits the exact remainder");
        EXPECT(tlc_capture_wait(1500, 1400, 1000, 0, 1000, 10000) == 900,
               "rest: activity during the wait pushes the capture back");
        /* THE TRAP: a capture during a stroke is the lag being removed. */
        EXPECT(tlc_capture_wait(50000, 0, 0, 1, 1000, 10000) == TLC_CAPTURE_POLL_MS,
               "rest: never captures while the pen presses, even past max_wait");
        EXPECT(tlc_capture_wait(12000, 11900, 1000, 0, 1000, 10000) == 0,
               "rest: past max_wait with the pen up -> capture between strokes");
        EXPECT(tlc_capture_wait(200, 0xFFFFFF00u, 0xFFFFFF00u, 0, 1000, 10000) == 544,
               "rest: tick counter wrap measures 456 ms of rest");
        EXPECT(tlc_capture_wait(900, 0xFFFFFF00u, 0xFFFFFF00u, 0, 1000, 10000) == 0,
               "rest: tick counter wrap reaches a full rest");
        EXPECT(tlc_capture_wait(1000, 1005, 1000, 0, 1000, 10000) == 1000,
               "rest: activity stamped just after 'now' counts as no rest yet");

        /* Replay: 5 s of quick strokes (200 ms down, 100 ms up), then a rest. */
        for (t = 0; t <= 7000; t += 10) {
            down = t < 5000 && (t % 300) < 200;
            if (down) last = t;
            if (!down && t < 5000 && (t % 300) == 200 && !is_pending) { is_pending = 1; pending = t; }
            if (is_pending && tlc_capture_wait(t, last, pending, down, 1000, 10000) == 0) {
                if (down) ok_never_mid = 0;
                if (n_cap < 16) cap_at[n_cap] = t;
                n_cap++; is_pending = 0;
            }
        }
        EXPECT(n_cap == 1 && cap_at[0] == 5990,
               "replay: quick scribbles get ONE capture, 1 s after the last stroke");

        /* Replay: 30 s of nonstop strokes with only 100 ms gaps. */
        n_cap = 0; is_pending = 0; last = 0;
        for (t = 0; t <= 30000; t += 10) {
            down = (t % 300) < 200;
            if (down) last = t;
            if (!down && (t % 300) == 200 && !is_pending) { is_pending = 1; pending = t; }
            if (is_pending && tlc_capture_wait(t, last, pending, down, 1000, 10000) == 0) {
                if (down) ok_never_mid = 0;
                if (n_cap < 16) cap_at[n_cap] = t;
                n_cap++; is_pending = 0;
            }
        }
        EXPECT(n_cap >= 2 && n_cap <= 3, "replay: nonstop drawing still gets a frame about every 10 s");
        EXPECT(n_cap >= 2 && cap_at[1] - cap_at[0] >= 10000, "replay: forced frames are at least max_wait apart");
        EXPECT(ok_never_mid, "replay: no capture ever happens while the pen presses");
    }

    /* --- remembered readable memory --------------------------------------- */
    {
        TLC_REGIONS r;
        uint32_t i;
        tlc_regions_clear(&r);
        tlc_regions_add(&r, 0x1000, 0x2000);
        EXPECT(tlc_regions_covers(&r, 0x1000, 0x1000), "regions: a read filling the area exactly is covered");
        EXPECT(tlc_regions_covers(&r, 0x1800, 0x10), "regions: a read inside is covered");
        /* THE TRAP: the end is exclusive. One byte past is memory nobody checked. */
        EXPECT(!tlc_regions_covers(&r, 0x1ff9, 8), "regions: one byte past the end is not covered");
        EXPECT(!tlc_regions_covers(&r, 0xfff, 8), "regions: one byte before the start is not covered");
        tlc_regions_add(&r, 0x2000, 0x3000);
        EXPECT(!tlc_regions_covers(&r, 0x1ffc, 8),
               "regions: a read straddling two areas is not covered (asks Wine again)");
        EXPECT(!tlc_regions_covers(&r, 0x1800, 0), "regions: an empty read is not covered");
        tlc_regions_add(&r, 0xFFFFFFFFFFFFF000ULL, 0xFFFFFFFFFFFFFFFFULL);
        EXPECT(!tlc_regions_covers(&r, 0xFFFFFFFFFFFFFFF0ULL, 0x20),
               "regions: a read wrapping past the top of memory is not covered");
        tlc_regions_clear(&r);
        tlc_regions_add(&r, 0x5000, 0x5000);
        tlc_regions_add(&r, 0x6000, 0x5000);
        EXPECT(r.n == 0, "regions: empty and inverted areas are ignored");
        tlc_regions_add(&r, 0x5000, 0x6000);
        tlc_regions_add(&r, 0x5000, 0x6000);
        EXPECT(r.n == 1, "regions: duplicates are stored once");
        for (i = 1; i <= TLC_REGION_SLOTS; i++) tlc_regions_add(&r, 0x10000ULL * i, 0x10000ULL * i + 0x100);
        EXPECT(!tlc_regions_covers(&r, 0x5000, 8), "regions: when full, the oldest area is replaced");
        EXPECT(tlc_regions_covers(&r, 0x10000ULL * TLC_REGION_SLOTS, 8), "regions: the newest area is kept");
        tlc_regions_clear(&r);
        EXPECT(!tlc_regions_covers(&r, 0x10000ULL * TLC_REGION_SLOTS, 8), "regions: clear forgets everything");
    }

    /* --- reading only changed tiles --------------------------------------- */
    {
        static uint8_t dst[300 * 140 * 4], ref[300 * 140 * 4], scratch[256 * 256 * 4];
        uint64_t ptrs[64], hashes[64];
        TLC_TILECACHE tc;
        TLC_READSTATS st;
        COUNTING cnt;
        uint64_t c3, slot, prev_hash, oldpx;
        uint32_t w = 0, h = 0, rw, rh, seed = 12345, step;
        unsigned long full_reads;
        int ok, sweep_ok = 1;
        const size_t fb = 100 * 70 * 4;

        memset(&tc, 0, sizeof tc);
        tc.ptr = ptrs; tc.hash = hashes; tc.cap = 64;
        cnt.f = &f; cnt.reads = 0;
        c3 = heap; heap += 0x2000;
        build_canvas(&f, c3, "Inc", 100, 70, 32, -1, -1, &heap);   /* 4 x 3 tiles, partial edges */

#define FRESH() tlc_read_level(fake_read, &f, L, c3, 0, ref, sizeof ref, scratch, sizeof scratch, &rw, &rh)
#define INC(v)  tlc_read_level_incremental(counting_read, &cnt, L, c3, 0, dst, sizeof dst, \
                                           scratch, sizeof scratch, &tc, (v), &w, &h, &st)

        cnt.reads = 0;
        ok = INC(0) && FRESH();
        full_reads = cnt.reads;
        EXPECT(ok && st.full && st.tiles_read == 12 && w == 100 && h == 70,
               "tiles: the first read is full");
        EXPECT(ok && !memcmp(dst, ref, fb), "tiles: a full read matches tlc_read_level byte for byte");
        prev_hash = st.frame_hash;

        cnt.reads = 0;
        ok = INC(0);
        EXPECT(ok && !st.full && st.tiles_read == 0 && st.tiles_skipped == 12,
               "tiles: nothing changed -> no tile is read");
        EXPECT(cnt.reads == full_reads - 12, "tiles: only the map and the tile pointers were read");
        EXPECT(st.frame_hash == prev_hash && !memcmp(dst, ref, fb), "tiles: same picture, same fingerprint");

        /* SAI's copy-on-write: tile (1,1) gets a new block with new pixels. */
        slot = tile_slot(&f, c3, 1, 1);
        put64(&f, slot, new_block(&f, &heap, 32, 0x77));
        ok = INC(0) && FRESH();
        EXPECT(ok && st.tiles_read == 1, "tiles: a changed tile is the only one read");
        EXPECT(ok && !memcmp(dst, ref, fb), "tiles: the frame shows the change");
        EXPECT(st.frame_hash != prev_hash, "tiles: the fingerprint changes with the picture");
        prev_hash = st.frame_hash;

        /* New block, same pixels: read, but not a new frame. */
        slot = tile_slot(&f, c3, 2, 1);
        oldpx = get64(&f, slot);
        {
            uint64_t px = new_block(&f, &heap, 32, 0);
            memcpy(f.buf + (px - FAKE_ORIGIN), f.buf + (oldpx - FAKE_ORIGIN), 32 * 32 * 4);
            put64(&f, slot, px);
        }
        ok = INC(0);
        EXPECT(ok && st.tiles_read == 1 && st.frame_hash == prev_hash,
               "tiles: a new block with the same pixels is not a change");

        /* THE TRAP the verify pass exists for: a block changed in place. */
        slot = tile_slot(&f, c3, 0, 0);
        oldpx = get64(&f, slot);
        memset(f.buf + (oldpx - FAKE_ORIGIN), 0x55, 32 * 32 * 4);
        ok = INC(0);
        EXPECT(ok && st.tiles_read == 0 && dst[0] != 0x55,
               "tiles: without verify, an in-place change is missed (why verify exists)");
        ok = INC(1) && FRESH();
        EXPECT(ok && st.inplace_changes == 1 && !memcmp(dst, ref, fb),
               "tiles: verify reads every tile, counts the in-place change and fixes the frame");
        prev_hash = st.frame_hash;

        /* Holes: a tile disappears (white), then comes back. */
        slot = tile_slot(&f, c3, 3, 2);
        oldpx = get64(&f, slot);
        put64(&f, slot, 0);
        ok = INC(0) && FRESH();
        EXPECT(ok && !memcmp(dst, ref, fb) && dst[(69 * 100 + 99) * 4] == 0xff,
               "tiles: a tile that disappears turns white");
        put64(&f, slot, oldpx);
        ok = INC(0) && FRESH();
        EXPECT(ok && !memcmp(dst, ref, fb), "tiles: a tile that comes back shows again");

        /* Padding: invisible bytes of the partial edge tile (3,0) change. */
        slot = tile_slot(&f, c3, 3, 0);
        oldpx = get64(&f, slot);
        prev_hash = st.frame_hash;
        {
            uint64_t px = new_block(&f, &heap, 32, 0);
            uint32_t r;
            memcpy(f.buf + (px - FAKE_ORIGIN), f.buf + (oldpx - FAKE_ORIGIN), 32 * 32 * 4);
            for (r = 0; r < 32; r++)   /* only x >= 4 is past the canvas edge */
                memset(f.buf + (px - FAKE_ORIGIN) + (size_t)r * 32 * 4 + 4 * 4, 0xAB, 28 * 4);
            put64(&f, slot, px);
        }
        ok = INC(0);
        EXPECT(ok && st.frame_hash == prev_hash,
               "tiles: garbage past the canvas edge is not a change");

        /* Canvas, level and size changes force a full read. */
        ok = tlc_read_level_incremental(fake_read, &f, L, c1, 0, dst, sizeof dst, scratch,
                                        sizeof scratch, &tc, 0, &w, &h, &st);
        EXPECT(ok && st.full, "tiles: switching canvas reads everything");
        ok = INC(0);
        EXPECT(ok && st.full, "tiles: switching back reads everything again");
        ok = tlc_read_level_incremental(fake_read, &f, L, c3, 1, dst, sizeof dst, scratch,
                                        sizeof scratch, &tc, 0, &w, &h, &st);
        EXPECT(ok && st.full, "tiles: switching level reads everything");

        /* Failure halfway: the cache must not survive it. */
        ok = INC(0);
        slot = tile_slot(&f, c3, 2, 2);
        oldpx = get64(&f, slot);
        put64(&f, slot, 0x900000000ULL);           /* outside the fake memory */
        EXPECT(!INC(0) && tc.ntiles == 0, "tiles: a failed read empties the cache");
        put64(&f, slot, oldpx);
        ok = INC(0) && FRESH();
        EXPECT(ok && st.full && !memcmp(dst, ref, fb), "tiles: the read after a failure is full and correct");

        /* Sweep: 200 random copy-on-write changes, hole toggles and same-pixel
         * swaps. After every step the frame must equal a fresh full read. */
        for (step = 0; step < 200; step++) {
            uint32_t tx = lcg(&seed) % 4, ty = lcg(&seed) % 3, op = lcg(&seed) % 3;
            slot = tile_slot(&f, c3, tx, ty);
            oldpx = get64(&f, slot);
            if (op == 0) put64(&f, slot, new_block(&f, &heap, 32, (int)(lcg(&seed) & 0xff)));
            else if (op == 1) put64(&f, slot, oldpx ? 0 : new_block(&f, &heap, 32, 0x33));
            else if (oldpx) {
                uint64_t px = new_block(&f, &heap, 32, 0);
                memcpy(f.buf + (px - FAKE_ORIGIN), f.buf + (oldpx - FAKE_ORIGIN), 32 * 32 * 4);
                put64(&f, slot, px);
            }
            if (!INC(0) || !FRESH() || memcmp(dst, ref, fb)) { sweep_ok = 0; break; }
        }
        EXPECT(sweep_ok, "tiles: 200 random changes, the frame always matches a full read");
#undef FRESH
#undef INC
    }

    free(f.buf);
    if (failures) { printf("FAILED: %d test(s)\n", failures); return 1; }
    printf("All timelapse_core tests passed.\n");
    return 0;
}
