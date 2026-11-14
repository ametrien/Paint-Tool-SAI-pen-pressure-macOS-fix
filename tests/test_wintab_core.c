/*
 * test_wintab_core.c — unit tests for wintab_core.h (the DLL's pure logic),
 * compiled NATIVELY with clang on macOS — no mingw, no Wine, no tablet.
 *
 * Run:  bash tests/run-tests.sh
 */
#include <string.h>
#include "../wintab-src/wintab_core.h"

static int failures = 0;
#define EXPECT(cond, name) do { \
    if (cond) printf("  ok   %s\n", name); \
    else { printf("  FAIL %s  (%s:%d)\n", name, __FILE__, __LINE__); failures++; } \
} while (0)

/* A sample exactly as wacom-helper builds it for global point (gx, gy) on a
 * desktop whose union is u: PressureCore.mapToVirtual + main.swift send(). */
static WTC_SAMPLE helper_sample(double gx, double gy, WTC_RECT u) {
    WTC_SAMPLE s = { 2000, 0, 0, 0, 0, 1 };
    s.x = (int)((gx - u.x) * 8);
    s.y = (int)(((u.y + u.h) - gy) * 8);
    s.w = u.w * 8;
    s.h = u.h * 8;
    return s;
}

/* The stroke-start trace without the app's times (an app from before they
 * were sent, or the file fallback): the DLL passes NULL for them. */
static void wtc_st_down(WTC_STARTTRACE *tr, uint32_t t, int posted, uint32_t ser,
                        int press, int32_t sx, int32_t sy) {
    wtc_st_down_t(tr, t, posted, ser, press, sx, sy, NULL);
}
static void wtc_st_sample(WTC_STARTTRACE *tr, uint32_t t, int down, int posted,
                          uint32_t ser, int press, int32_t sx, int32_t sy) {
    wtc_st_sample_t(tr, t, down, posted, ser, press, sx, sy, NULL);
}

int main(void) {
    printf("wintab_core tests:\n");

    /* --- wtc_parse_sample ------------------------------------------------- */
    WTC_SAMPLE s; memset(&s, 0, sizeof s);

    EXPECT(wtc_parse_sample("512 100 200 11520 7200", &s) == 1, "parse: full sample accepted");
    EXPECT(s.press == 512 && s.x == 100 && s.y == 200 && s.w == 11520 && s.h == 7200 && s.has_pos == 1,
           "parse: full sample fields");

    /* bare "p" (kill switch / pen-up without position): press updates,
     * position fields must be PRESERVED (stroke ends at last point) */
    EXPECT(wtc_parse_sample("0", &s) == 1, "parse: bare pressure accepted");
    EXPECT(s.press == 0 && s.has_pos == 0 && s.x == 100 && s.y == 200,
           "parse: bare pressure keeps last position fields");

    EXPECT(wtc_parse_sample("", &s) == 0, "parse: empty (torn read) rejected");
    EXPECT(wtc_parse_sample("garbage", &s) == 0, "parse: garbage rejected");
    EXPECT(wtc_parse_sample("-3", &s) == 0, "parse: negative pressure rejected");
    EXPECT(s.press == 0, "parse: rejected input leaves sample untouched");

    EXPECT(wtc_parse_sample("99999", &s) == 1 && s.press == WTC_MAX_PRESS,
           "parse: overshoot clamps to 1023");
    EXPECT(wtc_parse_sample("100 5 5 0 100", &s) == 1 && s.has_pos == 0,
           "parse: zero width -> position ignored (division guard)");
    EXPECT(wtc_parse_sample("   ", &s) == 0, "parse: whitespace-only rejected");
    EXPECT(wtc_parse_sample("  300 7 8 640 480", &s) == 1 && s.press == 300 && s.x == 7,
           "parse: leading whitespace tolerated");
    EXPECT(wtc_parse_sample("250\n", &s) == 1 && s.press == 250 && s.has_pos == 0,
           "parse: trailing newline, bare pressure");
    EXPECT(wtc_parse_sample("100 -50 -20 800 600", &s) == 1 && s.x == -50 && s.y == -20,
           "parse: negative coords accepted (multi-monitor origins)");

    /* --- wtc_map_to_out --------------------------------------------------- */
    int32_t x, y;
    /* identity-ish: out extent == in size -> coords pass through */
    WTC_SAMPLE m = { 512, 100, 200, 1000, 800, 1 };
    wtc_map_to_out(&m, 0, 0, 1000, 800, 32767, &x, &y);
    EXPECT(x == 100 && y == 200, "map: same-size spaces pass through (y-up)");

    /* y-down context (negative extY): y flips */
    wtc_map_to_out(&m, 0, 0, 1000, -800, 32767, &x, &y);
    EXPECT(x == 100 && y == (800 - 1 - 200), "map: negative extY flips to y-down");

    /* scaling: 2x output space */
    wtc_map_to_out(&m, 0, 0, 2000, 1600, 32767, &x, &y);
    EXPECT(x == 200 && y == 400, "map: 2x extent scales up");

    /* origin offset is added */
    wtc_map_to_out(&m, 50, 70, 1000, 800, 32767, &x, &y);
    EXPECT(x == 150 && y == 270, "map: origin offset applied");

    /* unconfigured context (ext 0) falls back to in_ext */
    wtc_map_to_out(&m, 0, 0, 0, 0, 32767, &x, &y);
    EXPECT(x == (int32_t)((int64_t)100 * 32767 / 1000), "map: zero extX falls back to in_ext");

    /* 64-bit intermediate: virtual-desktop-sized values must not overflow.
     * 8x fixed-point 4K-ish desktop: x=30000*8, w=30720*8, ext=30720*8. */
    WTC_SAMPLE big = { 1, 240000, 120000, 245760, 138240, 1 };
    wtc_map_to_out(&big, 0, 0, 245760, 138240, 32767, &x, &y);
    EXPECT(x == 240000 && y == 120000, "map: large fixed-point values don't overflow");

    /* divide-by-zero guard: w/h of 0 must degrade to the origin, not crash
     * (UBSan in the test build would trap an actual division by zero). */
    WTC_SAMPLE zerow = { 512, 100, 200, 0, 800, 1 };
    x = 999; y = 999;
    wtc_map_to_out(&zerow, 5, 7, 1000, 800, 32767, &x, &y);
    EXPECT(x == 5 && y == 7, "map: zero width degrades to origin (no divide-by-zero)");
    WTC_SAMPLE zeroh = { 512, 100, 200, 800, 0, 1 };
    wtc_map_to_out(&zeroh, 5, 7, 1000, 800, 32767, &x, &y);
    EXPECT(x == 5 && y == 7, "map: zero height degrades to origin (no divide-by-zero)");

    /* --- wtc_place: more than one screen (issue #37) ----------------------
     * THE TRAP these guard: scaling the helper's desktop straight into SAI's
     * area (wtc_map_to_out) is only right while both describe the SAME
     * rectangle. They stop doing so the moment a screen is connected,
     * unplugged, rearranged or switched between mirrored and extended while
     * SAI is open, and with a screen left of or above the main one. To see
     * these fail, make wtc_place() just call wtc_map_to_out() and return 1:
     * the #37 replay lands at x 537 instead of 960, and the left/above/unplug
     * cases fail with it. */
    {
        int32_t ox, oy, mx, my;
        int in;

        /* Single screen: must be EXACTLY the old answer, everywhere. Every
         * single-screen user depends on this not moving by one unit. */
        WTC_RECT one = { 0, 0, 1512, 982 };
        int same = 1, allin = 1;
        for (int gy = 0; gy < 982; gy += 97) for (int gx = 0; gx < 1512; gx += 151) {
            WTC_SAMPLE hs = helper_sample(gx + 0.375, gy + 0.625, one);
            in = wtc_place(&hs, one, one, 0, 0, 1512 * 8, 982 * 8, 32767, &ox, &oy);
            wtc_map_to_out(&hs, 0, 0, 1512 * 8, 982 * 8, 32767, &mx, &my);
            if (ox != mx || oy != my) same = 0;
            if (!in) allin = 0;
        }
        EXPECT(same, "place: one screen gives exactly the old mapping");
        EXPECT(allin, "place: one screen, every point is inside SAI's area");
        /* The far edges are INSIDE. A tablet maps its edge onto the screen's
         * edge, so the pen can report x == width exactly. Counting that as
         * outside ends the stroke and makes the pen step aside at the last
         * column of a single screen, which no single-screen user should ever
         * see. Every edge must also keep the old mapping to the unit. To see
         * this fail, make the x check in wtc_place() exclusive (lx < sw8). */
        {
            double edges[][2] = { {0, 0}, {1512, 0}, {0, 982}, {1512, 982}, {1512, 491}, {756, 982} };
            int edges_in = 1, edges_same = 1;
            for (int i = 0; i < 6; i++) {
                WTC_SAMPLE e = helper_sample(edges[i][0], edges[i][1], one);
                in = wtc_place(&e, one, one, 0, 0, 1512 * 8, 982 * 8, 32767, &ox, &oy);
                wtc_map_to_out(&e, 0, 0, 1512 * 8, 982 * 8, 32767, &mx, &my);
                if (!in) edges_in = 0;
                if (ox != mx || oy != my) edges_same = 0;
            }
            EXPECT(edges_in, "place: every edge and corner of a single screen is inside");
            EXPECT(edges_same, "place: edges keep exactly the old mapping too");
        }
        /* and with a y-down context, which some apps open */
        WTC_SAMPLE hs = helper_sample(100, 200, one);
        wtc_place(&hs, one, one, 0, 0, 1512 * 8, -982 * 8, 32767, &ox, &oy);
        wtc_map_to_out(&hs, 0, 0, 1512 * 8, -982 * 8, 32767, &mx, &my);
        EXPECT(ox == mx && oy == my, "place: one screen, y-down context unchanged too");

        /* EVERY sub-pixel position on one screen, at the scalings people use.
         * THE TRAP: the helper sends the pen in 1/8 px, and SAI asks for the
         * same: its context in the field log is out ext 10816x7024 on a
         * 1352x878 screen, 8 units per pixel. If any step rounds to whole
         * pixels, strokes still land in the right place, so nothing looks
         * broken, but every line snaps to the pixel grid and drawing feels
         * less precise. This came up after #37 ("not as precise as before"),
         * and the grid above checks only one fraction (3/8, 5/8) at 1512x982.
         *
         * Two checks, because they catch different breakages:
         *   same:  wtc_place() == wtc_map_to_out(), the v0.3.6 mapping. Fails
         *          when wtc_place() rounds (e.g. lx = (wx8 / 8) * 8).
         *   exact: with SAI's 8-units-per-pixel area, out == the helper's
         *          value, unit for unit. Fails when wtc_map_to_out() itself
         *          rounds, which "same" cannot see: both would round alike.
         * x and y are mapped independently, so one full row plus one full
         * column, edges included, covers every value either can take.
         *
         * 1352x878 the screen in the "less precise" session (log);
         * 1512x982 the MacBook Pro 14" default; 1168x755, 1800x1169 its other
         * choices; 3024x1964 the same panel with Wine's Retina mode on;
         * 1920x1080, 2560x1440, 1440x900 common external screens. */
        {
            static const int res[][2] = { {1352, 878}, {1512, 982}, {1168, 755}, {1800, 1169},
                                          {3024, 1964}, {1920, 1080}, {2560, 1440}, {1440, 900} };
            long diff = 0, inexact = 0, outside = 0;
            for (unsigned r = 0; r < sizeof res / sizeof res[0]; r++) {
                int w = res[r][0], h = res[r][1];
                WTC_RECT scr = { 0, 0, w, h };
                for (int ydown = 0; ydown < 2; ydown++) {
                    int32_t eX = w * 8, eY = ydown ? -h * 8 : h * 8;
                    for (int col = 0; col < 2; col++) {
                        int n = col ? h * 8 : w * 8;
                        for (int v = 0; v <= n; v++) {
                            WTC_SAMPLE s = { 2000, w * 4, h * 4, w * 8, h * 8, 1 };
                            if (col) s.y = v; else s.x = v;
                            in = wtc_place(&s, scr, scr, 0, 0, eX, eY, 32767, &ox, &oy);
                            wtc_map_to_out(&s, 0, 0, eX, eY, 32767, &mx, &my);
                            if (ox != mx || oy != my) diff++;
                            if (!in) outside++;
                            if (!ydown && (ox != s.x || oy != s.y)) inexact++;
                        }
                    }
                }
            }
            EXPECT(diff == 0, "place: every 1/8 px on one screen, 8 scalings: exactly the v0.3.6 mapping");
            EXPECT(inexact == 0, "place: SAI's 8-per-pixel area gets the helper's 1/8 px unchanged, no rounding");
            EXPECT(outside == 0, "place: every 1/8 px on one screen, edges included, is inside");
        }

        /* #37 replay, numbers from the field log: SAI opened while the TV was
         * MIRRORED (area 1920x1080), then the laptop was extended to the
         * right of the TV, 139 pt lower. Desktop now 3432x1121. */
        WTC_RECT ext   = { 0, 0, 3432, 1121 };
        WTC_RECT stale = { 0, 0, 1920, 1080 };
        hs = helper_sample(960, 540, ext);                      /* TV centre */
        in = wtc_place(&hs, ext, stale, 0, 0, 15360, 8640, 32767, &ox, &oy);
        EXPECT(in, "place #37: TV centre is inside the area SAI opened with");
        EXPECT(ox == 960 * 8, "place #37: TV centre lands at x 960 (old code: 537, a fifth to the left)");
        EXPECT(oy == (1080 - 540) * 8, "place #37: TV centre lands at y 540 (old code: 520, too high)");
        wtc_map_to_out(&hs, 0, 0, 15360, 8640, 32767, &mx, &my);
        EXPECT(mx / 8 == 537, "place #37: (the old mapping really did put it at 537)");
        hs = helper_sample(10, 10, ext);                        /* TV top-left */
        wtc_place(&hs, ext, stale, 0, 0, 15360, 8640, 32767, &ox, &oy);
        EXPECT(ox == 80 && oy == (1080 - 10) * 8, "place #37: TV top-left corner exact");
        hs = helper_sample(1900, 1070, ext);                    /* TV bottom-right */
        wtc_place(&hs, ext, stale, 0, 0, 15360, 8640, 32767, &ox, &oy);
        EXPECT(ox == 1900 * 8 && oy == (1080 - 1070) * 8, "place #37: TV bottom-right corner exact");
        hs = helper_sample(1920 + 756, 139 + 491, ext);         /* laptop centre */
        in = wtc_place(&hs, ext, stale, 0, 0, 15360, 8640, 32767, &ox, &oy);
        EXPECT(!in, "place #37: laptop (added after SAI opened) is reported as outside");
        EXPECT(ox == 15360 - 1, "place #37: outside points are clamped, never wrapped");

        /* Screen to the LEFT of the main one: the desktop starts at x -1920.
         * The point on the main screen must land on the main screen whether
         * SAI's area starts at 0 (what v0.3.6 told it) or at -1920. */
        WTC_RECT left = { -1920, 0, 3432, 1080 };
        WTC_RECT sys0 = { 0, 0, 3432, 1080 };
        hs = helper_sample(756, 491, left);                     /* main centre */
        in = wtc_place(&hs, left, sys0, 0, 0, 3432 * 8, 1080 * 8, 32767, &ox, &oy);
        EXPECT(in && ox == 756 * 8, "place left: main centre at x 756 in an area that starts at 0");
        wtc_map_to_out(&hs, 0, 0, 3432 * 8, 1080 * 8, 32767, &mx, &my);
        EXPECT(mx == (1920 + 756) * 8, "place left: (old mapping put it 1920 to the right, off the screen)");
        in = wtc_place(&hs, left, left, 0, 0, 3432 * 8, 1080 * 8, 32767, &ox, &oy);
        EXPECT(in && ox == (1920 + 756) * 8, "place left: same point in an area that starts at -1920");
        hs = helper_sample(-960, 540, left);                    /* left screen centre */
        in = wtc_place(&hs, left, left, 0, 0, 3432 * 8, 1080 * 8, 32767, &ox, &oy);
        EXPECT(in && ox == 960 * 8 && oy == (1080 - 540) * 8, "place left: left screen reachable when SAI's area starts there");

        /* Screen ABOVE the main one: the desktop starts at y -1080. */
        WTC_RECT above = { 0, -1080, 1920, 2062 };
        hs = helper_sample(756, 491, above);
        in = wtc_place(&hs, above, above, 0, 0, 1920 * 8, 2062 * 8, 32767, &ox, &oy);
        int32_t sx, sy;
        wtc_sample_to_screen(&hs, above, &sx, &sy);
        EXPECT(sx == 756 && sy == 491, "place above: sample means Windows point (756,491)");
        EXPECT(in && ox == 756 * 8 && oy == (982 - 491) * 8, "place above: main centre exact (y measured from the bottom)");

        /* TV UNPLUGGED while SAI ran: SAI's area is still the old 3432x1121,
         * the desktop is now the laptop alone, at a new origin. */
        WTC_RECT laptop = { 0, 0, 1352, 878 };
        hs = helper_sample(676, 439, laptop);
        in = wtc_place(&hs, laptop, ext, 0, 0, 3432 * 8, 1121 * 8, 32767, &ox, &oy);
        EXPECT(in && ox == 676 * 8 && oy == (1121 - 439) * 8, "place unplug: laptop centre stays exact in the bigger old area");
        wtc_map_to_out(&hs, 0, 0, 3432 * 8, 1121 * 8, 32767, &mx, &my);
        EXPECT(mx != ox, "place unplug: (old mapping stretched it across the old area)");

        /* Wine in Retina mode: Windows works in pixels (2x), the helper in
         * points. The fraction makes the unit difference disappear. */
        WTC_RECT px = { 0, 0, 3024, 1964 }, pt = { 0, 0, 1512, 982 };
        hs = helper_sample(756, 491, pt);
        in = wtc_place(&hs, px, px, 0, 0, 3024 * 8, 1964 * 8, 32767, &ox, &oy);
        EXPECT(in && ox == 1512 * 8 && oy == (1964 - 982) * 8, "place retina: points map onto the pixel desktop");

        /* Nothing usable to go on: behave exactly like before. */
        WTC_RECT none = { 0, 0, 0, 0 };
        hs = helper_sample(100, 200, one);
        in = wtc_place(&hs, none, one, 0, 0, 1512 * 8, 982 * 8, 32767, &ox, &oy);
        wtc_map_to_out(&hs, 0, 0, 1512 * 8, 982 * 8, 32767, &mx, &my);
        EXPECT(in && ox == mx && oy == my, "place: unknown desktop falls back to the old mapping");
        in = wtc_place(&hs, one, none, 0, 0, 1512 * 8, 982 * 8, 32767, &ox, &oy);
        EXPECT(in && ox == mx && oy == my, "place: unknown SAI area falls back to the old mapping");
        WTC_SAMPLE bad = { 512, 1, 1, 0, 0, 1 };
        in = wtc_place(&bad, one, one, 3, 4, 1000, 800, 32767, &ox, &oy);
        EXPECT(in && ox == 3 && oy == 4, "place: zero-size sample cannot divide by zero");

        /* round trip used by the cursor fallback */
        WTC_SAMPLE back = wtc_screen_to_sample(&hs, left, -100, 700);
        wtc_sample_to_screen(&back, left, &sx, &sy);
        EXPECT(sx == -100 && sy == 700, "place: screen -> sample -> screen round trip, negative origin");
        EXPECT(back.press == hs.press && back.has_pos == hs.has_pos, "place: round trip keeps pressure and has_pos");
    }

    /* --- wtc_cursor_streak (self-check against Wine's cursor) ------------- */
    EXPECT(wtc_cursor_streak(0, 100, 100, 100, 100, 48) == 0, "selfcheck: agreeing point keeps streak 0");
    EXPECT(wtc_cursor_streak(5, 100, 100, 148, 52, 48) == 0, "selfcheck: exactly at tolerance agrees, resets streak");
    EXPECT(wtc_cursor_streak(5, 100, 100, 149, 100, 48) == 6, "selfcheck: one past tolerance counts");
    EXPECT(wtc_cursor_streak(0, 960, 540, 537, 520, 48) == 1, "selfcheck: the #37 offset is caught");
    EXPECT(wtc_cursor_streak(1000000, 0, 0, 999, 999, 48) == 1000000, "selfcheck: streak saturates, no overflow");

    /* --- asking SAI to re-read its tablet area (#37) -----------------------
     * THE TRAP: these values are what sai2.exe compares against (its jump
     * table for messages 0x7FF1..0x7FF7 re-reads contexts only at 0x7FF4, and
     * only in the window proc of class sflWintabCtrlWindow). Nothing in the
     * build would notice a change; SAI would just stop re-reading. To see
     * these fail: set WTC_CTXOVERLAP_OFFSET to 3, or misspell the class. */
    EXPECT(0x7ff0 + WTC_CTXOVERLAP_OFFSET == 0x7ff4, "reread: WT_CTXOVERLAP is base+4, the case SAI re-reads on");
    EXPECT(wtc_sai_rereads_on_overlap("sflWintabCtrlWindow"), "reread: SAI's WinTab control window re-reads");
    EXPECT(!wtc_sai_rereads_on_overlap("sflRootWindow"), "reread: SAI's main window never re-reads");
    EXPECT(!wtc_sai_rereads_on_overlap("sflwintabctrlwindow"), "reread: exact spelling (GetClassName returns it as SAI registered it)");
    EXPECT(!wtc_sai_rereads_on_overlap(""), "reread: unknown class, no message");
    EXPECT(!wtc_sai_rereads_on_overlap(NULL), "reread: no class, no message");

    /* --- wtc_selfcheck_step: a frozen cursor is not evidence ---------------
     * THE TRAP: Wine's cursor freezes, still inside SAI's window, when the pen
     * hovers onto another screen. The old check counted every such sample and
     * after 20 of them switched the DLL to following that frozen cursor (field
     * log 2026-11-06: "pen at (1510,623) but Wine's cursor at (2109,544) for 20
     * samples"). To see these fail: make wtc_selfcheck_step() count every
     * sample (drop the `frozen` test) and the replay trips; make it skip
     * whenever the cursor did not move and the still-pen case goes blind;
     * make a frozen sample reset the streak and the interleaved case does. */
    {
        const int need = WTC_SELFCHECK_NEED, tol = WTC_SELFCHECK_TOL;
        WTC_SELFCHECK sc;
        int st, maxst;

        /* Replay of the field log. Laptop at x 1920..3432, TV at 0..1920.
         * The pen hovers over SAI on the laptop with the cursor following it,
         * then leaves for the TV: our position keeps moving, the cursor stays
         * where it last was over SAI. Then the pen comes back. */
        memset(&sc, 0, sizeof sc);
        maxst = 0;
        for (int i = 0; i < 10; i++) {                      /* over SAI, cursor live */
            st = wtc_selfcheck_step(&sc, 2200 - 9 * i, 560, 2200 - 9 * i, 560, tol);
            if (st > maxst) maxst = st;
        }
        int32_t frozenX = 2200 - 9 * 9, frozenY = 560;
        for (int i = 1; i <= 60; i++) {                     /* onto the TV, cursor frozen */
            st = wtc_selfcheck_step(&sc, frozenX - 12 * i, 560 + i, frozenX, frozenY, tol);
            if (st > maxst) maxst = st;
        }
        EXPECT(maxst < need, "selfcheck: hovering onto another screen (frozen cursor) never trips it");
        EXPECT(maxst == 0, "selfcheck: and the frozen samples do not even count");
        st = wtc_selfcheck_step(&sc, 2036, 753, 2036, 753, tol);   /* back over SAI */
        EXPECT(st == 0, "selfcheck: back over SAI with a live cursor, all clear");

        /* A real fault must still be caught: our mapping squeezed as in #37
         * while the cursor is live (both move). */
        memset(&sc, 0, sizeof sc);
        for (int i = 0; i < need; i++) {
            int32_t cx = 960 + 8 * i;
            st = wtc_selfcheck_step(&sc, cx * 1920 / 3432, 540, cx, 540, tol);
        }
        EXPECT(st == need, "selfcheck: a wrong mapping with a live cursor trips after exactly NEED samples");

        /* Both standing still and apart: nothing is frozen there, so it
         * counts. (The helper drops exact duplicates, so this is rare, but a
         * check that only works while moving is not a check.) */
        memset(&sc, 0, sizeof sc);
        for (int i = 0; i < need; i++) st = wtc_selfcheck_step(&sc, 537, 540, 960, 540, tol);
        EXPECT(st == need, "selfcheck: pen and cursor still and apart still count");

        /* A frozen sample neither counts nor clears: 10 real disagreements,
         * 5 frozen-cursor samples, 10 more real ones. */
        memset(&sc, 0, sizeof sc);
        for (int i = 0; i < 10; i++) st = wtc_selfcheck_step(&sc, 500 + i, 540, 960 + i, 540, tol);
        int32_t fx = 960 + 9;
        for (int i = 1; i <= 5; i++) st = wtc_selfcheck_step(&sc, 509 + 3 * i, 540, fx, 540, tol);
        EXPECT(st == 10, "selfcheck: frozen samples leave the streak where it was");
        for (int i = 1; i <= 10; i++) st = wtc_selfcheck_step(&sc, 530 + i, 540, 980 + i, 540, tol);
        EXPECT(st == 20, "selfcheck: and the real disagreements on both sides add up");

        /* The ordinary case stays quiet: a live cursor trailing by up to the
         * tolerance during a hover. */
        memset(&sc, 0, sizeof sc);
        maxst = 0;
        for (int i = 0; i < 100; i++) {
            st = wtc_selfcheck_step(&sc, 400 + 6 * i, 300, 400 + 6 * i - (i % 9) * 5, 300, tol);
            if (st > maxst) maxst = st;
        }
        EXPECT(maxst == 0, "selfcheck: a cursor trailing within tolerance never counts");
    }

    /* --- wtc_format_screens ------------------------------------------------ */
    {
        char b[64];
        EXPECT(wtc_format_screens(b, sizeof b, 1, 0) > 0 && !strcmp(b, "newscreen=1\nmismatch=0\n"),
               "screens status: both lines, exact text the app parses");
        EXPECT(wtc_format_screens(b, sizeof b, 0, 7) > 0 && !strcmp(b, "newscreen=0\nmismatch=1\n"),
               "screens status: any true value is written as 1");
        char tiny[4];
        EXPECT(wtc_format_screens(tiny, sizeof tiny, 1, 1) == 0 && tiny[0] == '\0',
               "screens status: too small writes nothing");
    }

    /* --- wtc_should_post (conflation) -------------------------------------- */
    /* serial=next to assign, fetched=last consumed; window = 3 */
    EXPECT(wtc_should_post(1, 0, 0, 3) == 1, "conflate: nothing outstanding -> post");
    EXPECT(wtc_should_post(3, 0, 0, 3) == 1, "conflate: 2 outstanding < 3 -> post");
    EXPECT(wtc_should_post(4, 0, 0, 3) == 0, "conflate: 3 outstanding -> conflate");
    EXPECT(wtc_should_post(10, 9, 0, 3) == 1, "conflate: SAI caught up -> post again");
    EXPECT(wtc_should_post(10, 2, 1, 3) == 1, "conflate: tip transition ALWAYS posts");

    /* --- wtc_should_eat_click (#19, and its v0.1.10 recurrence) ------------ */
    /* Eating a WM_LBUTTONDOWN destroys the stroke it would have started, so a
     * wrong "yes" here stops the pen drawing at all. That has shipped TWICE.
     * These cases are therefore exhaustive rather than representative.
     * "eats" == message rewritten to WM_NULL, SAI never sees it. */

    /* THE REGRESSION. v0.1.10 installed the hook for scroll->pan (on by
     * default) while want_dedup was 0, and click_hook_proc checked only the
     * timing window. The field log showed, 2 ms after a real pen-down:
     *     msg hook: dedup=off scroll-pan=on
     *     CLICK dedup: ate msg=0x201 hwnd=... dt=2ms total=1
     * i.e. the de-dup reporting itself off and eating the stroke anyway. */
    EXPECT(wtc_should_eat_click(0, 2, WTC_CLICK_DEDUP_MS, 1) == 0,
           "dedup OFF: click 2ms after pen-down SURVIVES (#19 / v0.1.10 regression)");

    /* The invariant that actually protects drawing: when the de-dup was not
     * requested, nothing is eaten anywhere in the parameter space. Any future
     * feature that installs this shared hook trips this immediately. */
    {
        int off_ate = 0;
        for (unsigned long d = 0; d <= 1000; d++)
            for (int root = 0; root <= 1; root++)
                if (wtc_should_eat_click(0, d, WTC_CLICK_DEDUP_MS, root)) off_ate++;
        EXPECT(off_ate == 0, "dedup OFF: eats nothing across dt 0..1000ms x both targets");
    }

    /* Opt-in still works — #8's double-click fix is intact for those who want it. */
    EXPECT(wtc_should_eat_click(1, 2, WTC_CLICK_DEDUP_MS, 1) == 1,
           "dedup ON: eats the duplicate click 2ms after pen-down (#8 fix)");
    EXPECT(wtc_should_eat_click(1, 0, WTC_CLICK_DEDUP_MS, 1) == 1,
           "dedup ON: eats at dt=0 (same tick as the tip transition)");

    /* Window boundary is EXCLUSIVE (dt < dedup_ms). Pinned so a future edit
     * cannot quietly widen or narrow it by one millisecond. */
    EXPECT(wtc_should_eat_click(1, WTC_CLICK_DEDUP_MS - 1, WTC_CLICK_DEDUP_MS, 1) == 1,
           "dedup ON: eats at 399ms (last ms inside the window)");
    EXPECT(wtc_should_eat_click(1, WTC_CLICK_DEDUP_MS, WTC_CLICK_DEDUP_MS, 1) == 0,
           "dedup ON: does NOT eat at exactly 400ms (boundary exclusive)");
    EXPECT(wtc_should_eat_click(1, WTC_CLICK_DEDUP_MS + 1, WTC_CLICK_DEDUP_MS, 1) == 0,
           "dedup ON: does not eat at 401ms (just past the window)");
    EXPECT(wtc_should_eat_click(1, 60000, WTC_CLICK_DEDUP_MS, 1) == 0,
           "dedup ON: does not eat a click a minute later (deliberate mouse click)");

    /* Scoping: only messages aimed at SAI's own root window are candidates. */
    EXPECT(wtc_should_eat_click(1, 2, WTC_CLICK_DEDUP_MS, 0) == 0,
           "dedup ON: never eats a click aimed at another root window");
    EXPECT(wtc_should_eat_click(0, 2, WTC_CLICK_DEDUP_MS, 0) == 0,
           "dedup OFF + foreign window: survives");

    /* Every term is load-bearing: drop any one and the click must survive.
     * v0.1.10 dropped precisely the first. */
    EXPECT(wtc_should_eat_click(0, 2, WTC_CLICK_DEDUP_MS, 1) == 0 &&
           wtc_should_eat_click(1, WTC_CLICK_DEDUP_MS, WTC_CLICK_DEDUP_MS, 1) == 0 &&
           wtc_should_eat_click(1, 2, WTC_CLICK_DEDUP_MS, 0) == 0 &&
           wtc_should_eat_click(1, 2, WTC_CLICK_DEDUP_MS, 1) == 1,
           "dedup: all three terms required — dropping any one spares the click");

    /* Replay of the captured field log (v0.1.10, Intuos BT S, Wine 11.13):
     * both of these were eaten while dedup reported off — 0x201 cost the
     * stroke, 0x202 the release. Both must now survive. */
    EXPECT(wtc_should_eat_click(0, 2,   WTC_CLICK_DEDUP_MS, 1) == 0 &&
           wtc_should_eat_click(0, 302, WTC_CLICK_DEDUP_MS, 1) == 0,
           "field replay: WM_LBUTTONDOWN(dt=2ms) and WM_LBUTTONUP(dt=302ms) both survive");

    /* --- wtc_format_status ------------------------------------------------
     * The DLL's one channel back to the app (#29). The app decides what to tell
     * the user from these seven lines, so the shape is a contract, not a log
     * format: keys it doesn't recognise are ignorable, but a field that changes
     * name or a truncated write would silently become "SAI never loaded us". */
    {
        char buf[256];
        int n = wtc_format_status(buf, sizeof buf, "Sep 10 2026 18:07:11", 1,
                                  1234, 1200, 1198, 4095);
        EXPECT(n > 0 && (size_t)n == strlen(buf), "status: returns the length written");
        EXPECT(strstr(buf, "v=1\n") == buf, "status: starts with the version marker");
        EXPECT(strstr(buf, "\nbuild=Sep 10 2026 18:07:11\n") != NULL, "status: build stamp, spaces and all");
        EXPECT(strstr(buf, "\nopen=1\n") != NULL, "status: open flag");
        EXPECT(strstr(buf, "\nrecv=1234\n") != NULL && strstr(buf, "\nposted=1200\n") != NULL,
               "status: what arrived and what we posted");
        EXPECT(strstr(buf, "\nfetched=1198\n") != NULL, "status: what SAI actually read");
        EXPECT(strstr(buf, "\npmax=4095\n") != NULL, "status: the pressure scale in force");

        /* open=0 is a DIAGNOSIS ("SAI never asked for a tablet"), so it has to
         * survive the round trip rather than be omitted as a falsy value. */
        n = wtc_format_status(buf, sizeof buf, "b", 0, 0, 0, 0, 1023);
        EXPECT(n > 0 && strstr(buf, "\nopen=0\n") != NULL, "status: closed context is written, not skipped");

        /* A half-written status parses as a confident lie, so a buffer that
         * cannot hold the whole thing must produce nothing at all. */
        char small[8];
        EXPECT(wtc_format_status(small, sizeof small, "Sep 10 2026", 1, 1, 1, 1, 1023) == 0 &&
               small[0] == '\0',
               "status: too small a buffer writes nothing rather than a truncation");
        EXPECT(wtc_format_status(NULL, 0, "b", 1, 1, 1, 1, 1023) == 0, "status: no buffer, no crash");
        EXPECT(wtc_format_status(buf, sizeof buf, NULL, 1, 1, 1, 1, 1023) > 0 &&
               strstr(buf, "\nbuild=unknown\n") != NULL,
               "status: a missing build stamp says so");
    }

    /* --- which program loaded us (SAI going inactive, 2026-11-11) ---------
     * A Test pen probe left running loaded this same DLL and ran the wake,
     * taking the Windows foreground away from SAI every time. These pin who
     * counts as the probe: a false "no" lets the probe fight SAI again, a
     * false "yes" takes the wake away from SAI. */
    {
        /* the probe, as Wine reports its own exe path, and other spellings */
        EXPECT(wtc_host_is_probe("Z:\\Applications\\SAI Pen Pressure.app\\Contents\\Resources\\wtprobe.exe") == 1,
               "host: the probe, as Wine names it, is the probe");
        EXPECT(wtc_host_is_probe("/Applications/SAI Pen Pressure.app/Contents/Resources/wtprobe.exe") == 1,
               "host: the probe by a Mac path is the probe");
        EXPECT(wtc_host_is_probe("wtprobe.exe") == 1, "host: a bare probe name is the probe");
        EXPECT(wtc_host_is_probe("Z:\\APPS\\WTPROBE.EXE") == 1 && wtc_host_is_probe("C:\\x\\WtProbe.Exe") == 1,
               "host: Windows paths ignore case, so the probe in capitals is still the probe");

        /* SAI, under every name it has shipped as: must keep its wake */
        EXPECT(wtc_host_is_probe("C:\\SAI2\\sai2.exe") == 0, "host: SAI2 is not the probe");
        EXPECT(wtc_host_is_probe("C:\\PaintToolSAI\\sai.exe") == 0, "host: SAI Ver.1 is not the probe");
        EXPECT(wtc_host_is_probe("C:\\Program Files\\SAI\\My SAI copy.exe") == 0,
               "host: a renamed SAI is not the probe");

        /* one character either side of the name, and the name in the wrong place */
        EXPECT(wtc_host_is_probe("C:\\x\\mywtprobe.exe") == 0, "host: a longer name ending in wtprobe.exe is not the probe");
        EXPECT(wtc_host_is_probe("C:\\x\\wtprobe.exe.bak") == 0, "host: wtprobe.exe plus more is not the probe");
        EXPECT(wtc_host_is_probe("C:\\x\\wtprobe.ex") == 0, "host: one letter short is not the probe");
        EXPECT(wtc_host_is_probe("C:\\wtprobe.exe\\sai2.exe") == 0,
               "host: a FOLDER called wtprobe.exe does not make SAI the probe");
        EXPECT(wtc_host_is_probe("C:\\x\\wtprobe.exe\\") == 0, "host: a path ending in a separator names no file");

        /* unknown host: SAI must not lose its wake because the lookup failed */
        EXPECT(wtc_host_is_probe(NULL) == 0, "host: unknown (NULL) is not the probe");
        EXPECT(wtc_host_is_probe("") == 0, "host: unknown (empty) is not the probe");
    }

    /* --- the wake request, as each process sees it --------------------------
     * Replays what the wake log showed: SAI and the probe both watching
     * C:\wt_wake.txt, each with its own memory of the last value. */
    {
        char saiLast[32] = "", probeLast[32] = "";
        const int SAI = 0, PROBE = 1;

        /* the value already in the file at load is an old request */
        EXPECT(wtc_wake_requested("3", saiLast, sizeof saiLast, SAI) == 0,
               "wake: SAI ignores the request left over from before it started");
        EXPECT(wtc_wake_requested("3", probeLast, sizeof probeLast, PROBE) == 0,
               "wake: the probe ignores it too");

        /* THE FAILING CASE: the helper asks for a wake */
        EXPECT(wtc_wake_requested("4", saiLast, sizeof saiLast, SAI) == 1,
               "wake: SAI wakes when the helper asks");
        EXPECT(wtc_wake_requested("4", probeLast, sizeof probeLast, PROBE) == 0,
               "wake: THE BUG: the probe must NOT wake (it would take the foreground from SAI)");

        /* once per request, not once per look at the file (~6 per second) */
        EXPECT(wtc_wake_requested("4", saiLast, sizeof saiLast, SAI) == 0,
               "wake: SAI does not wake again for the same request");
        EXPECT(wtc_wake_requested("5", saiLast, sizeof saiLast, SAI) == 1 &&
               wtc_wake_requested("5", probeLast, sizeof probeLast, PROBE) == 0,
               "wake: the next request wakes SAI and still not the probe");
        /* a new app session counts from 1 again: a change is a change */
        EXPECT(wtc_wake_requested("1", saiLast, sizeof saiLast, SAI) == 1,
               "wake: a lower number after an app restart is still a new request");

        /* nothing to compare: never a wake, never a crash */
        EXPECT(wtc_wake_requested(NULL, saiLast, sizeof saiLast, SAI) == 0, "wake: no marker, no wake");
        EXPECT(wtc_wake_requested("9", NULL, 32, SAI) == 0, "wake: no memory, no wake");
        EXPECT(wtc_wake_requested("9", saiLast, 0, SAI) == 0, "wake: zero-size memory, no wake");
    }

    /* --- retrying the pen port ----------------------------------------------
     * Before: one try at load, then "file mode only" for the whole session. */
    {
        EXPECT(wtc_should_retry_bind(1, 5000, 0, WTC_PORT_RETRY_MS) == 0,
               "port: holding the port, never retry");
        EXPECT(wtc_should_retry_bind(0, 999, 0, WTC_PORT_RETRY_MS) == 0,
               "port: taken, 999 ms after the last try: wait");
        EXPECT(wtc_should_retry_bind(0, 1000, 0, WTC_PORT_RETRY_MS) == 1,
               "port: taken, 1000 ms after the last try: THE FIX: try again");
        EXPECT(wtc_should_retry_bind(0, 1001, 0, WTC_PORT_RETRY_MS) == 1,
               "port: taken, 1001 ms after: try again");
        EXPECT(wtc_should_retry_bind(0, 61000, 60000, WTC_PORT_RETRY_MS) == 1,
               "port: keeps retrying for as long as the port stays taken");

        /* GetTickCount() wraps after 49.7 days of uptime; Macs stay up that long */
        uint32_t before = 0xFFFFFE00u;            /* 512 ms before the wrap */
        EXPECT(wtc_should_retry_bind(0, before + 999u, before, WTC_PORT_RETRY_MS) == 0,
               "port: across the 32-bit tick wrap, 999 ms: wait");
        EXPECT(wtc_should_retry_bind(0, before + 1000u, before, WTC_PORT_RETRY_MS) == 1,
               "port: across the 32-bit tick wrap, 1000 ms: try again");
        /* The case `now >= last_try + interval` gets wrong: the last try was
         * just before the wrap, the clock has since wrapped to a small number,
         * and that form would wait another 49.7 days to try again. */
        uint32_t lastTry = 0xFFFFF000u;           /* 4096 ms before the wrap */
        EXPECT(wtc_should_retry_bind(0, lastTry + 5000u, lastTry, WTC_PORT_RETRY_MS) == 1,
               "port: last try before the wrap, clock now past it: try again, not in 49 days");
        /* ...and the other way round: the deadline wraps, the clock has not yet */
        EXPECT(wtc_should_retry_bind(0, before + 256u, before, WTC_PORT_RETRY_MS) == 0,
               "port: 256 ms after a try just before the wrap: still wait");
    }

    /* --- stroke-start trace (wtc_st_*) ------------------------------------
     * Diagnostic for "the very beginning of a stroke is not captured". The
     * number that matters is how many of the first packets SAI fetched BEFORE
     * it took Wine's click, because that click is what starts SAI's stroke. */
    {
        WTC_STARTTRACE tr; memset(&tr, 0, sizeof tr);
        char line[1024];

        /* The usual shape from the field log: pen-down packet, SAI fetches it,
         * then Wine's click arrives 6 ms later, then the next packets. */
        wtc_st_down(&tr, 1000, 1, 50, 529, 100, 200);
        wtc_st_fetch(&tr, 1001, 50);
        wtc_st_click(&tr, 1006, 101, 201);
        wtc_st_sample(&tr, 1008, 1, 1, 51, 700, 104, 204);
        wtc_st_fetch(&tr, 1008, 51);
        EXPECT(wtc_st_before_click(&tr) == 1, "start: the packet fetched before the click is counted");
        EXPECT(tr.click_dt == 6, "start: click time is measured from pen-down");
        EXPECT(wtc_st_due(&tr, 1119) == 0, "start: not reported before the report delay");
        EXPECT(wtc_st_due(&tr, 1120) == 1, "start: reported once the report delay has passed");
        wtc_st_format(&tr, line, sizeof line);
        EXPECT(strstr(line, "START before-click=1 of 2") != NULL, "start: line leads with the count");
        EXPECT(strstr(line, "click=+6ms@(101,201) nearest=#0") != NULL,
               "start: line gives the click's time, place and nearest packet");
        EXPECT(strstr(line, "#0 +0ms p=529 (100,200) got+1ms BEFORE") != NULL,
               "start: packet #0 reads as fetched BEFORE the click");
        EXPECT(strstr(line, "#1 +8ms p=700 (104,204) got+8ms after") != NULL,
               "start: packet #1 reads as fetched after the click");
        EXPECT(tr.active == 0 && wtc_st_due(&tr, 5000) == 0, "start: formatting closes the trace");

        /* THE TRAP (see wintab_core.h): the fetch and the click in the SAME
         * millisecond. Only the order they happened in can say which came
         * first; a tick compare would call both of these the same. */
        memset(&tr, 0, sizeof tr);
        wtc_st_down(&tr, 2000, 1, 60, 300, 0, 0);
        wtc_st_fetch(&tr, 2003, 60);
        wtc_st_click(&tr, 2003, 0, 0);
        EXPECT(wtc_st_before_click(&tr) == 1, "start: same tick, fetch then click -> before");
        memset(&tr, 0, sizeof tr);
        wtc_st_down(&tr, 2000, 1, 60, 300, 0, 0);
        wtc_st_click(&tr, 2003, 0, 0);
        wtc_st_fetch(&tr, 2003, 60);
        EXPECT(wtc_st_before_click(&tr) == 0, "start: same tick, click then fetch -> after");

        /* Wine's click reaches SAI before our first packet: it still belongs to
         * this stroke, at a negative time, and nothing is "before" it. */
        memset(&tr, 0, sizeof tr);
        wtc_st_click(&tr, 2990, 7, 8);                 /* no stroke yet: just remembered */
        EXPECT(tr.clicked == 0, "start: a click with no stroke open is only remembered");
        wtc_st_down(&tr, 3000, 1, 70, 400, 7, 8);
        wtc_st_fetch(&tr, 3001, 70);
        EXPECT(tr.clicked == 1 && tr.click_dt == -10, "start: click 10 ms before pen-down is matched, at -10 ms");
        EXPECT(wtc_st_before_click(&tr) == 0, "start: nothing comes before a click that came first");
        wtc_st_format(&tr, line, sizeof line);
        EXPECT(strstr(line, "click=-10ms@(7,8)") != NULL, "start: line shows the early click as negative");
        /* ...and it is used up: the next stroke does not inherit it */
        wtc_st_down(&tr, 3010, 1, 80, 400, 0, 0);
        EXPECT(tr.clicked == 0, "start: an early click is matched to one stroke only");

        /* A click from long before (31 ms) is some other click, not this stroke's */
        memset(&tr, 0, sizeof tr);
        wtc_st_click(&tr, 4000 - (WTC_ST_EARLY_MS + 1), 0, 0);
        wtc_st_down(&tr, 4000, 1, 90, 400, 0, 0);
        EXPECT(tr.clicked == 0, "start: a click 31 ms before pen-down is not this stroke's");
        memset(&tr, 0, sizeof tr);
        wtc_st_click(&tr, 4000 - WTC_ST_EARLY_MS, 0, 0);
        wtc_st_down(&tr, 4000, 1, 90, 400, 0, 0);
        EXPECT(tr.clicked == 1, "start: a click exactly 30 ms before pen-down is");

        /* no click at all: the line says so, and every fetch counts as before */
        memset(&tr, 0, sizeof tr);
        wtc_st_down(&tr, 5000, 1, 100, 400, 0, 0);
        wtc_st_fetch(&tr, 5002, 100);
        EXPECT(wtc_st_before_click(&tr) == 1, "start: no click -> fetched packets are all before it");
        wtc_st_format(&tr, line, sizeof line);
        EXPECT(strstr(line, "click=none") != NULL && wtc_st_nearest(&tr, NULL) == -1,
               "start: no click -> 'click=none', no nearest packet");

        /* Only the FIRST click of a stroke counts; a second (Wine's mouse
         * bouncing mid-stroke, seen in the field log) must not move it. */
        memset(&tr, 0, sizeof tr);
        wtc_st_down(&tr, 6000, 1, 110, 400, 0, 0);
        wtc_st_click(&tr, 6005, 1, 1);
        wtc_st_click(&tr, 6040, 9, 9);
        EXPECT(tr.click_dt == 5 && tr.cx == 1, "start: a second click does not replace the first");

        /* A merged packet (conflated, never posted) shows as merged; a fetch
         * of a serial we never traced changes nothing; a fetch counts once. */
        memset(&tr, 0, sizeof tr);
        wtc_st_down(&tr, 7000, 1, 120, 400, 0, 0);
        wtc_st_sample(&tr, 7007, 1, 0, 0, 500, 0, 0);  /* posted=0 */
        wtc_st_fetch(&tr, 7008, 999);
        EXPECT(tr.pk[0].fetched == 0 && tr.pk[1].fetched == 0, "start: an untraced serial marks nothing");
        wtc_st_fetch(&tr, 7009, 0);                    /* serial 0 = the merged one's zeroed ser */
        EXPECT(tr.pk[1].fetched == 0, "start: a merged packet can never be marked fetched");
        wtc_st_fetch(&tr, 7010, 120);
        wtc_st_fetch(&tr, 7030, 120);
        EXPECT(tr.pk[0].t_fetch == 10, "start: a packet fetched twice keeps its first fetch time");
        wtc_st_format(&tr, line, sizeof line);
        EXPECT(strstr(line, "#1 +7ms p=500 (0,0) merged") != NULL, "start: merged packet reads 'merged'");

        /* posted but never fetched */
        memset(&tr, 0, sizeof tr);
        wtc_st_down(&tr, 7500, 1, 130, 400, 0, 0);
        wtc_st_format(&tr, line, sizeof line);
        EXPECT(strstr(line, "#0 +0ms p=400 (0,0) unfetched") != NULL, "start: unfetched packet reads 'unfetched'");

        /* the window: samples after it are not traced; past MAX they are counted */
        memset(&tr, 0, sizeof tr);
        wtc_st_down(&tr, 8000, 1, 1, 400, 0, 0);
        wtc_st_sample(&tr, 8000 + WTC_ST_WINDOW_MS, 1, 1, 2, 400, 0, 0);
        wtc_st_sample(&tr, 8000 + WTC_ST_WINDOW_MS + 1, 1, 1, 3, 400, 0, 0);
        EXPECT(tr.n == 2, "start: a sample at the window edge is in, one after it is out");
        memset(&tr, 0, sizeof tr);
        wtc_st_down(&tr, 9000, 1, 1, 400, 0, 0);
        for (int i = 0; i < WTC_ST_MAX + 2; i++)
            wtc_st_sample(&tr, 9001 + (uint32_t)i, 1, 1, (uint32_t)(2 + i), 400, 0, 0);
        EXPECT(tr.n == WTC_ST_MAX && tr.extra == 3, "start: past the cap, packets are counted, not stored");
        wtc_st_format(&tr, line, sizeof line);
        EXPECT(strstr(line, " +3 more") != NULL, "start: the line says how many more there were");

        /* a tap: the pen lifts inside the window, and nothing after it is traced */
        memset(&tr, 0, sizeof tr);
        wtc_st_down(&tr, 10000, 1, 1, 400, 0, 0);
        wtc_st_sample(&tr, 10007, 0, 1, 2, 0, 0, 0);
        wtc_st_sample(&tr, 10014, 1, 1, 3, 400, 0, 0);
        EXPECT(tr.ended == 1 && tr.n == 1, "start: pen-up ends the trace; samples after it are not added");
        wtc_st_format(&tr, line, sizeof line);
        EXPECT(strstr(line, " lifted") != NULL, "start: a tap's line says 'lifted'");

        /* nothing happens while no stroke is open */
        memset(&tr, 0, sizeof tr);
        wtc_st_sample(&tr, 11000, 1, 1, 1, 400, 0, 0);
        wtc_st_fetch(&tr, 11000, 1);
        EXPECT(tr.n == 0 && tr.active == 0 && wtc_st_due(&tr, 99999) == 0,
               "start: samples and fetches with no stroke open do nothing");

        /* nearest packet to the click, by distance */
        memset(&tr, 0, sizeof tr);
        wtc_st_down(&tr, 12000, 1, 1, 400, 0, 0);
        wtc_st_sample(&tr, 12007, 1, 1, 2, 400, 10, 0);
        wtc_st_sample(&tr, 12014, 1, 1, 3, 400, 20, 0);
        wtc_st_click(&tr, 12006, 11, 1);
        double d2 = -1;
        EXPECT(wtc_st_nearest(&tr, &d2) == 1 && d2 == 2.0, "start: nearest packet is the closest one, with its distance");

        /* GetTickCount wraps after 49.7 days: times across the wrap stay small */
        memset(&tr, 0, sizeof tr);
        uint32_t w0 = 0xFFFFFFF0u;                      /* 16 ms before the wrap */
        wtc_st_down(&tr, w0, 1, 1, 400, 0, 0);
        wtc_st_sample(&tr, w0 + 20u, 1, 1, 2, 400, 0, 0);
        wtc_st_click(&tr, w0 + 25u, 0, 0);
        EXPECT(tr.n == 2 && tr.pk[1].t_post == 20 && tr.click_dt == 25,
               "start: across the 32-bit tick wrap, times stay right");
        EXPECT(wtc_st_due(&tr, w0 + WTC_ST_REPORT_MS - 1u) == 0 && wtc_st_due(&tr, w0 + WTC_ST_REPORT_MS) == 1,
               "start: across the tick wrap, the report comes on time");

        /* A short buffer cuts the line short but never overruns it (ASan
         * would stop the run). Full trace, longest line we can make. */
        memset(&tr, 0, sizeof tr);
        wtc_st_down(&tr, 13000, 1, 4000000000u, 8191, -2000000000, -2000000000);
        for (int i = 0; i < WTC_ST_MAX + 5; i++)
            wtc_st_sample(&tr, 13001 + (uint32_t)i, 1, 1, (uint32_t)i, 8191, -2000000000, 2000000000);
        for (int i = 0; i < WTC_ST_MAX; i++) wtc_st_fetch(&tr, 13050, (uint32_t)i);
        wtc_st_click(&tr, 13055, -2000000000, -2000000000);
        WTC_STARTTRACE copy = tr;
        char small[40];
        int n = wtc_st_format(&tr, small, sizeof small);
        EXPECT(n == (int)sizeof small - 1 && small[sizeof small - 1] == '\0',
               "start: a short buffer is filled and terminated, not overrun");
        n = wtc_st_format(&copy, line, sizeof line);
        EXPECT(n < (int)sizeof line - 1, "start: the longest line fits the DLL's 1024-byte buffer");
        EXPECT(wtc_st_format(&copy, NULL, 0) == 0, "start: no buffer at all is refused safely");
    }

    /* --- datagram with times (wtc_parse_datagram) -------------------------- */
    {
        WTC_DGRAM d;
        EXPECT(wtc_parse_datagram("7 512 100 200 11520 7200 1000 1500 42", &d) == 1 &&
               d.seq == 7 && d.p == 512 && d.x == 100 && d.y == 200 && d.w == 11520 && d.h == 7200,
               "datagram: the six sample fields");
        EXPECT(d.tm.has == 1 && d.tm.ev == 1000 && d.tm.tx == 1500 && d.tm.n == 42,
               "datagram: the three times are read");
        /* an app from before the times existed: still a good sample, no times */
        EXPECT(wtc_parse_datagram("7 512 100 200 11520 7200", &d) == 1 && d.tm.has == 0 && d.p == 512,
               "datagram: six fields from an older app -> sample, no times");
        /* a datagram cut short must not be read as having times */
        EXPECT(wtc_parse_datagram("7 512 100 200 11520 7200 1000 1500", &d) == 1 && d.tm.has == 0,
               "datagram: two of the three time fields -> no times at all");
        EXPECT(wtc_parse_datagram("7 512 100 200 11520", &d) == 0, "datagram: five fields is not a sample");
        EXPECT(wtc_parse_datagram("7 -1 100 200 11520 7200 1 2 3", &d) == 0, "datagram: negative pressure rejected");
        EXPECT(wtc_parse_datagram("", &d) == 0 && wtc_parse_datagram("garbage", &d) == 0,
               "datagram: empty and garbage rejected");
        /* the app masks to 31 bits; a stray larger value is masked, not trusted */
        EXPECT(wtc_parse_datagram("1 1 0 0 8 8 4294967295 2147483648 3", &d) == 1 &&
               d.tm.ev == 0x7FFFFFFFu && d.tm.tx == 0,
               "datagram: time fields are masked to 31 bits");

        /* wire values wrap at 2^31: the difference must not */
        EXPECT(wtc_wire_diff(5, 0x7FFFFFFBu) == 10, "wire: difference across the 2^31 wrap");
        EXPECT(wtc_wire_diff(1000, 400) == 600, "wire: plain difference");
    }

    /* --- stroke-start trace with the app's times --------------------------- */
    {
        WTC_STARTTRACE tr; memset(&tr, 0, sizeof tr);
        char line[2048];

        /* THE CASE THIS EXISTS FOR, three ways. The second sample reaches us
         * 35 ms after the first each time; the three clocks say why.
         *  (a) the tablet made it late:   ev +35.0, tx +35.1
         *  (b) the app sent it late:      ev  +7.5, tx +35.1
         *  (c) Wine received it late:     ev  +7.5, tx  +7.6          */
        WTC_TIMES t0 = { 1, 1000000, 1000300, 500, 0 };
        WTC_TIMES ta = { 1, 1035000, 1035400, 501, 0 };
        WTC_TIMES tb = { 1, 1007500, 1035400, 501, 0 };
        WTC_TIMES tc = { 1, 1007500, 1007900, 501, 0 };

        wtc_st_down_t(&tr, 1000, 1, 50, 529, 100, 200, &t0);
        wtc_st_sample_t(&tr, 1035, 1, 1, 51, 700, 104, 204, &ta);
        wtc_st_format(&tr, line, sizeof line);
        EXPECT(strstr(line, "#1 +35ms ev+35.0 tx+35.1 skip=0 p=700") != NULL,
               "times: tablet late -> ev shows the gap");
        EXPECT(strstr(line, " lag0=0.3ms") != NULL, "times: lag0 is packet #0's wait inside the app");
        EXPECT(strstr(line, "#0 +0ms ev+0.0 tx+0.0 skip=0 p=529") != NULL, "times: packet #0 is the zero of both clocks");

        wtc_st_down_t(&tr, 1000, 1, 50, 529, 100, 200, &t0);
        wtc_st_sample_t(&tr, 1035, 1, 1, 51, 700, 104, 204, &tb);
        wtc_st_format(&tr, line, sizeof line);
        EXPECT(strstr(line, "#1 +35ms ev+7.5 tx+35.1 skip=0") != NULL,
               "times: app late -> ev on time, tx shows the gap");

        wtc_st_down_t(&tr, 1000, 1, 50, 529, 100, 200, &t0);
        wtc_st_sample_t(&tr, 1035, 1, 1, 51, 700, 104, 204, &tc);
        wtc_st_format(&tr, line, sizeof line);
        EXPECT(strstr(line, "#1 +35ms ev+7.5 tx+7.6 skip=0") != NULL,
               "times: Wine late -> ev and tx on time, only our +ms shows the gap");

        /* skip: the app handled 4 samples since the last one it sent (n went
         * up by 4), so 3 were held back by its own rules */
        WTC_TIMES tskip = { 1, 1030000, 1030400, 504, 0 };
        wtc_st_down_t(&tr, 1000, 1, 50, 529, 0, 0, &t0);
        wtc_st_sample_t(&tr, 1030, 1, 1, 51, 700, 0, 0, &tskip);
        EXPECT(tr.pk[1].skip == 3, "times: n up by 4 between two sends -> 3 skipped");
        /* ...and it is counted from the sample BEFORE, even one past the cap */
        memset(&tr, 0, sizeof tr);
        wtc_st_down_t(&tr, 1000, 1, 1, 400, 0, 0, &t0);
        for (int i = 1; i < WTC_ST_MAX; i++) {
            WTC_TIMES t = { 1, 1000000u + (uint32_t)i * 1000u, 1000300u + (uint32_t)i * 1000u, 500u + (uint32_t)i, 0 };
            wtc_st_sample_t(&tr, 1000 + (uint32_t)i, 1, 1, (uint32_t)(1 + i), 400, 0, 0, &t);
        }
        EXPECT(tr.pk[WTC_ST_MAX - 1].skip == 0, "times: back-to-back sends -> skip 0");

        /* across the 2^31 wrap of the wire clock: still 7.5 ms, not 35 minutes */
        WTC_TIMES w0 = { 1, 0x7FFFFFFFu - 1000u, 0x7FFFFFFFu - 700u, 0x7FFFFFFFu, 0 };
        WTC_TIMES w1 = { 1, 6499u, 6899u, 0, 0 };                 /* n wrapped to 0 too */
        wtc_st_down_t(&tr, 1000, 1, 50, 529, 0, 0, &w0);
        wtc_st_sample_t(&tr, 1008, 1, 1, 51, 700, 0, 0, &w1);
        EXPECT(tr.pk[1].ev_us == 7500 && tr.pk[1].tx_us == 7600 && tr.pk[1].skip == 0,
               "times: across the 2^31 wrap, intervals and skip stay right");

        /* An OLD app (no times) with this DLL: the line is exactly the old one */
        wtc_st_down(&tr, 1000, 1, 50, 529, 100, 200);
        wtc_st_sample(&tr, 1008, 1, 1, 51, 700, 104, 204);
        wtc_st_format(&tr, line, sizeof line);
        EXPECT(strstr(line, "ev+") == NULL && strstr(line, "lag0") == NULL &&
               strstr(line, "#1 +8ms p=700 (104,204)") != NULL,
               "times: none sent -> no time fields, the line reads as before");

        /* Times that appear mid-trace (packet #0 had none) have no zero to be
         * measured from: left out rather than shown against garbage. */
        wtc_st_down(&tr, 1000, 1, 50, 529, 0, 0);
        wtc_st_sample_t(&tr, 1008, 1, 1, 51, 700, 0, 0, &ta);
        EXPECT(tr.pk[1].has_t == 0, "times: packet #0 had none -> later ones are not shown either");

        /* lag0 is only believed when small (under a second) */
        WTC_TIMES odd = { 1, 5000000, 1000, 1, 0 };
        wtc_st_down_t(&tr, 1000, 1, 50, 529, 0, 0, &odd);
        wtc_st_format(&tr, line, sizeof line);
        EXPECT(strstr(line, "lag0") == NULL, "times: an absurd lag0 (clocks disagree) is not printed");

        /* the longest line, now with times, still fits the DLL's buffer */
        WTC_TIMES big = { 1, 0x7FFFFFFFu, 0x7FFFFFFFu, 0x7FFFFFFFu, 0 };
        WTC_TIMES z   = { 1, 0, 0, 0, 0 };
        wtc_st_down_t(&tr, 13000, 1, 4000000000u, 8191, -2000000000, -2000000000, &z);
        for (int i = 0; i < WTC_ST_MAX + 5; i++)
            wtc_st_sample_t(&tr, 13001 + (uint32_t)i, 1, 1, (uint32_t)i, 8191, -2000000000, 2000000000, &big);
        for (int i = 0; i < WTC_ST_MAX; i++) wtc_st_fetch(&tr, 13050, (uint32_t)i);
        wtc_st_click(&tr, 13055, -2000000000, -2000000000);
        int n = wtc_st_format(&tr, line, sizeof line);
        EXPECT(n < (int)sizeof line - 1, "times: the longest line fits the DLL's 2048-byte buffer");
    }

    /* --- the rest of the stroke (wtc_mid_*) -------------------------------- */
    {
        WTC_MIDSTAT m; char line[256];
        WTC_TIMES a = { 1, 100000, 100300, 10, 0 };

        /* samples inside the trace's own window are not this line's business */
        wtc_mid_down(&m, 1000);
        wtc_mid_sample(&m, 1030, 0, 0, &a);
        wtc_mid_sample(&m, 1060, 50, 0, &a);
        EXPECT(m.pairs == 0, "mid: samples in the first 60 ms are left to the START line");
        EXPECT(wtc_mid_format(&m, line, sizeof line) == 0 && line[0] == '\0',
               "mid: a stroke with no middle writes no line");

        /* a moving stroke: gaps of 8, 40 and 8 ms; the 40 is the longest */
        wtc_mid_down(&m, 1000);
        WTC_TIMES s1 = { 1, 200000, 200300, 20, 0 }, s2 = { 1, 208000, 208300, 21, 0 },
                  s3 = { 1, 215500, 248300, 22, 0 }, s4 = { 1, 223000, 256300, 25, 0 };
        wtc_mid_sample(&m, 1100, 0, 0, &s1);
        wtc_mid_sample(&m, 1108, 10, 0, &s2);
        wtc_mid_sample(&m, 1148, 20, 0, &s3);
        wtc_mid_sample(&m, 1156, 30, 0, &s4);
        EXPECT(m.pairs == 3 && m.max_recv == 40, "mid: the longest gap between moving samples is kept");
        EXPECT(m.max_ev == 8000 && m.max_tx == 40000, "mid: each clock keeps its own longest gap");
        EXPECT(m.skipped == 2, "mid: samples the app handled but did not send are added up");
        wtc_mid_format(&m, line, sizeof line);
        EXPECT(strcmp(line, "MID gaps=3 longest: recv=40ms ev=8.0ms tx=40.0ms skipped=2") == 0,
               "mid: the line");
        EXPECT(m.active == 0, "mid: formatting closes the stroke");

        /* THE TRAP: a pen held still mid-stroke. The app sends nothing while
         * nothing changes, so the next sample comes "late" and is not. Only
         * the gap before a sample that MOVED counts. */
        wtc_mid_down(&m, 1000);
        wtc_mid_sample(&m, 1100, 0, 0, NULL);
        wtc_mid_sample(&m, 1108, 10, 0, NULL);
        wtc_mid_sample(&m, 1900, 11, 1, NULL);     /* 792 ms later, moved 2 px: a rest */
        wtc_mid_sample(&m, 1908, 21, 1, NULL);
        EXPECT(m.pairs == 2 && m.max_recv == 8, "mid: a pause with the pen at rest is not a late sample");
        wtc_mid_format(&m, line, sizeof line);
        EXPECT(strcmp(line, "MID gaps=2 longest: recv=8ms") == 0, "mid: without app times, only our own clock is shown");
        /* exactly at the threshold counts as moved */
        wtc_mid_down(&m, 1000);
        wtc_mid_sample(&m, 1100, 0, 0, NULL);
        wtc_mid_sample(&m, 1150, 2, -2, NULL);
        EXPECT(m.pairs == 1 && m.max_recv == 50, "mid: moving exactly 4 px (2 + 2) counts as moved");

        /* nothing before pen-down, nothing after the line is written */
        memset(&m, 0, sizeof m);
        wtc_mid_sample(&m, 5000, 0, 0, NULL);
        wtc_mid_sample(&m, 5100, 90, 0, NULL);
        EXPECT(m.pairs == 0 && wtc_mid_format(&m, line, sizeof line) == 0, "mid: no stroke open -> nothing");

        /* far-apart coordinates must not overflow (sanitizer run) */
        wtc_mid_down(&m, 1000);
        wtc_mid_sample(&m, 1100, -2000000000, -2000000000, NULL);
        wtc_mid_sample(&m, 1108, 2000000000, 2000000000, NULL);
        EXPECT(m.pairs == 1, "mid: coordinates at both ends of the range do not overflow");
        /* a short buffer is terminated, not overrun */
        char tiny[12];
        int n = wtc_mid_format(&m, tiny, sizeof tiny);
        EXPECT(n == (int)sizeof tiny - 1 && tiny[sizeof tiny - 1] == '\0', "mid: a short buffer is cut, not overrun");
        /* tick wrap */
        wtc_mid_down(&m, 0xFFFFFF00u);
        wtc_mid_sample(&m, 0xFFFFFF00u + 100u, 0, 0, NULL);
        wtc_mid_sample(&m, 0xFFFFFF00u + 300u, 50, 0, NULL);   /* past the 32-bit wrap */
        EXPECT(m.pairs == 1 && m.max_recv == 200, "mid: across the 32-bit tick wrap, the gap stays right");
    }

    /* --- an event time the app could not vouch for (ev_bad) ----------------
     * THE TRAP: the field run of 2026-11-14 had the same `ev` on every sample.
     * The trace printed "ev+0.0" for every packet and "ev=0.0ms" for every
     * stroke, which is word for word what "the tablet delivered on time, the
     * app sent late" looks like. A time that cannot be trusted must print as
     * "?", and must not be counted. */
    {
        WTC_DGRAM d;
        WTC_STARTTRACE tr;
        WTC_MIDSTAT m;
        char line[1024];

        EXPECT(wtc_parse_datagram("7 512 100 200 11520 7200 1000 1500 42 1", &d) == 1 &&
               d.tm.has == 1 && d.tm.ev_bad == 0 && d.tm.ev == 1000, "evbad: tenth field 1 -> the event time is real");
        EXPECT(wtc_parse_datagram("7 512 100 200 11520 7200 0 1500 42 0", &d) == 1 &&
               d.tm.has == 1 && d.tm.ev_bad == 1 && d.tm.tx == 1500 && d.tm.n == 42,
               "evbad: tenth field 0 -> event time unknown, tx and n still good");
        EXPECT(wtc_parse_datagram("7 512 100 200 11520 7200 1000 1500 42", &d) == 1 &&
               d.tm.has == 1 && d.tm.ev_bad == 0, "evbad: nine fields (no flag) are taken at their word");
        EXPECT(wtc_parse_datagram("7 512 100 200 11520 7200 1000 1500 42 7", &d) == 1 && d.tm.ev_bad == 1,
               "evbad: only an exact 1 vouches for the time");

        /* the trace: the stuck stamp of the field run, now flagged */
        WTC_TIMES b0 = { 1, 777, 1000300, 500, 1 };
        WTC_TIMES b1 = { 1, 777, 1035400, 501, 1 };
        memset(&tr, 0, sizeof tr);
        wtc_st_down_t(&tr, 1000, 1, 50, 529, 0, 0, &b0);
        wtc_st_sample_t(&tr, 1035, 1, 1, 51, 700, 0, 0, &b1);
        wtc_st_format(&tr, line, sizeof line);
        EXPECT(strstr(line, "#1 +35ms ev+? tx+35.1 skip=0 p=700") != NULL,
               "evbad: an unknown event time prints as ?, with tx and skip intact");
        EXPECT(strstr(line, "ev+0.0") == NULL, "evbad: a stuck stamp never prints as 'on time'");
        EXPECT(strstr(line, "lag0") == NULL, "evbad: no lag0 from an unknown event time");

        /* packet #0 good, a later one bad: only that one is ? */
        WTC_TIMES g0 = { 1, 1000000, 1000300, 500, 0 };
        WTC_TIMES g1 = { 1, 0, 1008400, 501, 1 };
        WTC_TIMES g2 = { 1, 1016000, 1016300, 502, 0 };
        memset(&tr, 0, sizeof tr);
        wtc_st_down_t(&tr, 1000, 1, 50, 529, 0, 0, &g0);
        wtc_st_sample_t(&tr, 1008, 1, 1, 51, 700, 0, 0, &g1);
        wtc_st_sample_t(&tr, 1016, 1, 1, 52, 800, 0, 0, &g2);
        wtc_st_format(&tr, line, sizeof line);
        EXPECT(strstr(line, "lag0=0.3ms") != NULL && strstr(line, "#1 +8ms ev+? tx+8.1") != NULL &&
               strstr(line, "#2 +16ms ev+16.0 tx+16.0") != NULL,
               "evbad: one bad stamp in the middle does not spoil its neighbours");

        /* packet #0 bad: everything is measured from it, so nothing has an ev */
        memset(&tr, 0, sizeof tr);
        wtc_st_down_t(&tr, 1000, 1, 50, 529, 0, 0, &b0);
        wtc_st_sample_t(&tr, 1016, 1, 1, 52, 800, 0, 0, &g2);
        wtc_st_format(&tr, line, sizeof line);
        EXPECT(strstr(line, "#1 +16ms ev+? tx+16.0") != NULL,
               "evbad: measured from an unknown packet #0, a good stamp is still unknown");

        /* MID: gaps with a bad end are not counted for ev, but still for tx */
        WTC_TIMES m1 = { 1, 5, 200300, 20, 1 }, m2 = { 1, 5, 240300, 21, 1 };
        wtc_mid_down(&m, 1000);
        wtc_mid_sample(&m, 1100, 0, 0, &m1);
        wtc_mid_sample(&m, 1140, 50, 0, &m2);
        EXPECT(m.timed == 1 && m.timed_ev == 0 && m.max_tx == 40000 && m.max_ev == 0,
               "evbad mid: a gap between unknown event times counts for tx only");
        wtc_mid_format(&m, line, sizeof line);
        EXPECT(strcmp(line, "MID gaps=1 longest: recv=40ms ev=? tx=40.0ms skipped=0") == 0,
               "evbad mid: no usable event time at all prints ev=?, never ev=0.0ms");
        /* one good pair among bad ones: its ev gap is the one reported */
        WTC_TIMES k0 = { 1, 300000, 300300, 30, 0 }, k1 = { 1, 309000, 309300, 31, 0 },
                  k2 = { 1, 0, 349300, 32, 1 };
        wtc_mid_down(&m, 1000);
        wtc_mid_sample(&m, 1100, 0, 0, &k0);
        wtc_mid_sample(&m, 1109, 50, 0, &k1);
        wtc_mid_sample(&m, 1149, 100, 0, &k2);
        EXPECT(m.timed == 2 && m.timed_ev == 1 && m.max_ev == 9000 && m.max_tx == 40000,
               "evbad mid: only the gap with a usable time at BOTH ends counts for ev");
    }

    /* --- hold the first pen-down packets until the click (wtc_hold_*) ------
     * Experimental. What must hold whatever SAI does with it: nothing is held
     * without a hook to notice the click, nothing is held for longer than the
     * limit, the pen-down packet itself is never given up, and nothing is
     * posted twice. */
    {
        WTC_HOLD h;
        uint32_t out[WTC_HOLD_CAP], reuse = 0;

        /* when to start */
        EXPECT(wtc_hold_should_start(1, 1, 0, 5000, 0) == 1, "hold: on, hook installed, no click yet -> hold");
        EXPECT(wtc_hold_should_start(0, 1, 0, 5000, 0) == 0, "hold: switched off -> never");
        /* THE TRAP: without the message hook nothing can release the hold
         * early, so EVERY stroke would start a full time limit late. */
        EXPECT(wtc_hold_should_start(1, 0, 0, 5000, 0) == 0, "hold: no hook to notice the click -> never");
        /* the click is already in: nothing to wait for */
        EXPECT(wtc_hold_should_start(1, 1, 1, 5000, 5000 - WTC_HOLD_EARLY_MS) == 0,
               "hold: a click just before pen-down is this stroke's -> do not hold");
        EXPECT(wtc_hold_should_start(1, 1, 1, 5000, 5000 - WTC_HOLD_EARLY_MS - 1) == 1,
               "hold: an older click was the last stroke's -> hold");
        EXPECT(wtc_hold_should_start(1, 1, 1, 10u, 0xFFFFFFF0u) == 0, "hold: 'just before' across the tick wrap");
        /* have_click = 0 means last_click_t is not a time at all: SAI freshly
         * started, tick still small */
        EXPECT(wtc_hold_should_start(1, 1, 0, 10, 0) == 1, "hold: no click ever, tick near 0 -> still hold");

        /* the time limit */
        wtc_hold_start(&h, 1000);
        EXPECT(h.active == 1 && h.n == 0, "hold: starts empty");
        EXPECT(wtc_hold_expired(&h, 1000 + WTC_HOLD_MAX_MS - 1) == 0, "hold: not over 1 ms before the limit");
        EXPECT(wtc_hold_expired(&h, 1000 + WTC_HOLD_MAX_MS) == 1, "hold: over at the limit");
        wtc_hold_start(&h, 0xFFFFFFF0u);
        EXPECT(wtc_hold_expired(&h, 0xFFFFFFF0u + 5u) == 0 && wtc_hold_expired(&h, 0xFFFFFFF0u + WTC_HOLD_MAX_MS) == 1,
               "hold: the limit across the tick wrap");
        memset(&h, 0, sizeof h);
        EXPECT(wtc_hold_expired(&h, 99999) == 0, "hold: nothing held never expires");

        /* order: released oldest first, once */
        wtc_hold_start(&h, 1000);
        EXPECT(wtc_hold_add(&h, 50, &reuse) == 1 && wtc_hold_add(&h, 51, &reuse) == 1, "hold: packets take their place in line");
        EXPECT(wtc_hold_release(&h, out) == 2 && out[0] == 50 && out[1] == 51, "hold: released oldest first");
        EXPECT(h.active == 0, "hold: release ends the hold");
        /* THE TRAP: the click (SAI's thread) and the time limit (ours) can both
         * fire for the same hold. The second must find nothing. */
        EXPECT(wtc_hold_release(&h, out) == 0, "hold: a second release posts nothing twice");

        /* a full line: the pen-down packet stays, the newest is replaced */
        wtc_hold_start(&h, 1000);
        for (uint32_t i = 0; i < WTC_HOLD_CAP; i++) wtc_hold_add(&h, 100 + i, &reuse);
        reuse = 0;
        EXPECT(wtc_hold_add(&h, 999, &reuse) == 0 && reuse == 100 + WTC_HOLD_CAP - 1,
               "hold: a full line takes no new serial and names the newest to overwrite");
        EXPECT(wtc_hold_release(&h, out) == WTC_HOLD_CAP && out[0] == 100 && out[WTC_HOLD_CAP - 1] == 100 + WTC_HOLD_CAP - 1,
               "hold: a full line still starts with the pen-down packet");

        /* a new stroke starts clean */
        wtc_hold_start(&h, 2000);
        wtc_hold_add(&h, 7, &reuse);
        wtc_hold_start(&h, 3000);
        EXPECT(h.n == 0 && wtc_hold_release(&h, out) == 0, "hold: a new pen-down does not inherit old packets");
    }

    /* --- a pen-down that got no click (wtc_nc_*) ---------------------------
     * Diagnostic only. What must hold: the NOCLICK line is written for a
     * pen-down that truly got no click, and for nothing else, and its tally
     * puts each mouse message in the right column. */
    {
        WTC_NOCLICK n;
        char line[200];

        /* which messages count as mouse messages: both ranges, ends included */
        EXPECT(wtc_nc_is_mouse(0x0200) && wtc_nc_is_mouse(0x020E), "noclick: client mouse range, both ends");
        EXPECT(wtc_nc_is_mouse(0x00A0) && wtc_nc_is_mouse(0x00AD), "noclick: frame mouse range, both ends");
        EXPECT(!wtc_nc_is_mouse(0x01FF) && !wtc_nc_is_mouse(0x020F), "noclick: just outside the client range");
        EXPECT(!wtc_nc_is_mouse(0x009F) && !wtc_nc_is_mouse(0x00AE), "noclick: just outside the frame range");
        EXPECT(!wtc_nc_is_mouse(0x7FF0) && !wtc_nc_is_mouse(0x0100), "noclick: our WT_PACKET and a key are not mouse");

        /* the lost stroke of 2026-11-13: SAI got moves, and no click anywhere */
        memset(&n, 0, sizeof n);
        wtc_nc_msg(&n, 0x0200, 1);
        wtc_nc_msg(&n, 0x0200, 1);
        wtc_nc_msg(&n, 0x7FF0, 1);                     /* our own packet: not counted */
        EXPECT(n.moves == 2 && n.ldown == 0 && n.other == 0 && n.other_root == 0,
               "noclick: moves counted, a non-mouse message is not");
        EXPECT(wtc_nc_lost(0, &n) == 1, "noclick: no click in the trace and none in the tally -> lost");

        /* THE TRAP in wtc_nc_lost: a tap in a dialog or floating panel is a
         * click in ANOTHER window. The trace says click=none, yet nothing was
         * lost. Drop the tally from the test and every tap in a panel is
         * reported as a lost stroke. */
        wtc_nc_msg(&n, 0x0201, 0);
        EXPECT(n.ldown == 1 && n.other_root == 1, "noclick: a click in another window is counted, and marked elsewhere");
        EXPECT(wtc_nc_lost(0, &n) == 0, "noclick: a click in another of SAI's windows is not a lost stroke");

        /* the other half: a click that came just BEFORE our pen-down is only
         * in the trace (the tally starts at pen-down) */
        memset(&n, 0, sizeof n);
        EXPECT(wtc_nc_lost(1, &n) == 0, "noclick: a click the trace matched is not lost, even with an empty tally");

        /* a double click starts a stroke as well */
        memset(&n, 0, sizeof n);
        wtc_nc_msg(&n, 0x0203, 1);
        EXPECT(n.ldown == 1 && wtc_nc_lost(0, &n) == 0, "noclick: a double click counts as a click");

        /* a click on the window frame is NOT a canvas click: the stroke is
         * still lost, and the line must say where the click went */
        memset(&n, 0, sizeof n);
        wtc_nc_msg(&n, 0x00A1, 1);
        wtc_nc_msg(&n, 0x00A0, 1);
        EXPECT(n.nc == 2 && n.nc_ldown == 1 && n.ldown == 0, "noclick: frame messages have their own columns");
        EXPECT(wtc_nc_lost(0, &n) == 1, "noclick: a click on the frame does not start a stroke");

        /* every column, each message in one column only */
        memset(&n, 0, sizeof n);
        wtc_nc_msg(&n, 0x0202, 1);                     /* left up */
        wtc_nc_msg(&n, 0x0204, 1);                     /* right down */
        wtc_nc_msg(&n, 0x020A, 0);                     /* wheel, in another window */
        EXPECT(n.lup == 1 && n.other == 2 && n.other_root == 1 && n.moves == 0 && n.ldown == 0 && n.nc == 0,
               "noclick: button-up, right button and wheel each land in one column");

        /* the line */
        memset(&n, 0, sizeof n);
        n.moves = 3; n.lup = 1; n.nc = 2; n.nc_ldown = 1; n.other = 4; n.other_root = 5;
        wtc_nc_format(&n, 17, line, sizeof line);
        EXPECT(strcmp(line, "moves=3 (last 17ms ago) up=1 frame=2 frame-click=1 other=4 elsewhere=5") == 0,
               "noclick: the line names every column");
        wtc_nc_format(&n, -1, line, sizeof line);
        EXPECT(strstr(line, "moves=3 (none ever)") == line, "noclick: no mouse move seen at all is said so");
        wtc_nc_format(&n, 0, line, sizeof line);
        EXPECT(strstr(line, "(last 0ms ago)") != NULL, "noclick: a move in this very millisecond is not 'none ever'");
        {
            char tiny[10];
            int w = wtc_nc_format(&n, 17, tiny, sizeof tiny);
            EXPECT(w == (int)sizeof tiny - 1 && tiny[sizeof tiny - 1] == '\0', "noclick: a short buffer is cut, not overrun");
            EXPECT(wtc_nc_format(&n, 17, NULL, 0) == 0, "noclick: no buffer -> nothing written");
        }
    }

    if (failures) { printf("FAILED: %d test(s)\n", failures); return 1; }
    printf("All wintab_core tests passed.\n");
    return 0;
}
