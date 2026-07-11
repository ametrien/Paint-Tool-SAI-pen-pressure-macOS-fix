/*
 * wintab_core.h — the PURE logic of our wintab32.dll, extracted so it can be
 * unit-tested natively (clang on macOS, no Win32/mingw needed). wintab32.c
 * includes this and keeps only the OS glue (window messages, threads, sockets).
 *
 * Everything here is deterministic input -> output. If you change behaviour
 * here, add/adjust a case in tests/test_wintab_core.c.
 */
#ifndef WINTAB_CORE_H
#define WINTAB_CORE_H

#include <stdint.h>
#include <stdio.h>

#define WTC_MAX_PRESS 1023

/* one pen sample from the mac helper: pressure 0..1023 plus (optionally) a
 * position in mac coords — origin bottom-left, y-up, 8x fixed point — and the
 * virtual-desktop size in the same units. */
typedef struct { int press, x, y, w, h, has_pos; } WTC_SAMPLE;

/* Parse "p [x y w h]" into a sample. Returns 1 on success, 0 on a torn/invalid
 * read (caller keeps its previous sample — treating torn reads as pen-up caused
 * stroke gaps SAI bridged with straight segments). On a bare "p" (no position),
 * press is updated and has_pos is cleared; existing x/y/w/h in *out are left
 * untouched so a position-less pen-up can end the stroke at the last point. */
static int wtc_parse_sample(const char *buf, WTC_SAMPLE *out) {
    int p = -1, x = 0, y = 0, w = 0, h = 0;
    int n = sscanf(buf, "%d %d %d %d %d", &p, &x, &y, &w, &h);
    if (n < 1 || p < 0) return 0;
    if (p > WTC_MAX_PRESS) p = WTC_MAX_PRESS;
    out->press = p;
    if (n == 5 && w > 0 && h > 0) { out->x = x; out->y = y; out->w = w; out->h = h; out->has_pos = 1; }
    else out->has_pos = 0;
    return 1;
}

/* Map a sample's position into the OUTPUT coordinate space of the context SAI
 * opened (WinTab packets are in lcOut coords). WinTab convention: positive
 * lcOutExtY means Y grows upward. Helper coords are mac bottom-left y-up
 * (already the WinTab direction) and fixed-point (x,y,w,h uniformly scaled) —
 * map DIRECTLY into out space in one 64-bit step, no intermediate screen-pixel
 * quantization. eX/eY of 0 fall back to in_ext (context not yet configured). */
static void wtc_map_to_out(const WTC_SAMPLE *s,
                           int32_t oX, int32_t oY, int32_t eX, int32_t eY,
                           int32_t in_ext,
                           int32_t *outX, int32_t *outY) {
    if (!eX) eX = in_ext;
    if (!eY) eY = in_ext;
    *outX = oX + (int32_t)((int64_t)s->x * eX / s->w);
    if (eY > 0)  /* y-up: mac y is already y-up */
        *outY = oY + (int32_t)((int64_t)s->y * eY / s->h);
    else         /* y-down */
        *outY = oY + (int32_t)((int64_t)(s->h - 1 - s->y) * (int64_t)(-eY) / s->h);
}

/* CONFLATION decision: post a new WT_PACKET now, or collapse this sample into
 * "latest" and deliver it once SAI catches up? Posting a packet per sample
 * floods SAI faster than it drains its message queue (ink trails the cursor);
 * self-pacing to SAI's consumption keeps the trail tight. Tip transitions
 * (down<->up) must NEVER be dropped. `serial` is the NEXT serial to assign,
 * `fetched` the last serial SAI actually pulled via WTPacket. */
static int wtc_should_post(unsigned serial, unsigned fetched, int transition, int post_window) {
    int outstanding = (int)(serial - 1 - fetched);
    return transition || outstanding < post_window;
}

#endif /* WINTAB_CORE_H */
