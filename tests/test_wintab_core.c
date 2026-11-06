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

    if (failures) { printf("FAILED: %d test(s)\n", failures); return 1; }
    printf("All wintab_core tests passed.\n");
    return 0;
}
