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

    if (failures) { printf("FAILED: %d test(s)\n", failures); return 1; }
    printf("All wintab_core tests passed.\n");
    return 0;
}
