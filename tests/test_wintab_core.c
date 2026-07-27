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

    if (failures) { printf("FAILED: %d test(s)\n", failures); return 1; }
    printf("All wintab_core tests passed.\n");
    return 0;
}
