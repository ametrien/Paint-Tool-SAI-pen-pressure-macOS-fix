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

/* Hard ceiling for the wire format. The ACTIVE full-scale value is chosen
 * at runtime (see g_max_press in wintab32.c) and may be lower; this only
 * bounds what the parser will accept. */
#define WTC_MAX_PRESS 8191

/* How long after a real pen-tip transition a synthetic left-button message is
 * considered a duplicate of it. Lives here (not in wintab32.c) so the DLL and
 * tests/test_wintab_core.c cannot drift apart on the boundary. */
#define WTC_CLICK_DEDUP_MS 400

/* one pen sample from the mac helper: pressure 0..g_max_press plus (optionally) a
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
    /* Defensive: never divide by a zero extent. Callers only pass has_pos
     * samples (w>0, h>0), but guard the pure function anyway — a stray w/h of 0
     * would otherwise be a divide-by-zero crash. Degrade to the origin. */
    if (s->w <= 0 || s->h <= 0) { *outX = oX; *outY = oY; return; }
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

/* CLICK DE-DUP decision: should this left-button message be rewritten to
 * WM_NULL? Answering yes to a WM_LBUTTONDOWN destroys the stroke it would have
 * started, so this has blocked drawing entirely TWICE (#19, then again in
 * v0.1.10) and is the single most damaging "yes" in the DLL.
 *
 * ---------------------------------------------------------------------------
 * READ THIS BEFORE TOUCHING THE MESSAGE HOOK
 * ---------------------------------------------------------------------------
 * `want_dedup` is NOT redundant, and you cannot infer it from the hook being
 * installed. That inference is exactly what broke this the second time:
 *
 *   #19  fixed the first outage by making the de-dup opt-in AT THE INSTALL
 *        SITE — ensure_click_dedup() simply returned without installing the
 *        hook. click_hook_proc needed no check of its own, because the hook's
 *        existence implied consent.
 *   #24  needed the SAME WH_GETMESSAGE hook for scroll-to-pan, which is on by
 *        default, so the early return became `if (!want_dedup && !want_pan)`.
 *        The hook now installs for everyone. The install-site guard silently
 *        stopped guarding anything, and every user got #19 back.
 *
 * The lesson: the hook is SHARED. Its existence tells you nothing about which
 * feature asked for it. Every consumer inside click_hook_proc must gate on its
 * own flag. If you add a third feature to that hook, it needs its own flag too
 * — do not widen an existing one.
 *
 * Keep this decision here, in the natively-testable core, rather than inline in
 * click_hook_proc: the Win32 version is unreachable from the test suite, which
 * is why two outages shipped undetected. See the wtc_should_eat_click cases in
 * tests/test_wintab_core.c.
 *
 *   want_dedup  did the user actually opt in (WT_CLICK_DEDUP=1)?
 *   dt          ms since the last real pen-tip transition
 *   dedup_ms    the window (WTC_CLICK_DEDUP_MS, 400)
 *   same_root   is the message aimed at SAI's own root window?
 */
static int wtc_should_eat_click(int want_dedup, unsigned long dt,
                                unsigned long dedup_ms, int same_root) {
    return want_dedup && dt < dedup_ms && same_root;
}

#endif /* WINTAB_CORE_H */
