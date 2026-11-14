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
#include <string.h>

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
    /* Edges are inclusive on every side: a tablet maps its edge onto the
     * screen's edge, so x == width happens, and calling it outside ended the
     * stroke at the last column of a single screen. Inside points are left
     * exactly as they are (single screen == old mapping, edges included);
     * only points that really are outside get clamped. */
    int inside = lx >= 0 && lx <= sw8 && ly >= 0 && ly <= sh8;
    if (!inside) {
        if (lx < 0) lx = 0;
        if (lx > sw8 - 1) lx = sw8 - 1;
        if (ly < 0) ly = 0;
        if (ly > sh8) ly = sh8;
    }
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

/* GETTING SAI TO RE-READ ITS TABLET AREA AFTER A SCREEN CHANGE (#37).
 *
 * Read from sai2.exe (static disassembly, SAI2 build of 5,171,200 bytes; see
 * MULTI-MONITOR-FINDINGS.md for addresses). SAI copies the tablet area out of
 * WTGetW() into its own fields and maps every packet with those copies. It
 * calls WTGetW() at start-up and in exactly one other place: on WT_CTXOVERLAP
 * (base + 4) arriving at its WinTab control window, class
 * "sflWintabCtrlWindow". SAI only opens its context on that window in one of
 * its WinTab modes; in the other it hands WTOpenW() its main window
 * ("sflRootWindow"), where WT_CTXUPDATE and WT_INFOCHANGE are ignored and
 * WT_CTXOVERLAP merely clears a flag.
 *
 * So the extra message goes out only when the window SAI gave us is the
 * control window. THE TRAP: the message number and the class name are what
 * SAI's code compares against; "tidying" either (base + 3, a different
 * spelling, a case-insensitive guess at another class) silently brings back
 * "restart SAI for pressure there" with nothing failing at build time. */
#define WTC_CTXOVERLAP_OFFSET 4
#define WTC_SAI_WINTAB_WINDOW "sflWintabCtrlWindow"

static int wtc_sai_rereads_on_overlap(const char *window_class) {
    return window_class && strcmp(window_class, WTC_SAI_WINTAB_WINDOW) == 0;
}

/* How far (Windows pixels) our pen may sit from Wine's cursor, and for how
 * many consecutive hover samples, before the DLL stops trusting its own
 * position. Generous on purpose: the cursor trails the tablet by a frame or
 * two, and a false alarm costs sub-pixel precision for nothing. Here, not in
 * wintab32.c, so the DLL and the tests cannot drift apart. */
#define WTC_SELFCHECK_TOL  48
#define WTC_SELFCHECK_NEED 20

/* ONE HOVER SAMPLE OF THE SELF-CHECK, with a stale cursor left out.
 *
 * THE TRAP (seen 2026-11-06, two screens): Wine only learns where the cursor
 * is while it is over one of Wine's own windows. Hover from SAI's window onto
 * another screen and Wine's cursor stays frozen where it last was, INSIDE
 * SAI's window, so the caller's "cursor is over SAI" guard still passes. Our
 * position (right) then moves away from that frozen point (wrong), and 20
 * samples later the DLL decided its own position was the fault and followed
 * the cursor: "pen at (1510,623) but Wine's cursor at (2109,544) for 20
 * samples". Had a stroke started then, it would have been drawn from Wine's
 * cursor, in whole pixels and late.
 *
 * The signature of a frozen cursor: our position moved since the last sample
 * and Wine's cursor did not move at all. Such a sample says nothing about us,
 * so it neither counts nor clears the streak. Everything else is compared as
 * before, which keeps the real faults visible:
 *   - our mapping wrong while the cursor is live: both move, so it counts;
 *   - both standing still and apart: counts too (nothing is frozen there);
 *   - first sample after a gap: nothing to compare with, so it counts.
 * Do not "simplify" this to "the cursor did not move": a pen held still
 * would then never be checked. */
typedef struct { int streak, have; int32_t ourX, ourY, curX, curY; } WTC_SELFCHECK;

static int wtc_selfcheck_step(WTC_SELFCHECK *st, int32_t ourX, int32_t ourY,
                              int32_t curX, int32_t curY, int32_t tol) {
    int frozen = st->have
              && (ourX != st->ourX || ourY != st->ourY)
              && curX == st->curX && curY == st->curY;
    st->have = 1;
    st->ourX = ourX; st->ourY = ourY;
    st->curX = curX; st->curY = curY;
    if (!frozen)
        st->streak = wtc_cursor_streak(st->streak, ourX, ourY, curX, curY, tol);
    return st->streak;
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

/* ---------------------------------------------------------------------------
 * WHICH PROGRAM LOADED US? (SAI going inactive, 2026-11-11)
 * ---------------------------------------------------------------------------
 * Two programs load this DLL: SAI, and wtprobe.exe, the stand-in for SAI that
 * the app's Test pen button runs inside Wine. Both start the producer thread,
 * so both used to run every one of its chores. The wake is the one that
 * reaches outside its own process: it takes the Windows foreground for the
 * host's window, with the AttachThreadInput bypass. A probe left running after
 * a pen test therefore took the foreground away from SAI on every wake, and
 * SAI went inactive. The wake log showed it as two pids taking turns, ending
 * "STILL LOST".
 *
 * THE TRAP: the probe's window is never shown, so find_main_window() finds
 * nothing and win32_wake() falls back to GetAncestor(g_hwnd). "The probe has
 * no visible window" does NOT mean "the wake does nothing there". Anything
 * new in the producer that touches the foreground, focus or another process's
 * windows must be gated on wtc_host_is_probe() too.
 *
 * Decided by the probe's name, not by SAI's: SAI has shipped as sai.exe and
 * sai2.exe and people rename it, while the probe is ours and is always
 * wtprobe.exe. Only the file name counts (a folder called wtprobe.exe is not
 * the probe), compared without case because Windows paths are. Unknown host
 * (NULL, empty) means "not the probe", so SAI never loses its wake because
 * GetModuleFileName failed. */
#define WTC_PROBE_EXE "wtprobe.exe"

static int wtc_host_is_probe(const char *exe_path) {
    const char *base, *p, *want = WTC_PROBE_EXE;
    if (!exe_path) return 0;
    base = exe_path;
    for (p = exe_path; *p; p++)
        if (*p == '\\' || *p == '/') base = p + 1;
    for (p = base; *p && *want; p++, want++) {
        char a = *p, b = *want;
        if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
        if (a != b) return 0;
    }
    return *p == '\0' && *want == '\0';
}

/* Should THIS process run a wake now? The helper asks for one by writing a
 * new number to C:\wt_wake.txt; `marker` is what the file holds now and `last`
 * (capacity `cap`) is what this process saw before, updated here.
 *   - never in the probe (see above): this is the line the bug lacked;
 *   - not for the value already there when we started, which is an old
 *     request from a previous session, not a new one;
 *   - otherwise exactly once per change of the file. */
static int wtc_wake_requested(const char *marker, char *last, size_t cap, int host_is_probe) {
    int first;
    if (host_is_probe) return 0;
    if (!marker || !last || cap == 0) return 0;
    if (strcmp(marker, last) == 0) return 0;
    first = (last[0] == '\0');
    snprintf(last, cap, "%s", marker);
    return !first;
}

/* PEN PORT RETRY. The producer binds 127.0.0.1:47800 to receive the helper's
 * samples. Until 2026-11-11 it tried once, at load: if anything else held the
 * port (a leftover probe did), SAI stayed in "file mode only" for the whole
 * session. File mode reads one file that holds only the newest sample, so
 * whatever the pen did while the producer was busy elsewhere (a wake keeps it
 * busy for a quarter to most of a second) is overwritten before it is read.
 * The UDP socket queues those samples instead.
 *
 * So the producer keeps trying, once per `interval_ms`, and takes the live
 * stream back as soon as the port is free. GetTickCount() is 32 bits and
 * wraps after 49.7 days; the 32-bit unsigned subtraction is what keeps the
 * retry going across the wrap. Do not widen these to unsigned long (64 bits
 * on the Mac, so the tests would stop seeing the wrap) or rewrite the test as
 * `now >= last_try + interval`. */
#define WTC_PORT_RETRY_MS 1000

static int wtc_should_retry_bind(int have_socket, uint32_t now,
                                 uint32_t last_try, uint32_t interval_ms) {
    if (have_socket) return 0;
    return (uint32_t)(now - last_try) >= interval_ms;
}

/* ---- SAMPLE TIMES FROM THE APP ----------------------------------------------
 * Since the stroke-start diagnosis, each datagram ends with three more numbers
 * (PressureCore.wireLine in the app): `ev`, when macOS stamped the pen event;
 * `tx`, when the app sent it; both in microseconds; and `n`, how many pen
 * samples the app has handled. All three arrive modulo 2^31, so two of them
 * are only ever compared through wtc_wire_diff(), never with a plain minus.
 * An app from before this sends six fields: has = 0 and the trace does
 * without. */
#define WTC_WIRE_MASK 0x7FFFFFFFu
/* ev_bad: the app could not use the stamp macOS put on this event (it did not
 * read as a recent time on either clock), or there was no event at all (a
 * timer's send). `ev` then means nothing and is shown as "?", never as a
 * number. THE TRAP this closes: the first field run with times (2026-11-14)
 * had the same `ev` on every sample, so every gap read "ev+0.0", which is
 * exactly what "the tablet was on time, the app was late" looks like. A time
 * that cannot be trusted must not look like a measurement. Last in the struct
 * so that { has, ev, tx, n } still spells a usable one. */
typedef struct { int has; uint32_t ev, tx, n; int ev_bad; } WTC_TIMES;

/* a - b for two wire values, right across the 2^31 wrap */
static uint32_t wtc_wire_diff(uint32_t a, uint32_t b) { return (a - b) & WTC_WIRE_MASK; }

typedef struct { long seq; int p, x, y, w, h; WTC_TIMES tm; } WTC_DGRAM;

/* One datagram: "seq p x y w h [ev tx n [evok]]". Returns 1 when it holds a
 * sample. The three extra fields count only if all three are there. `evok` is
 * 1 when `ev` is a real event time; an app that does not send it (nine fields)
 * is taken at its word. */
static int wtc_parse_datagram(const char *buf, WTC_DGRAM *d) {
    unsigned ev = 0, tx = 0, n = 0;
    int got, evok = 1;
    memset(d, 0, sizeof *d);
    d->seq = -1; d->p = -1;
    got = sscanf(buf, "%ld %d %d %d %d %d %u %u %u %d",
                 &d->seq, &d->p, &d->x, &d->y, &d->w, &d->h, &ev, &tx, &n, &evok);
    if (got < 6 || d->p < 0) return 0;
    if (got >= 9) {
        d->tm.has = 1;
        d->tm.ev = ev & WTC_WIRE_MASK; d->tm.tx = tx & WTC_WIRE_MASK; d->tm.n = n & WTC_WIRE_MASK;
        d->tm.ev_bad = (got >= 10 && evok != 1);
    }
    return 1;
}

/* ---- STROKE-START TRACE (diagnostic, debug log only) ------------------------
 * Question it answers: is the very beginning of a stroke lost, and where?
 *
 * SAI needs the mouse click Wine makes from the same pen touch to start a
 * stroke (we learned that the hard way in #19: eating that click stopped all
 * drawing). That click reaches SAI 1 to 12 ms AFTER our first pen-down packet.
 * Windows hands a program its posted messages (our WT_PACKET) before its input
 * messages (the click), so SAI may read our first pen-down packets before it
 * has started the stroke, and may drop them. This trace records, for the first
 * packets of each stroke: when we posted it, its pressure and screen position,
 * when SAI fetched it, and whether that fetch came BEFORE or AFTER SAI took the
 * click. One log line per stroke.
 *
 * THE TRAP: decide "before or after the click" by the ORDER the two happened
 * in, never by comparing millisecond ticks. Both run on SAI's UI thread, a
 * fetch and the click often land in the same millisecond, and a tick compare
 * then gets about half of them wrong, which is exactly the packet this trace
 * exists to find. Every event takes the next number from `ord` instead.
 * tests/test_wintab_core.c pins this with a fetch and a click in one tick.
 *
 * WHERE A LATE SAMPLE LOST ITS TIME. The first field run showed the second
 * sample of a stroke arriving 20 to 59 ms after the first in 29 strokes of 72
 * (8 ms is normal), with nothing lost between the app and SAI. So each packet
 * also shows, when the app sends them (WTC_TIMES), three times measured from
 * packet #0: `ev` (macOS stamped the pen event), `tx` (the app sent it) and
 * the plain `+Nms` (we received it). The first of the three that shows the
 * gap names the culprit: the tablet and its driver, the app, or Wine.
 * `skip` is how many samples the app handled but did not send since the
 * packet before. `lag0` is how long packet #0 itself waited inside the app. */
#define WTC_ST_MAX       8     /* packets traced per stroke start */
#define WTC_ST_WINDOW_MS 60    /* samples within this long of pen-down are traced */
#define WTC_ST_REPORT_MS 120   /* the line is written this long after pen-down,
                                  leaving SAI time to fetch the last ones */
#define WTC_ST_EARLY_MS  30    /* a click this soon BEFORE our pen-down still
                                  belongs to this stroke (Wine was faster) */

typedef struct {
    int      posted;      /* 0: merged into a later packet, SAI never saw it */
    uint32_t ser;
    uint32_t t_post;      /* ms after pen-down */
    int      press;
    int32_t  sx, sy;      /* screen position, the space Wine's click uses */
    int      fetched;
    uint32_t t_fetch;     /* ms after pen-down */
    int      fetch_ord;
    int      has_t;       /* the app sent times with this sample */
    int      ev_bad;      /* ...but its event time, or packet #0's, is unusable */
    uint32_t ev_us, tx_us;   /* microseconds after packet #0's own ev / tx */
    int      skip;        /* samples the app handled but did not send before this one */
} WTC_ST_PKT;

typedef struct {
    int        active;
    uint32_t   t0;              /* GetTickCount at pen-down */
    int        n, extra;        /* traced packets; ones past WTC_ST_MAX */
    WTC_ST_PKT pk[WTC_ST_MAX];
    int        ord;             /* event order, see THE TRAP */
    int        clicked, click_ord;
    int32_t    click_dt;        /* ms from pen-down; negative = click came first */
    int32_t    cx, cy;
    int        ended;           /* pen lifted inside the window (a tap) */
    /* the newest click seen, kept across strokes so a click that beat our
     * pen-down can still be matched to it */
    int        have_last_click;
    uint32_t   last_click_t;
    int32_t    last_cx, last_cy;
    /* app times: packet #0's, which the others are measured from, and the
     * sample before the current one (traced or not), for `skip` */
    WTC_TIMES  tm0, tm_prev;
} WTC_STARTTRACE;

static void wtc_st_add(WTC_STARTTRACE *tr, uint32_t t, int posted, uint32_t ser,
                       int press, int32_t sx, int32_t sy, const WTC_TIMES *tm) {
    WTC_TIMES prev = tr->tm_prev;
    if (tm) tr->tm_prev = *tm; else tr->tm_prev.has = 0;
    if (tr->n >= WTC_ST_MAX) { tr->extra++; return; }
    WTC_ST_PKT *p = &tr->pk[tr->n++];
    memset(p, 0, sizeof *p);
    p->posted = posted; p->ser = ser; p->t_post = t - tr->t0;
    p->press = press; p->sx = sx; p->sy = sy;
    /* Times only while packet #0 had them too: they are all measured from it,
     * and a trace that starts without (an old app) stays without. */
    if (tm && tm->has && (tr->n == 1 || tr->tm0.has)) {
        if (tr->n == 1) tr->tm0 = *tm;
        p->has_t = 1;
        p->ev_bad = tm->ev_bad || tr->tm0.ev_bad;     /* measured from #0: both must hold */
        p->ev_us = wtc_wire_diff(tm->ev, tr->tm0.ev);
        p->tx_us = wtc_wire_diff(tm->tx, tr->tm0.tx);
        /* n counts every sample the app handled; two sends in a row differ by
         * exactly 1 when nothing was held back in between */
        p->skip = (tr->n > 1 && prev.has) ? (int)wtc_wire_diff(tm->n, prev.n) - 1 : 0;
    }
    tr->ord++;
}

/* Pen-down: start a fresh trace with this packet as #0. The caller writes out
 * any trace still active first (wtc_st_format), or it is lost. `tm` may be
 * NULL (no times: an app from before they were sent, or the file fallback). */
static void wtc_st_down_t(WTC_STARTTRACE *tr, uint32_t t, int posted, uint32_t ser,
                          int press, int32_t sx, int32_t sy, const WTC_TIMES *tm) {
    int have = tr->have_last_click;
    uint32_t lt = tr->last_click_t;
    int32_t lx = tr->last_cx, ly = tr->last_cy;
    memset(tr, 0, sizeof *tr);
    tr->have_last_click = have; tr->last_click_t = lt; tr->last_cx = lx; tr->last_cy = ly;
    tr->active = 1;
    tr->t0 = t;
    if (have && (uint32_t)(t - lt) <= WTC_ST_EARLY_MS) {
        /* Wine's click got to SAI before our first packet: it comes first in
         * the order, so every fetch below counts as after it. */
        tr->clicked = 1;
        tr->click_ord = tr->ord++;
        tr->click_dt = -(int32_t)(t - lt);
        tr->cx = lx; tr->cy = ly;
        tr->have_last_click = 0;        /* used up */
    }
    wtc_st_add(tr, t, posted, ser, press, sx, sy, tm);
}

/* Every later sample. `down` 0 is the pen lifting. */
static void wtc_st_sample_t(WTC_STARTTRACE *tr, uint32_t t, int down, int posted,
                            uint32_t ser, int press, int32_t sx, int32_t sy,
                            const WTC_TIMES *tm) {
    if (!tr->active || tr->ended) return;
    if ((uint32_t)(t - tr->t0) > WTC_ST_WINDOW_MS) return;
    if (!down) { tr->ended = 1; return; }
    wtc_st_add(tr, t, posted, ser, press, sx, sy, tm);
}

/* SAI fetched serial `ser` (WTPacket). The first fetch of a packet counts. */
static void wtc_st_fetch(WTC_STARTTRACE *tr, uint32_t t, uint32_t ser) {
    if (!tr->active) return;
    for (int i = 0; i < tr->n; i++) {
        WTC_ST_PKT *p = &tr->pk[i];
        if (p->posted && p->ser == ser && !p->fetched) {
            p->fetched = 1; p->t_fetch = t - tr->t0; p->fetch_ord = tr->ord++;
            return;
        }
    }
}

/* SAI took a WM_LBUTTONDOWN at screen (x, y). Only the first one per stroke. */
static void wtc_st_click(WTC_STARTTRACE *tr, uint32_t t, int32_t x, int32_t y) {
    tr->have_last_click = 1; tr->last_click_t = t; tr->last_cx = x; tr->last_cy = y;
    if (!tr->active || tr->clicked) return;
    tr->clicked = 1;
    tr->click_ord = tr->ord++;
    tr->click_dt = (int32_t)(t - tr->t0);
    tr->cx = x; tr->cy = y;
    tr->have_last_click = 0;            /* used up by this stroke */
}

static int wtc_st_due(const WTC_STARTTRACE *tr, uint32_t now) {
    return tr->active && (uint32_t)(now - tr->t0) >= WTC_ST_REPORT_MS;
}

/* Packets SAI fetched before it took the click: the ones at risk. */
static int wtc_st_before_click(const WTC_STARTTRACE *tr) {
    int k = 0;
    for (int i = 0; i < tr->n; i++)
        if (tr->pk[i].fetched && (!tr->clicked || tr->pk[i].fetch_ord < tr->click_ord)) k++;
    return k;
}

/* Which traced packet sits nearest the click, in screen pixels. -1: no click.
 * In double, not long long: two 32-bit coordinates far apart square past what
 * a 64-bit integer holds (the sanitizer run in tests/ caught exactly that). */
static int wtc_st_nearest(const WTC_STARTTRACE *tr, double *dist2) {
    int best = -1; double bd = 0;
    if (!tr->clicked) return -1;
    for (int i = 0; i < tr->n; i++) {
        double dx = (double)tr->pk[i].sx - tr->cx, dy = (double)tr->pk[i].sy - tr->cy;
        double d = dx * dx + dy * dy;
        if (best < 0 || d < bd) { best = i; bd = d; }
    }
    if (dist2) *dist2 = bd;
    return best;
}

/* The one log line, then the trace is closed. Returns the length written
 * (always NUL-terminated, cut short if `cap` is too small). */
static int wtc_st_format(WTC_STARTTRACE *tr, char *out, size_t cap) {
    size_t len = 0;
    /* `near` and `far` are macros in the Windows headers: no locals by those names */
    #define WTC_ST_PUT(...) do { \
        if (len < cap) { \
            int w_ = snprintf(out + len, cap - len, __VA_ARGS__); \
            if (w_ > 0) len += (size_t)w_; \
            if (len >= cap) len = cap - 1; \
        } \
    } while (0)
    if (!out || cap == 0) { tr->active = 0; return 0; }
    out[0] = '\0';
    WTC_ST_PUT("START before-click=%d of %d", wtc_st_before_click(tr), tr->n);
    if (tr->clicked) {
        double d2 = 0;
        int closest = wtc_st_nearest(tr, &d2);
        WTC_ST_PUT(" click=%+dms@(%d,%d) nearest=#%d", (int)tr->click_dt,
                   (int)tr->cx, (int)tr->cy, closest);
    } else {
        WTC_ST_PUT(" click=none");
    }
    if (tr->n > 0 && tr->pk[0].has_t && !tr->pk[0].ev_bad) {
        /* how long packet #0 sat in the app. Only believed when small: the two
         * clocks are compared directly here, the one place that is done. */
        uint32_t lag = wtc_wire_diff(tr->tm0.tx, tr->tm0.ev);
        if (lag < 1000000u) WTC_ST_PUT(" lag0=%u.%ums", lag / 1000u, (lag % 1000u) / 100u);
    }
    if (tr->ended) WTC_ST_PUT(" lifted");
    if (tr->extra) WTC_ST_PUT(" +%d more", tr->extra);
    for (int i = 0; i < tr->n; i++) {
        const WTC_ST_PKT *p = &tr->pk[i];
        WTC_ST_PUT(" | #%d +%ums", i, (unsigned)p->t_post);
        if (p->has_t && p->ev_bad)
            WTC_ST_PUT(" ev+? tx+%u.%u skip=%d",
                       (unsigned)(p->tx_us / 1000u), (unsigned)((p->tx_us % 1000u) / 100u), p->skip);
        else if (p->has_t)
            WTC_ST_PUT(" ev+%u.%u tx+%u.%u skip=%d",
                       (unsigned)(p->ev_us / 1000u), (unsigned)((p->ev_us % 1000u) / 100u),
                       (unsigned)(p->tx_us / 1000u), (unsigned)((p->tx_us % 1000u) / 100u), p->skip);
        WTC_ST_PUT(" p=%d (%d,%d)", p->press, (int)p->sx, (int)p->sy);
        if (!p->posted)       WTC_ST_PUT(" merged");
        else if (!p->fetched) WTC_ST_PUT(" unfetched");
        else WTC_ST_PUT(" got+%ums %s", (unsigned)p->t_fetch,
                        (tr->clicked && p->fetch_ord > tr->click_ord) ? "after" : "BEFORE");
    }
    #undef WTC_ST_PUT
    tr->active = 0;
    return (int)len;
}

/* ---- THE REST OF THE STROKE, FOR COMPARISON ---------------------------------
 * The trace above only sees the first WTC_ST_WINDOW_MS of a stroke. A late
 * sample there means something only if samples are NOT late like that further
 * on, so this keeps the longest gap between two samples for the rest of the
 * stroke, on the same three clocks, and writes one "MID ..." line at pen-up.
 *
 * Only gaps between samples where the pen MOVED are counted. A pen held still
 * mid-stroke sends nothing new (the app drops repeats), and that silence is
 * not a delay; counting it would make every thoughtful stroke look broken. */
#define WTC_MID_MOVE_PX 4

typedef struct {
    int       active;
    uint32_t  t0;
    int       have_prev;
    uint32_t  prev_t;
    WTC_TIMES prev_tm;
    int32_t   px, py;
    int       pairs;            /* gaps measured */
    int       timed;            /* ...of which with app times */
    int       timed_ev;         /* ...of which with a usable event time at both ends */
    uint32_t  max_recv;         /* ms */
    uint32_t  max_ev, max_tx;   /* us */
    uint32_t  skipped;          /* samples the app handled but did not send */
} WTC_MIDSTAT;

static void wtc_mid_down(WTC_MIDSTAT *m, uint32_t t) {
    memset(m, 0, sizeof *m);
    m->active = 1; m->t0 = t;
}

/* every pen-DOWN sample of the stroke after the first */
static void wtc_mid_sample(WTC_MIDSTAT *m, uint32_t t, int32_t sx, int32_t sy, const WTC_TIMES *tm) {
    if (!m->active) return;
    if ((uint32_t)(t - m->t0) <= WTC_ST_WINDOW_MS) return;     /* the trace's part */
    if (m->have_prev) {
        long long dx = (long long)sx - m->px, dy = (long long)sy - m->py;
        int both = tm && tm->has && m->prev_tm.has;
        if (dx < 0) dx = -dx;
        if (dy < 0) dy = -dy;
        if (both) m->skipped += wtc_wire_diff(tm->n, m->prev_tm.n) - 1u;
        if (dx + dy >= WTC_MID_MOVE_PX) {
            uint32_t g = t - m->prev_t;
            m->pairs++;
            if (g > m->max_recv) m->max_recv = g;
            if (both) {
                uint32_t ge = wtc_wire_diff(tm->ev, m->prev_tm.ev);
                uint32_t gt = wtc_wire_diff(tm->tx, m->prev_tm.tx);
                m->timed++;
                if (gt > m->max_tx) m->max_tx = gt;
                if (!tm->ev_bad && !m->prev_tm.ev_bad) {
                    m->timed_ev++;
                    if (ge > m->max_ev) m->max_ev = ge;
                }
            }
        }
    }
    m->have_prev = 1; m->prev_t = t; m->px = sx; m->py = sy;
    if (tm) m->prev_tm = *tm; else m->prev_tm.has = 0;
}

/* Pen-up: the line, and the stroke is closed. Returns 0 (and an empty line)
 * for a stroke too short to have a middle. */
static int wtc_mid_format(WTC_MIDSTAT *m, char *out, size_t cap) {
    int w = 0;
    int was = m->active;
    m->active = 0;
    if (!out || cap == 0) return 0;
    out[0] = '\0';
    if (!was || m->pairs == 0) return 0;
    if (m->timed && !m->timed_ev)
        w = snprintf(out, cap, "MID gaps=%d longest: recv=%ums ev=? tx=%u.%ums skipped=%u",
                     m->pairs, (unsigned)m->max_recv,
                     (unsigned)(m->max_tx / 1000u), (unsigned)((m->max_tx % 1000u) / 100u),
                     (unsigned)m->skipped);
    else if (m->timed)
        w = snprintf(out, cap, "MID gaps=%d longest: recv=%ums ev=%u.%ums tx=%u.%ums skipped=%u",
                     m->pairs, (unsigned)m->max_recv,
                     (unsigned)(m->max_ev / 1000u), (unsigned)((m->max_ev % 1000u) / 100u),
                     (unsigned)(m->max_tx / 1000u), (unsigned)((m->max_tx % 1000u) / 100u),
                     (unsigned)m->skipped);
    else
        w = snprintf(out, cap, "MID gaps=%d longest: recv=%ums", m->pairs, (unsigned)m->max_recv);
    if (w < 0) { out[0] = '\0'; return 0; }
    return w >= (int)cap ? (int)cap - 1 : w;
}

/* ---- A PEN-DOWN THAT GOT NO CLICK (diagnostic, debug log only) --------------
 * SAI starts a stroke on the mouse click Wine makes from the pen touch, not on
 * our packets. A field log (2026-11-13) holds a quick stroke where every packet
 * of ours reached SAI and was read, Wine delivered no click at all, and the
 * canvas did not change: the whole stroke was lost. One in about 120 strokes,
 * cause unknown.
 *
 * This does NOT try to repair that. Supplying the click ourselves means
 * rewriting SAI's mouse messages, the one place that has stopped the pen from
 * drawing altogether twice (#19); it is not done blind. It only records what
 * SAI's UI thread DID receive while the click was missing, so the next
 * occurrence comes with its own explanation: was Wine following the cursor at
 * all (mouse moves), did the click go somewhere else (a non-client click,
 * another window), or was there simply nothing.
 *
 * The tally counts mouse messages SAI took off its queue between pen-down and
 * the stroke-start report. Message numbers are the Win32 ones, spelled out
 * here because this file is also compiled on the Mac for the tests. */
#define WTC_WM_NCMOUSEMOVE   0x00A0
#define WTC_WM_NCLBUTTONDOWN 0x00A1
#define WTC_WM_NCMOUSELAST   0x00AD
#define WTC_WM_MOUSEMOVE     0x0200
#define WTC_WM_LBUTTONDOWN   0x0201
#define WTC_WM_LBUTTONUP     0x0202
#define WTC_WM_LBUTTONDBLCLK 0x0203
#define WTC_WM_MOUSELAST     0x020E

typedef struct {
    int moves;        /* WM_MOUSEMOVE: Wine is following the cursor over SAI */
    int ldown;        /* WM_LBUTTONDOWN or WM_LBUTTONDBLCLK, any window: a click DID come */
    int lup;          /* WM_LBUTTONUP */
    int nc;           /* any non-client mouse message (title bar, menu, borders) */
    int nc_ldown;     /* ...of which WM_NCLBUTTONDOWN: the click landed on the frame */
    int other;        /* any other mouse message (right button, wheel, ...) */
    int other_root;   /* how many of all the above went to a window outside SAI's main one */
} WTC_NOCLICK;

/* Is this a mouse message at all? The hook asks before taking the lock. */
static int wtc_nc_is_mouse(unsigned msg) {
    return (msg >= WTC_WM_MOUSEMOVE && msg <= WTC_WM_MOUSELAST) ||
           (msg >= WTC_WM_NCMOUSEMOVE && msg <= WTC_WM_NCMOUSELAST);
}

static void wtc_nc_msg(WTC_NOCLICK *n, unsigned msg, int same_root) {
    if (!wtc_nc_is_mouse(msg)) return;
    if (!same_root) n->other_root++;
    if (msg == WTC_WM_MOUSEMOVE)                                       n->moves++;
    else if (msg == WTC_WM_LBUTTONDOWN || msg == WTC_WM_LBUTTONDBLCLK) n->ldown++;
    else if (msg == WTC_WM_LBUTTONUP)                                  n->lup++;
    else if (msg >= WTC_WM_NCMOUSEMOVE && msg <= WTC_WM_NCMOUSELAST) {
        n->nc++;
        if (msg == WTC_WM_NCLBUTTONDOWN) n->nc_ldown++;
    }
    else n->other++;
}

/* Did this pen-down go without a click?
 *
 * THE TRAP: the stroke-start trace's own `clicked` only knows clicks into
 * SAI's MAIN window. A pen tap in one of SAI's dialogs or floating panels is
 * clicked perfectly well, in another window, and the trace says click=none.
 * So "no click" needs both: the trace saw none (which also covers a click
 * that arrived just BEFORE our pen-down) and the tally saw none in ANY of
 * SAI's windows. */
static int wtc_nc_lost(int trace_clicked, const WTC_NOCLICK *n) {
    return !trace_clicked && n->ldown == 0;
}

/* The tally's part of the NOCLICK line. `move_age_ms` < 0: no mouse move has
 * been seen at all since SAI started. */
static int wtc_nc_format(const WTC_NOCLICK *n, long move_age_ms, char *out, size_t cap) {
    int w;
    if (!out || cap == 0) return 0;
    if (move_age_ms < 0)
        w = snprintf(out, cap, "moves=%d (none ever) up=%d frame=%d frame-click=%d other=%d elsewhere=%d",
                     n->moves, n->lup, n->nc, n->nc_ldown, n->other, n->other_root);
    else
        w = snprintf(out, cap, "moves=%d (last %ldms ago) up=%d frame=%d frame-click=%d other=%d elsewhere=%d",
                     n->moves, move_age_ms, n->lup, n->nc, n->nc_ldown, n->other, n->other_root);
    if (w < 0) { out[0] = '\0'; return 0; }
    return w >= (int)cap ? (int)cap - 1 : w;
}

/* ---- HOLD THE FIRST PEN-DOWN PACKETS UNTIL THE CLICK ------------------------
 * SAI starts a stroke on the mouse click Wine makes from the pen touch. The
 * field run of 2026-11-14 (85 strokes) showed SAI reading our first pen-down
 * packet BEFORE it took that click in 85 strokes of 85, and two to five packets
 * before it in 16 of them: the click arrives a median 8 ms after our packet,
 * and Windows hands a program posted messages (ours) before input (the click).
 * Whether SAI then throws those packets away is not known. This is the
 * experiment that finds out: keep the pen-down packets back until SAI's own
 * thread takes the click, then post them straight after it.
 *
 * What it must never do:
 *  - touch a mouse message. It only delays OUR packets. (Rewriting SAI's mouse
 *    messages is what stopped all drawing in #19.)
 *  - keep a packet for long. No click within WTC_HOLD_MAX_MS: post everything
 *    as it is, which is exactly the behaviour without the hold.
 *  - hold without a way to notice the click. Without the message hook nothing
 *    would ever release early and every stroke would start WTC_HOLD_MAX_MS
 *    late, so no hook means no hold.
 *  - hold when the click is ALREADY in: then there is nothing to wait for.
 *
 * Result (2026-11-14, one SAI session, switched both ways): with the hold, SAI
 * read our packets before the click in 0 strokes of 52 and no hold ran into
 * the time limit; without it, in 27 of 27, and the late stroke start was felt
 * again at once. So it is ALWAYS on, with no switch: without it SAI loses the
 * start of strokes, which is worse than the cost. The cost: the first points
 * reach SAI about 9 ms later, but SAI starts the stroke on the click, which
 * comes those same ~8 ms later anyway; and with no click at all, at most
 * WTC_HOLD_MAX_MS. (The C:\wt_hold.txt switch used for the comparison is
 * gone.) */
#define WTC_HOLD_MAX_MS   30   /* longest a pen-down packet is kept back */
#define WTC_HOLD_EARLY_MS 30   /* a click this soon before pen-down is this stroke's */
#define WTC_HOLD_CAP      8    /* packets kept; later ones replace the newest */

typedef struct {
    int      active;
    uint32_t t0;                     /* tick of the pen-down that started it */
    int      n;
    uint32_t ser[WTC_HOLD_CAP];      /* serials waiting to be posted, oldest first */
} WTC_HOLD;

/* Pen-down just happened: hold its packets? */
static int wtc_hold_should_start(int enabled, int hook_installed, int have_click,
                                 uint32_t now, uint32_t last_click_t) {
    if (!enabled || !hook_installed) return 0;
    if (have_click && (uint32_t)(now - last_click_t) <= WTC_HOLD_EARLY_MS) return 0;
    return 1;
}

static void wtc_hold_start(WTC_HOLD *h, uint32_t now) {
    memset(h, 0, sizeof *h);
    h->active = 1; h->t0 = now;
}

/* Has this hold run out of time? */
static int wtc_hold_expired(const WTC_HOLD *h, uint32_t now) {
    return h->active && (uint32_t)(now - h->t0) >= WTC_HOLD_MAX_MS;
}

/* One more pen-down packet while holding. Returns 1 when `ser` took a new
 * place in the line. Returns 0 when the line is full: the caller then writes
 * this packet over the NEWEST held one (*reuse is its serial), so the first
 * packet, the pen-down itself, is never the one given up. */
static int wtc_hold_add(WTC_HOLD *h, uint32_t ser, uint32_t *reuse) {
    if (h->n < WTC_HOLD_CAP) { h->ser[h->n++] = ser; return 1; }
    if (reuse) *reuse = h->ser[WTC_HOLD_CAP - 1];
    return 0;
}

/* Let go: copies the serials to post, oldest first, into out[WTC_HOLD_CAP] and
 * returns how many. The hold is over; a second call returns 0, so the click
 * and the time limit arriving together cannot post anything twice. */
static int wtc_hold_release(WTC_HOLD *h, uint32_t *out) {
    int n = h->active ? h->n : 0;
    for (int i = 0; i < n; i++) out[i] = h->ser[i];
    h->active = 0; h->n = 0;
    return n;
}

#endif /* WINTAB_CORE_H */
