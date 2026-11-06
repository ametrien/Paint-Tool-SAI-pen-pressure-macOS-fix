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

/* ---------------------------------------------------------------------------
 * PLACING THE PEN WHEN THERE IS MORE THAN ONE SCREEN (issue #37)
 * ---------------------------------------------------------------------------
 * Two parts of this project each hold an idea of "the desktop", and before
 * #37 the DLL assumed they always agreed:
 *
 *   the HELPER  re-measures every time macOS reports a display change, and
 *               sends the pen as a position inside the WHOLE desktop (union of
 *               all screens) together with that desktop's size;
 *   SAI         learns the tablet area ONCE, from the context it opens at
 *               launch, and keeps it.
 *
 * wtc_map_to_out() scaled the helper's position straight into SAI's area. That
 * is right only while both describe the same rectangle. Start SAI with the
 * screens mirrored (1920x1080), switch to extended (3432x1121): the helper now
 * reports the TV centre as 960/3432 of the way across, SAI's area is 1920
 * wide, and the ink lands at x 537, about a fifth of the screen to the left,
 * slightly high, and the second screen cannot be reached at all. That is what
 * the #37 reporter and our own test both saw.
 *
 * The fix goes through a third rectangle that is always current: the Windows
 * virtual desktop as Wine reports it NOW (GetSystemMetrics, re-read about once
 * a second). The helper's fraction of the desktop becomes a real Windows
 * screen point, and that point is placed inside the area SAI opened with.
 * Whichever side is stale, the point is the same place on the glass.
 *
 *   virt  the Windows virtual desktop now: origin can be negative (a screen to
 *         the left of or above the main one), size in Windows pixels (== mac
 *         points unless Wine's Retina mode is on, and the fraction makes that
 *         difference irrelevant)
 *   sys   the screen area SAI's context says the tablet covers (lcSysOrg/Ext)
 *
 * Returns 1 when the point is inside SAI's area. 0 means SAI cannot be told
 * about this point at all (a screen added after SAI opened its context); the
 * caller must NOT post it, because any coordinate it posted would be a lie
 * that lands ink somewhere else. *out is still filled (clamped to the edge)
 * so a caller that needs a last position has one.
 *
 * With one screen, or before anything has changed, virt == sys == the
 * helper's desktop and this returns exactly what wtc_map_to_out() returned,
 * to the unit. The tests pin that, because every single-screen user relies on
 * it. Invalid virt or sys (zero size) falls back to wtc_map_to_out(). */
typedef struct { int32_t x, y, w, h; } WTC_RECT;

static int wtc_place(const WTC_SAMPLE *s, WTC_RECT virt, WTC_RECT sys,
                     int32_t oX, int32_t oY, int32_t eX, int32_t eY,
                     int32_t in_ext, int32_t *outX, int32_t *outY) {
    if (s->w <= 0 || s->h <= 0 || virt.w <= 0 || virt.h <= 0 || sys.w <= 0 || sys.h <= 0) {
        wtc_map_to_out(s, oX, oY, eX, eY, in_ext, outX, outY);
        return 1;
    }
    /* helper fraction -> Windows screen point, 8x fixed point, y DOWN */
    int64_t wx8 = (int64_t)virt.x * 8 + (int64_t)s->x * virt.w * 8 / s->w;
    int64_t wy8 = (int64_t)virt.y * 8 + (int64_t)(s->h - s->y) * virt.h * 8 / s->h;
    /* Windows point -> position inside SAI's area, in the helper's own
     * convention (y UP from the area's bottom), so wtc_map_to_out() finishes
     * the job unchanged */
    int64_t sw8 = (int64_t)sys.w * 8, sh8 = (int64_t)sys.h * 8;
    int64_t lx = wx8 - (int64_t)sys.x * 8;
    int64_t ly = ((int64_t)sys.y + sys.h) * 8 - wy8;
    int inside = lx >= 0 && lx < sw8 && ly >= 0 && ly <= sh8;
    if (lx < 0) lx = 0;
    if (lx > sw8 - 1) lx = sw8 - 1;
    if (ly < 0) ly = 0;
    if (ly > sh8) ly = sh8;
    WTC_SAMPLE local = *s;
    local.x = (int)lx; local.y = (int)ly; local.w = (int)sw8; local.h = (int)sh8;
    wtc_map_to_out(&local, oX, oY, eX, eY, in_ext, outX, outY);
    return inside;
}

/* The Windows screen point (whole pixels) a sample stands for, using the
 * desktop as Wine reports it now. Same arithmetic as wtc_place(), exposed so
 * the self-check below compares like with like. */
static void wtc_sample_to_screen(const WTC_SAMPLE *s, WTC_RECT virt, int32_t *sx, int32_t *sy) {
    if (s->w <= 0 || s->h <= 0 || virt.w <= 0 || virt.h <= 0) { *sx = virt.x; *sy = virt.y; return; }
    *sx = (int32_t)(virt.x + (int64_t)s->x * virt.w / s->w);
    *sy = (int32_t)(virt.y + (int64_t)(s->h - s->y) * virt.h / s->h);
}

/* The reverse: a Windows screen point as a helper-style sample of `virt`, so
 * a position taken from Wine's cursor can go through wtc_place() like any
 * other. Pressure and has_pos are copied from `like`. */
static WTC_SAMPLE wtc_screen_to_sample(const WTC_SAMPLE *like, WTC_RECT virt, int32_t sx, int32_t sy) {
    WTC_SAMPLE s = *like;
    s.x = (sx - virt.x) * 8;
    s.y = (virt.y + virt.h - sy) * 8;
    s.w = virt.w * 8;
    s.h = virt.h * 8;
    return s;
}

/* SELF-CHECK against Wine's own cursor.
 *
 * The tablet moves the ordinary cursor too, and Wine always knows where that
 * cursor is in Windows coordinates, screen changes included. So while the pen
 * HOVERS (not while drawing: a stroke is too fast for the two to stay in step),
 * where we think the pen is and where Wine's cursor is should agree within a
 * few pixels. If they persistently do not, our idea of the screens is wrong in
 * a way nothing else caught, and ink would land in the wrong place.
 *
 * This only decides. `streak` is the caller's counter of consecutive hover
 * samples that disagreed; returns the new streak. A disagreement must persist
 * for `need` samples (cursor updates lag the tablet by a frame or two, and a
 * fast hover can open a gap for a moment), and any agreeing sample resets it.
 * The caller treats streak >= need as "do not trust our position". */
static int wtc_cursor_streak(int streak, int32_t ourX, int32_t ourY,
                             int32_t curX, int32_t curY, int32_t tol) {
    int32_t dx = ourX - curX, dy = ourY - curY;
    if (dx < 0) dx = -dx;
    if (dy < 0) dy = -dy;
    if (dx <= tol && dy <= tol) return 0;
    return streak < 1000000 ? streak + 1 : streak;
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

/* STATUS LINE: the DLL's answer to "did any of this reach SAI?".
 *
 * Everything the setup app can see lives on the mac side. Whether SAI loaded
 * THIS dll, whether it opened a tablet context, whether our samples arrive, and
 * whether SAI actually reads the packets we post are all known HERE — and until
 * now they were only ever written to a debug log nobody switches on. That is
 * how a field report (#29) could show every mac-side check passing while the
 * bridge was inert: no one could see this side. So the producer writes these
 * numbers to C:\wt_status.txt about once a second and the app reads the file.
 * Two processes, one direction, no protocol to get wrong.
 *
 * One `key=value` per line, because the build stamp contains spaces and because
 * a human who opens the file should learn exactly what the app learns.
 *
 * Returns the length written, or 0 when the buffer is too small — a truncated
 * status parses as a confident lie, so callers write nothing at all instead.
 */
static int wtc_format_status(char *out, size_t cap,
                             const char *build, int open,
                             unsigned long recv, unsigned long posted,
                             unsigned long fetched, int max_press) {
    int n;
    if (!out || cap == 0) return 0;
    n = snprintf(out, cap,
                 "v=1\n"
                 "build=%s\n"
                 "open=%d\n"
                 "recv=%lu\n"
                 "posted=%lu\n"
                 "fetched=%lu\n"
                 "pmax=%d\n",
                 build ? build : "unknown", open ? 1 : 0, recv, posted, fetched, max_press);
    if (n < 0 || (size_t)n >= cap) { out[0] = '\0'; return 0; }
    return n;
}

/* Screen lines of the status file (#37), appended after wtc_format_status().
 *
 *   newscreen=1  the pen went onto a screen SAI's tablet area does not cover
 *                (connected after SAI opened it). The pen works as a plain
 *                mouse there; the app tells the user a restart of SAI brings
 *                pressure to that screen.
 *   mismatch=1   the self-check found our pen position persistently away from
 *                Wine's cursor, and the DLL is following the cursor instead.
 *
 * Kept separate so the long-standing lines above, which older apps parse,
 * stay exactly as they were. Same contract: 0 and an empty string when the
 * buffer is too small. */
static int wtc_format_screens(char *out, size_t cap, int newscreen, int mismatch) {
    int n;
    if (!out || cap == 0) return 0;
    n = snprintf(out, cap, "newscreen=%d\nmismatch=%d\n", newscreen ? 1 : 0, mismatch ? 1 : 0);
    if (n < 0 || (size_t)n >= cap) { out[0] = '\0'; return 0; }
    return n;
}

#endif /* WINTAB_CORE_H */
