/*
 * Minimal custom wintab32.dll for PaintTool SAI Ver.2 under Wine on macOS.
 *
 * Purpose: feed SAI pen pressure. SAI already gets POSITION from the normal
 * cursor (it draws lines fine); this DLL supplies the WinTab pressure stream.
 *
 * Architecture:
 *   - No synthetic/test injection (so no phantom stroke on startup).
 *   - A producer thread reads the current pressure (0..g_max_press) from a small file
 *     C:\wt_pressure.txt (which a native macOS helper writes from the real
 *     Wacom tablet). When pressure > 0 (pen down) it emits a packet at the
 *     LIVE cursor position and posts WT_PACKET to SAI's window; SAI then calls
 *     WTPacket() to read it. When pressure == 0 (pen up) it stays idle and SAI
 *     just draws with the mouse as usual.
 *
 * Build (from ~/Documents/wineORwhiskyFORSAI/wintab-src):
 *   x86_64-w64-mingw32-gcc -shared -O2 -o wintab32.dll wintab32.c wintab32.def \
 *       -lgdi32 -luser32 -municode
 */

#include <winsock2.h>
#include <windows.h>
#include <stdio.h>

#include "wintab_core.h"   /* the pure logic (parse/map/conflate) — unit-tested natively */

#define SAMPLE_PORT 47800   /* UDP; the mac helper sends every pen sample here */

/* ---- WinTab constants / structs (subset; we don't have wintab.h in mingw) - */
typedef DWORD WTPKT;
typedef struct { LONG axMin, axMax; UINT axUnits; DWORD axResolution; } AXIS;
typedef struct { int orAzimuth, orAltitude, orTwist; } ORIENTATION;

#define LCNAMELEN 40
typedef struct {
    WCHAR lcName[LCNAMELEN];
    UINT  lcOptions, lcStatus, lcLocks, lcMsgBase, lcDevice, lcPktRate;
    WTPKT lcPktData, lcPktMode, lcMoveMask;
    DWORD lcBtnDnMask, lcBtnUpMask;
    LONG  lcInOrgX, lcInOrgY, lcInOrgZ, lcInExtX, lcInExtY, lcInExtZ;
    LONG  lcOutOrgX, lcOutOrgY, lcOutOrgZ, lcOutExtX, lcOutExtY, lcOutExtZ;
    DWORD lcSensX, lcSensY, lcSensZ;
    BOOL  lcSysMode;
    int   lcSysOrgX, lcSysOrgY, lcSysExtX, lcSysExtY;
    DWORD lcSysSensX, lcSysSensY;
} LOGCONTEXTW;

/* packet field-mask bits (WTPKT) */
#define PK_STATUS 0x0002u
#define PK_CURSOR 0x0020u
#define PK_BUTTONS 0x0040u
#define PK_X 0x0080u
#define PK_Y 0x0100u
#define PK_NORMAL_PRESSURE 0x0400u
#define PK_ORIENTATION 0x1000u
#define OUR_PKTDATA (PK_STATUS|PK_CURSOR|PK_BUTTONS|PK_X|PK_Y|PK_NORMAL_PRESSURE|PK_ORIENTATION) /* 0x15e2 */

#define WT_DEFBASE 0x7ff0
#define WT_PACKET  (WT_DEFBASE+0)
/* Full-scale pressure. CHOSEN AT RUNTIME so the user can trade resolution
 * against jitter from the setup window (issue #21): more levels means finer
 * control but also that sensor noise stops being quantised away.
 *
 * Read once from C:\\wt_pmax.txt, which the mac side writes BEFORE launching
 * SAI. Both halves read the same file, so the helper's scaling and the axis we
 * advertise to SAI can never disagree -- and SAI reads the axis at WTOpen, so
 * it must be settled before then. Missing or invalid file -> 1023 (the long-standing
 * default). */
#define MAX_PRESS_CEILING 8191
static int g_max_press = 1023;
#define MAX_PRESS  g_max_press

static void load_max_press(void) {
    FILE *f = fopen("C:\\wt_pmax.txt", "rb");
    if (!f) return;
    char b[32] = {0};
    size_t n = fread(b, 1, sizeof(b) - 1, f);
    fclose(f);
    b[n] = '\0';
    int v = atoi(b);
    if (v >= 255 && v <= MAX_PRESS_CEILING) g_max_press = v;
}
#define IN_EXT     32767

/* our packet, in field order matching OUR_PKTDATA (36 bytes) */
typedef struct {
    UINT status;
    UINT cursor;
    UINT buttons;
    LONG x;
    LONG y;
    UINT pressure;
    int  orAzimuth, orAltitude, orTwist;
} OURPKT;

/* WinTab categories */
#define WTI_INTERFACE 1
#define WTI_DEFCONTEXT 3
#define WTI_DEVICES 100
#define WTI_CURSORS 200
#define WTI_DDCTXS 400

static HWND  g_hwnd;
static UINT  g_serial = 1;
static BOOL  g_open;
static int   g_screenW = 1352, g_screenH = 878;   /* primary screen (fallback) */
static int   g_virtW = 1352, g_virtH = 878;       /* full virtual desktop (all displays) */
static OURPKT g_last;          /* most recent packet */
static UINT   g_last_serial;
#define RING_SZ 256            /* recent packets by serial, so WTPacket can return
                                  the one SAI asked for — returning only the latest
                                  dropped intermediate points when SAI processed
                                  message bursts, causing straight "boxy" segments */
static OURPKT g_ring[RING_SZ];
static UINT   g_ring_serial[RING_SZ];
static LOGCONTEXTW g_ctx;      /* the context SAI asked for in WTOpenW/WTSetW */
static BOOL  g_have_ctx;
static CRITICAL_SECTION g_cs;
static FILE  *g_log;
static volatile DWORD g_last_tip_tick;   /* GetTickCount of the last pen-tip
                                            transition; opens the click de-dup
                                            window (see CLICK DE-DUP below) */

static void log_line(const char *fmt, ...) {
    if (!g_log) return;
    va_list ap; va_start(ap, fmt); vfprintf(g_log, fmt, ap); va_end(ap);
    fputc('\n', g_log); fflush(g_log);
}

static void fill_default_context(LOGCONTEXTW *lc) {
    memset(lc, 0, sizeof(*lc));
    static const WCHAR nm[] = L"OurDefault";
    memcpy(lc->lcName, nm, sizeof(nm));
    /* CXO_MESSAGES only. KNOWN QUIRK: while the pen is in range, SAI suppresses
     * the pen's synthesized mouse clicks, so the TOP MENU ROW ("File", ...)
     * ignores pen taps (canvas/brush panels are fine — they run on the WinTab
     * packets). Use the mouse/trackpad for the menu.
     * Tried: advertising CXO_SYSTEM (0x0001) like a real Wacom driver makes SAI
     * accept the mouse click, but SAI then processes BOTH the mouse click AND
     * our buttons=1 packet -> menus open and instantly close (double-click).
     * Real drivers dodge this because Windows tags pen-synthesized mouse events
     * (GetMessageExtraInfo signature) so apps can de-dup; Wine's mouse events
     * carry no tag. No DLL-side fix without risking canvas double-strokes. */
    lc->lcOptions  = 0x0004;
    lc->lcMsgBase  = WT_DEFBASE;
    lc->lcPktRate  = 133;
    lc->lcPktData  = OUR_PKTDATA;
    lc->lcMoveMask = OUR_PKTDATA;
    lc->lcInExtX = IN_EXT; lc->lcInExtY = IN_EXT;
    /* output/system extent spans the full VIRTUAL desktop (all monitors) with
     * its true aspect ratio (x8 for sub-pixel resolution). The helper reports
     * the pen position within this same combined space, so a 2nd monitor maps
     * correctly instead of producing a doubled cursor. A square extent stretched
     * drawings; a single-screen extent broke the 2nd display. Single screen:
     * virtual == primary, so this is identical to before. */
    lc->lcOutExtX = g_virtW * 8; lc->lcOutExtY = g_virtH * 8;
    lc->lcSysExtX = g_virtW; lc->lcSysExtY = g_virtH;
    lc->lcSensX = lc->lcSensY = lc->lcSensZ = 65536;
}

/* latest sample from the mac helper. Format: "p x y w h" (pressure, pen pos in
 * macOS coords: origin bottom-left y-up, and mac screen size in points) or a
 * bare "p" (no position -> caller falls back to the Wine cursor). A failed
 * open/parse (file caught mid-rewrite) returns the LAST good sample — treating
 * torn reads as pen-up caused stroke gaps SAI bridged with straight segments. */
typedef WTC_SAMPLE SAMPLE;   /* defined (and parsed) in wintab_core.h */
static SAMPLE g_sample;   /* last good sample */

static SAMPLE read_sample(void) {
    FILE *f = fopen("C:\\wt_pressure.txt", "rb");
    if (!f) return g_sample;
    char buf[128];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';
    (void)wtc_parse_sample(buf, &g_sample);   /* failed parse keeps the last good sample */
    return g_sample;
}

static int read_pressure(void) { return read_sample().press; }

static int   g_was_down;
static DWORD g_posted;
static UINT  g_fetched;    /* last serial SAI actually pulled via WTPacket */
static unsigned long g_fetch_count;   /* total WTPacket fetches = points SAI actually drew */
static int   g_dirty;      /* g_last holds a fresher sample than we've posted */
#define POST_WINDOW 3      /* max unfetched packets before we conflate. 1 = min lag but
                              boxy fast curves (drops in-between points); higher = smoother
                              curves, more lag. Measuring SAI's draw rate to tune this. */
static DWORD g_ring_time[RING_SZ];  /* GetTickCount when each serial was posted (latency probe) */

/* build a WinTab packet from one sample and post it to SAI. Streams
 * CONTINUOUSLY, exactly like a real Wacom driver: pen-down samples carry
 * buttons=1 + pressure, HOVER samples (pen up, in range) carry buttons=0 +
 * pressure 0 but STILL carry position. SAI positions its brush cursor from
 * these packets, so dropping hover samples froze the cursor at the last drawn
 * point until Wine's mouse path caught up — now the cursor tracks the pen
 * continuously. The pen-down -> up transition is naturally the first
 * buttons=0 packet, which ends the stroke. */
static void emit_sample(const SAMPLE *s) {
    if (!g_open || !g_hwnd) return;

    int down = s->press > 0;
    /* nothing to do: pen up, no position, and not ending a stroke
     * (e.g. the bare "0" file kill switch while already idle) */
    if (!down && !s->has_pos && !g_was_down) return;

    /* start from the last packet so a position-less pen-up ends the stroke
     * at the last drawn point rather than jumping */
    EnterCriticalSection(&g_cs);
    OURPKT pk = g_last;
    LeaveCriticalSection(&g_cs);
    pk.status = 0;
    pk.cursor = 0;
    pk.buttons  = down ? 1 : 0;
    pk.pressure = down ? (UINT)s->press : 0;

    /* map position into the OUTPUT coordinate space of the context SAI
     * opened (WinTab packets are in lcOut coords). WinTab convention:
     * positive lcOutExtY means Y grows upward. Helper coords are mac
     * bottom-left y-up (already the WinTab direction) and are fixed-point
     * (x,y,w,h uniformly scaled) — map DIRECTLY into out space in one
     * 64-bit step, no intermediate screen-pixel quantization. */
    if (s->has_pos) {
        LONG oX = 0, oY = 0, eX = IN_EXT, eY = IN_EXT;
        EnterCriticalSection(&g_cs);
        if (g_have_ctx) {
            oX = g_ctx.lcOutOrgX; eX = g_ctx.lcOutExtX;
            oY = g_ctx.lcOutOrgY; eY = g_ctx.lcOutExtY;
        }
        LeaveCriticalSection(&g_cs);
        int32_t px, py;
        wtc_map_to_out(s, oX, oY, eX, eY, IN_EXT, &px, &py);
        pk.x = px; pk.y = py;
    }
    /* else: keep pk.x/pk.y from g_last (position-less pen-up) */

    int transition = (down != g_was_down);
    if (transition) {         /* log tip transitions to investigate stray clicks */
        g_last_tip_tick = GetTickCount();   /* opens the click de-dup window */
        log_line("PEN %s buttons=%u pk=(%ld,%ld) press=%u t=%lu",
             down ? "DOWN" : "UP", pk.buttons, (long)pk.x, (long)pk.y, pk.pressure, GetTickCount());
    }
    g_was_down = down;

    /* CONFLATION: always keep g_last fresh, but only PostMessage a new WT_PACKET
     * when SAI isn't already behind (or on a tip transition, which must never be
     * dropped). Posting a packet per sample flooded SAI faster than it drains
     * its message queue, so the drawn point trailed the cursor during fast
     * motion (worse the faster you move). Now we self-pace to SAI's consumption:
     * intermediate samples collapse into g_last, so SAI always gets a CURRENT
     * point and the trail stays tight. Skipped points are on-path; SAI
     * interpolates. A pending fresh sample is flushed by flush_pending(). */
    UINT ser = 0; BOOL post;
    EnterCriticalSection(&g_cs);
    g_last = pk;
    post = wtc_should_post(g_serial, g_fetched, transition, POST_WINDOW);
    if (post) {
        ser = g_serial++;
        g_last_serial = ser;
        g_ring_serial[ser % RING_SZ] = ser;
        g_ring[ser % RING_SZ] = pk;
        g_ring_time[ser % RING_SZ] = GetTickCount();
        g_dirty = 0;
    } else {
        g_dirty = 1;          /* freshest not yet delivered; flush when SAI catches up */
    }
    LeaveCriticalSection(&g_cs);

    if (post) { PostMessageW(g_hwnd, WT_PACKET, ser, (LPARAM)0xC0FFEE01); g_posted++; }
}

/* deliver the freshest pending packet once SAI has caught up — covers the case
 * where samples stopped (pen still/lifted) while we were conflating, so the
 * final position isn't left undelivered. */
static void flush_pending(void) {
    if (!g_open || !g_hwnd) return;
    UINT ser = 0; BOOL post = FALSE;
    EnterCriticalSection(&g_cs);
    if (g_dirty && wtc_should_post(g_serial, g_fetched, 0, POST_WINDOW)) {
        ser = g_serial++;
        g_last_serial = ser;
        g_ring_serial[ser % RING_SZ] = ser;
        g_ring[ser % RING_SZ] = g_last;
        g_ring_time[ser % RING_SZ] = GetTickCount();
        g_dirty = 0;
        post = TRUE;
    }
    LeaveCriticalSection(&g_cs);
    if (post) { PostMessageW(g_hwnd, WT_PACKET, ser, (LPARAM)0xC0FFEE01); g_posted++; }
}

/* ---- WIN32 WAKE ------------------------------------------------------------
 * After an app switch Wine sometimes fails to restore the Win32 foreground /
 * active window, even though macOS shows SAI as the active app. SAI's own
 * WM_MOUSEACTIVATE handler returns MA_NOACTIVATEANDEAT, so in that state every
 * click on the canvas is swallowed as an "activating click" and the canvas
 * looks dead to BOTH pen and mouse — while the menu bar (a different code path)
 * still responds. macOS-side re-activation can't fix that; but this DLL lives
 * INSIDE SAI's process, so it can restore the Win32 state directly.
 * The mac helper bumps C:\wt_wake.txt to ask for it. Disable: WT_NO_WIN32_WAKE.
 *
 * SetActiveWindow/SetFocus are THREAD-LOCAL: they must run on SAI's UI thread,
 * not our producer thread (from here they'd target our message-less thread and
 * earlier attempts disturbed SAI's input). We marshal onto the UI thread with a
 * thread-scoped WH_GETMESSAGE hook: the hook proc is our own code but Windows
 * runs it on the HOOKED thread whenever that thread pulls a message — SAI's UI
 * thread keeps pumping while stuck (the menu row still works), so posting any
 * message guarantees a prompt tick. Fallback: AttachThreadInput, which shares
 * the input state so the calls apply from this thread. */
typedef struct { HWND h; LONG area; } BESTWND;

static volatile HWND  g_wake_target;   /* window the hook should activate */
static volatile LONG  g_wake_done;
static HHOOK          g_wake_hook;

/* Wake diagnostics are ALWAYS logged (separate file, append) — wakes are rare
 * (user-triggered) so there's no per-packet cost, and field reports without
 * WT_DEBUG were blind exactly when we needed data. See issue #2. */
static void wake_log(const char *fmt, ...) {
    FILE *f = fopen("C:\\wt_wakelog.txt", "a");
    if (!f) return;
    fprintf(f, "[%lu] ", (unsigned long)GetTickCount());
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); fclose(f);
}

/* runs ON SAI'S UI THREAD (thread-scoped hook) — the only place the two broken
 * layers can BOTH be repaired (verified live against a stuck SAI, issue #2):
 *
 * 1. WINESERVER FOREGROUND can be parked on another process's window (seen:
 *    the desktop window, class #32769). Wine enforces the Windows foreground
 *    lock: SetForegroundWindow from a non-foreground process fails with
 *    ERROR_ACCESS_DENIED (5). Classic bypass, confirmed working under this
 *    Wine: AttachThreadInput to the CURRENT foreground owner's thread, which
 *    makes our input state count as foreground, then retry.
 *
 * 2. THE COCOA KEY WINDOW: winemac.drv only makes the Mac window key on a
 *    focus CHANGE. After the bug the Win32 state can already read "correct"
 *    (focus==w) so a plain SetFocus(w) no-ops at win32u level and the driver
 *    is never called — the Mac window stays non-key and every click becomes a
 *    swallowed "activating click". Toggling focus through NULL forces the
 *    driver call. Driver entry points run in the CALLING process, so this is
 *    only effective from inside SAI — exactly here. */
static LRESULT CALLBACK wake_hook_proc(int code, WPARAM wp, LPARAM lp) {
    if (code >= 0 && g_wake_target && !g_wake_done) {
        HWND w = g_wake_target;
        InterlockedExchange(&g_wake_done, 1);   /* once per request */
        HWND fgBefore = GetForegroundWindow();
        BOOL bypass = FALSE;
        BringWindowToTop(w);
        SetLastError(0);
        BOOL ok = SetForegroundWindow(w);
        DWORD err = GetLastError();
        if (!ok || GetForegroundWindow() != w) {
            DWORD fgTid = fgBefore ? GetWindowThreadProcessId(fgBefore, NULL) : 0;
            if (fgTid && fgTid != GetCurrentThreadId() &&
                AttachThreadInput(GetCurrentThreadId(), fgTid, TRUE)) {
                bypass = TRUE;
                SetLastError(0);
                ok = SetForegroundWindow(w);
                err = GetLastError();
                AttachThreadInput(GetCurrentThreadId(), fgTid, FALSE);
            }
        }
        SetActiveWindow(w);
        SetFocus(NULL);       /* force the focus change through the driver */
        SetFocus(w);
        /* 3rd broken layer (the one that finally matched the field logs): SAI
         * keeps its OWN "am I active" flag, set only by activation MESSAGES.
         * Wine can restore the activation state without a state CHANGE, so no
         * message is ever generated and SAI's flag stays stale — canvas clicks
         * keep getting eaten even with fg/active/focus all correct (observed
         * live: 6 perfectly healthy wakes on a still-stuck SAI). Synthesize the
         * sequence a real activation would deliver; we're ON the UI thread, so
         * these are direct window-proc calls. */
        SendMessageW(w, WM_NCACTIVATE, TRUE, 0);
        SendMessageW(w, WM_ACTIVATEAPP, TRUE, 0);
        SendMessageW(w, WM_ACTIVATE, MAKEWPARAM(WA_ACTIVE, 0), 0);
        wake_log("hook: target=%p fgBefore=%p sfw=%d err=%lu bypass=%d "
                 "fg=%p active=%p focus=%p (activation msgs sent)",
                 w, fgBefore, ok, (unsigned long)err, bypass,
                 GetForegroundWindow(), GetActiveWindow(), GetFocus());
    }
    return CallNextHookEx(g_wake_hook, code, wp, lp);
}

static BOOL CALLBACK find_main_window(HWND h, LPARAM lp) {
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (pid != GetCurrentProcessId()) return TRUE;
    if (!IsWindowVisible(h) || GetWindow(h, GW_OWNER)) return TRUE;
    RECT r;
    if (!GetWindowRect(h, &r)) return TRUE;
    LONG area = (r.right - r.left) * (r.bottom - r.top);
    BESTWND *b = (BESTWND *)lp;
    if (area > b->area) { b->area = area; b->h = h; }
    return TRUE;
}

/* marshal one wake onto the UI thread; returns 1 if the hook ran */
static int run_wake_hook(HWND w, DWORD tid) {
    g_wake_target = w;
    InterlockedExchange(&g_wake_done, 0);
    g_wake_hook = SetWindowsHookExW(WH_GETMESSAGE, wake_hook_proc, NULL, tid);
    if (!g_wake_hook) {
        wake_log("win32_wake: SetWindowsHookEx failed (%lu)", (unsigned long)GetLastError());
        g_wake_target = NULL;
        return 0;
    }
    /* poke the UI thread so the hook fires now; WM_NULL is a no-op to SAI */
    PostMessageW(w, WM_NULL, 0, 0);
    for (int i = 0; i < 40 && !g_wake_done; i++) Sleep(5);   /* <=200 ms */
    UnhookWindowsHookEx(g_wake_hook);
    g_wake_hook = NULL;
    g_wake_target = NULL;
    if (!g_wake_done) wake_log("win32_wake: hook never ticked");
    return g_wake_done != 0;
}

static void win32_wake(void) {
    BESTWND best = { NULL, 0 };
    EnumWindows(find_main_window, (LPARAM)&best);
    HWND w = best.h ? best.h : (g_hwnd ? GetAncestor(g_hwnd, GA_ROOT) : NULL);
    if (!w) { wake_log("win32_wake: no window found"); return; }

    DWORD tid = GetWindowThreadProcessId(w, NULL);
    wake_log("win32_wake: target=%p uiThread=%lu fg=%p", w, (unsigned long)tid,
             GetForegroundWindow());

    run_wake_hook(w, tid);

    /* VERIFY it took (and stuck): a sibling Wine process — e.g. the one the
     * helper's macOS-side bounce activates — can steal wineserver foreground
     * right back. Identify the thief for the log and retry once, again via
     * the UI thread (a naked call from this thread hits the foreground lock). */
    Sleep(250);
    HWND fgNow = GetForegroundWindow();
    if (fgNow == w) { wake_log("win32_wake: OK, foreground is ours"); return; }
    DWORD thiefPid = 0;
    if (fgNow) GetWindowThreadProcessId(fgNow, &thiefPid);
    wake_log("win32_wake: fg=%p ownerPid=%lu (we are pid %lu) — retrying",
             fgNow, (unsigned long)thiefPid, (unsigned long)GetCurrentProcessId());
    run_wake_hook(w, tid);
    Sleep(150);
    fgNow = GetForegroundWindow();
    wake_log("win32_wake: after retry fg=%p (%s)", fgNow, fgNow == w ? "ok" : "STILL LOST");
}

/* poll the wake marker (cheap, ~6x/sec) */
/* ---- PINCH TO ZOOM (issue #22) --------------------------------------------
 * macOS pinch arrives as a "magnify" gesture, which Wine does not translate
 * into anything SAI understands — so only two-finger scroll zooms, and every
 * Mac reflex to pinch does nothing.
 *
 * We do NOT synthesise macOS events for this: that would need the Accessibility
 * permission, which this project deliberately dropped. Instead the mac helper
 * (which already sees the gesture through the tap it uses for the tablet) writes
 * a running step count to C:\wt_zoom.txt, and we post the wheel message from
 * INSIDE SAI's own process — no permission involved at all.
 *
 * WM_MOUSEWHEEL rather than PageUp/PageDown on purpose: it carries a position,
 * so SAI zooms at the cursor instead of the canvas centre, and it is the path
 * already known to work here (two-finger scroll zooms today).
 * Disable: WT_NO_PINCH_ZOOM=1. */
static void post_zoom(int steps) {
    HWND w = g_hwnd ? GetAncestor(g_hwnd, GA_ROOT) : NULL;
    if (!w) return;
    POINT pt;
    if (!GetCursorPos(&pt)) { pt.x = 0; pt.y = 0; }
    int dir = steps > 0 ? 1 : -1;
    int n = steps > 0 ? steps : -steps;
    if (n > 8) n = 8;                       /* a violent pinch shouldn't fling the zoom */
    for (int i = 0; i < n; i++) {
        PostMessageW(w, WM_MOUSEWHEEL,
                     MAKEWPARAM(0, (short)(dir * WHEEL_DELTA)),
                     MAKELPARAM((short)pt.x, (short)pt.y));
    }
    log_line("pinch: posted %d wheel step(s) at (%ld,%ld)", dir * n, (long)pt.x, (long)pt.y);
}

static void check_zoom(DWORD now) {
    static DWORD lastCheck;
    static long lastVal;
    static int primed;
    if (getenv("WT_NO_PINCH_ZOOM")) return;
    if (now - lastCheck < 30) return;       /* responsive: a pinch is a live gesture */
    lastCheck = now;
    FILE *f = fopen("C:\\wt_zoom.txt", "rb");
    if (!f) return;
    char b[32];
    size_t n = fread(b, 1, sizeof(b) - 1, f);
    fclose(f);
    b[n] = 0;
    long v = atol(b);
    if (!primed) { primed = 1; lastVal = v; return; }   /* ignore the value present at startup */
    if (v != lastVal) {
        long d = v - lastVal;
        lastVal = v;
        post_zoom((int)d);
    }
}

static void check_win32_wake(DWORD now) {
    static DWORD lastCheck;
    static char lastVal[32];
    /* ON by default (the wake now runs on SAI's UI thread via the hook, so the
     * earlier wrong-thread hazard is gone). Opt out with WT_NO_WIN32_WAKE=1. */
    if (getenv("WT_NO_WIN32_WAKE")) return;
    if (now - lastCheck < 150) return;
    lastCheck = now;
    FILE *f = fopen("C:\\wt_wake.txt", "rb");
    if (!f) return;
    char b[32];
    size_t n = fread(b, 1, sizeof(b) - 1, f);
    fclose(f);
    b[n] = 0;
    if (strcmp(b, lastVal) != 0) {
        int first = (lastVal[0] == 0);
        strcpy(lastVal, b);
        if (!first) win32_wake();       /* skip the value we see on startup */
    }
}

/* ---- CLICK DE-DUP (pen tap = double click bug) -----------------------------
 * Every physical pen tap reaches SAI TWICE: once as our WinTab packet
 * (buttons=1, which drives the canvas and the tool panels) and once as the
 * mouse click Wine synthesizes from the same tap. Real Windows drivers tag
 * their synthesized mouse events so apps can de-dup; Wine's carry no tag, and
 * SAI's own heuristic misses often enough that a single pen tap on a brush
 * slot could register as TWO clicks and pop the double-click Property dialog
 * (field logs showed one clean DOWN/UP pair per tap — the duplicate is the
 * mouse click, not our stream). So we de-dup for SAI: a permanent
 * WH_GETMESSAGE hook on its UI thread rewrites left-button messages to
 * WM_NULL when they arrive within CLICK_DEDUP_MS of a pen-tip transition.
 * Scope:
 *   - main window only (GA_ROOT match): dialogs are separate windows and may
 *     be mouse-driven — never touched.
 *   - client-area messages only: the menu bar is WM_NCLBUTTONDOWN, so the
 *     issue-#1 menu-strip fix is unaffected.
 *   - only within CLICK_DEDUP_MS of a REAL tip transition from our stream; a
 *     human can't switch pen->mouse that fast, so real mouse clicks pass.
 *
 * OFF BY DEFAULT since v0.1.6 — see issue #19. The "main window only" scoping
 * above is WRONG: the canvas is a child of the main window too, so GA_ROOT
 * matches it just as happily as a brush slot. That made this hook swallow the
 * WM_LBUTTONDOWN that STARTS EVERY STROKE, ~6ms after each pen-down:
 *     PEN DOWN press=218
 *     CLICK dedup: ate msg=0x201 dt=6ms          (0x201 = WM_LBUTTONDOWN)
 * WinTab pressure kept arriving perfectly (fetched=274/274, press up to 1023),
 * so every log looked healthy while the pen simply could not draw — and no
 * amount of reinstalling could fix it, because the bug shipped in this DLL.
 * A double-click dialog is a nuisance; a pen that cannot draw is not, so the
 * default now favours drawing and #8 is reopened.
 * Enable:  WT_CLICK_DEDUP=1   (accepts the #8 double-click risk)
 * Disable: WT_NO_CLICK_DEDUP=1 (still honoured; now redundant) */
#define CLICK_DEDUP_MS 400
static HHOOK g_click_hook;
static unsigned long g_clicks_eaten;

static LRESULT CALLBACK click_hook_proc(int code, WPARAM wp, LPARAM lp) {
    MSG *m = (MSG *)lp;
    (void)wp;
    if (code >= 0 && m && g_hwnd &&
        (m->message == WM_LBUTTONDOWN || m->message == WM_LBUTTONUP ||
         m->message == WM_LBUTTONDBLCLK)) {
        DWORD dt = GetTickCount() - g_last_tip_tick;
        if (dt < CLICK_DEDUP_MS &&
            GetAncestor(m->hwnd, GA_ROOT) == GetAncestor(g_hwnd, GA_ROOT)) {
            log_line("CLICK dedup: ate msg=%#x hwnd=%p dt=%lums total=%lu",
                     m->message, (void *)m->hwnd, (unsigned long)dt, ++g_clicks_eaten);
            m->message = WM_NULL;
            m->wParam = 0;
            m->lParam = 0;
        } else {
            /* diagnosis aid: a click we saw and let PASS — tells us whether
             * Wine mouse clicks exist at all and why they were skipped
             * (too late after the tip, or aimed at another root window) */
            log_line("CLICK seen: msg=%#x hwnd=%p root=%p (main=%p) dt=%lums",
                     m->message, (void *)m->hwnd,
                     (void *)GetAncestor(m->hwnd, GA_ROOT),
                     (void *)(g_hwnd ? GetAncestor(g_hwnd, GA_ROOT) : NULL),
                     (unsigned long)dt);
        }
    }
    return CallNextHookEx(g_click_hook, code, wp, lp);
}

/* install once SAI's window exists (cheap; called from producer housekeeping) */
static void ensure_click_dedup(void) {
    if (g_click_hook || !g_hwnd) return;
    if (getenv("WT_NO_CLICK_DEDUP")) return;   /* explicit off, kept for compat */
    if (!getenv("WT_CLICK_DEDUP")) {           /* OPT-IN now — see issue #19 */
        /* Log ONCE. This is called from producer housekeeping on every
         * iteration, so an unguarded line here drowned the log: a field capture
         * came back 2055 spam lines out of 2111, hiding the packet flow that
         * the log exists to show. */
        static int said;
        if (!said) { said = 1; log_line("click dedup: OFF by default (set WT_CLICK_DEDUP=1 to enable)"); }
        return;
    }
    HWND root = GetAncestor(g_hwnd, GA_ROOT);
    DWORD tid = GetWindowThreadProcessId(root ? root : g_hwnd, NULL);
    if (!tid) return;
    g_click_hook = SetWindowsHookExW(WH_GETMESSAGE, click_hook_proc, NULL, tid);
    log_line("click dedup: hook %s on thread %lu",
             g_click_hook ? "installed" : "FAILED", (unsigned long)tid);
}

/* parse "p [x y w h]" into a SAMPLE (pure logic lives in wintab_core.h) */
static int parse_sample(const char *buf, SAMPLE *out) { return wtc_parse_sample(buf, out); }

/* producer: block on the UDP socket and post EACH datagram the instant it
 * arrives (no fixed poll interval — removes up to 6 ms of cursor-vs-ink lag
 * and packet clumping). A 100 ms recv timeout lets us do heartbeat logging
 * and the file fallback (kill switch / manual test) while the pen is idle.
 *
 * INSTRUMENTATION (Phase 1): the helper stamps each datagram with a monotonic
 * sequence number; we count datagrams received and any sequence GAPS (= true
 * transport loss). Compare in the log: helper's captured count vs our recv=,
 * and posted= vs SAI's WTPacket fetch count — this locates where samples are
 * lost (capture vs transport vs SAI-side) instead of guessing. */
static DWORD WINAPI producer(LPVOID arg) {
    DWORD lastBeat = 0, lastDatagram = 0;
    unsigned long recvCount = 0, gaps = 0;
    long lastSeq = -1;
    SOCKET sock = INVALID_SOCKET;
    (void)arg;

    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2,2), &wsa) == 0) {
        sock = socket(AF_INET, SOCK_DGRAM, 0);
        if (sock != INVALID_SOCKET) {
            struct sockaddr_in a; memset(&a, 0, sizeof(a));
            a.sin_family = AF_INET;
            a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            a.sin_port = htons(SAMPLE_PORT);
            if (bind(sock, (struct sockaddr*)&a, sizeof(a)) != 0) {
                log_line("producer: UDP bind :%d failed (%d) — file mode only", SAMPLE_PORT, WSAGetLastError());
                closesocket(sock); sock = INVALID_SOCKET;
            } else {
                DWORD tv = 15;          /* ms; short so pending flush + housekeeping are prompt */
                setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
                log_line("producer: listening on UDP 127.0.0.1:%d (blocking, immediate post)", SAMPLE_PORT);
            }
        }
    }

    for (;;) {
        char buf[128];
        int r = -1;
        if (sock != INVALID_SOCKET)
            r = recv(sock, buf, sizeof(buf)-1, 0);

        if (r > 0) {
            buf[r] = 0;
            long sq = -1; int p=-1, x=0, y=0, w=0, h=0;
            int n = sscanf(buf, "%ld %d %d %d %d %d", &sq, &p, &x, &y, &w, &h);
            if (n >= 6 && p >= 0) {
                recvCount++;
                /* backlog probe DURING a stroke: how far ahead is what we've
                 * posted vs what SAI has actually pulled? A growing gap = SAI's
                 * message queue is behind = the lag you feel. */
                /* RATE probe: from two consecutive lines, deliver rate =
                 * (recv2-recv1)/(tick2-tick1) and SAI draw rate =
                 * (fetches2-fetches1)/(tick2-tick1). If deliver >> draw, SAI is
                 * the bottleneck (boxy is its limit); if both high, we can feed
                 * more; if deliver is low, the capture/tap is dropping. */
                if ((recvCount & 63) == 0)
                    log_line("RATE recv=%lu fetches=%lu gap=%d tick=%lu",
                         recvCount, g_fetch_count, (int)(g_serial - 1 - g_fetched),
                         (unsigned long)GetTickCount());
                if (lastSeq >= 0 && sq > lastSeq + 1) gaps += (unsigned long)(sq - lastSeq - 1);
                lastSeq = sq;
                SAMPLE s;
                s.press = p > MAX_PRESS ? MAX_PRESS : p;
                s.x = x; s.y = y; s.w = w; s.h = h;
                s.has_pos = (w > 0 && h > 0);
                emit_sample(&s);        /* post immediately: lowest latency */
                lastDatagram = GetTickCount();
            }
            flush_pending();            /* deliver freshest if SAI just caught up */
            continue;                   /* drain any backlog before housekeeping */
        }

        /* recv timed out (idle) or no socket -> housekeeping */
        DWORD now = GetTickCount();
        ensure_click_dedup();           /* pen-tap double-click fix, once hwnd exists */
        check_win32_wake(now);          /* helper asked us to restore Win32 focus? */
        check_zoom(now);                /* ...or asked us to zoom (pinch gesture) */
        flush_pending();                /* pen still/lifted: deliver the final point */
        if (now - lastBeat > 2000) {
            lastBeat = now;
            log_line("producer: open=%d hwnd=%p posted=%lu recv=%lu gaps=%lu fetched=%u udp=%s",
                 g_open, g_hwnd, (unsigned long)g_posted, recvCount, gaps, g_fetched,
                 sock == INVALID_SOCKET ? "off" : (now - lastDatagram < 1000 ? "live" : "quiet"));
        }
        /* file fallback only while the socket is quiet, and EDGE-TRIGGERED:
         * emit only when the file's contents change. A static file (e.g. the
         * last pen-up sample sitting there while you use the mouse) must NOT
         * keep re-emitting hover packets — that told SAI a pen was present and
         * blocked mouse painting. `echo 0 > file` kill switch still works. */
        if (now - lastDatagram > 500) {
            static char lastFile[128];
            FILE *f = fopen("C:\\wt_pressure.txt", "rb");
            if (f) {
                char b[128];
                size_t nb = fread(b, 1, sizeof(b)-1, f);
                fclose(f);
                b[nb] = 0;
                if (strcmp(b, lastFile) != 0) {
                    strcpy(lastFile, b);
                    SAMPLE s;
                    if (parse_sample(b, &s)) emit_sample(&s);
                }
            }
        }
        if (sock == INVALID_SOCKET) Sleep(6);   /* avoid spin in file-only mode */
    }
    return 0;
}

/* ---------------- exported WinTab API (only what SAI uses) --------------- */

UINT WINAPI WTInfoW(UINT cat, UINT idx, LPVOID out) {
    log_line("WTInfoW cat=%u idx=%u out=%p", cat, idx, out);
    switch (cat) {
    case 0: return 200;
    case WTI_INTERFACE:
        switch (idx) {
        case 1: { static const WCHAR id[]=L"Wine OwnTab 1.1"; if(out) memcpy(out,id,sizeof(id)); return sizeof(id); }
        case 2: { WORD v=(1)|(1<<8); if(out)*(WORD*)out=v; return sizeof(WORD); }   /* SPECVERSION 1.1 */
        case 3: { WORD v=(0)|(1<<8); if(out)*(WORD*)out=v; return sizeof(WORD); }
        case 4: case 6: { UINT n=1; if(out)*(UINT*)out=n; return sizeof(UINT); }    /* NDEVICES/NCONTEXTS */
        case 5: { UINT n=1; if(out)*(UINT*)out=n; return sizeof(UINT); }            /* NCURSORS */
        default: return 0;
        }
    case WTI_DEFCONTEXT: case WTI_DDCTXS:
        if (idx==0) { if(out) fill_default_context((LOGCONTEXTW*)out); return sizeof(LOGCONTEXTW); }
        return 0;
    case WTI_DEVICES:
        switch (idx) {
        case 15: { AXIS a={0,MAX_PRESS,0,0}; if(out)*(AXIS*)out=a; return sizeof(AXIS); } /* NPRESSURE */
        case 17: { AXIS a[3]={{0,3600,0,0},{0,900,0,0},{0,0,0,0}}; if(out)memcpy(out,a,sizeof(a)); return sizeof(a); } /* ORIENTATION */
        case 1: { static const WCHAR n[]=L"Wine OwnTab"; if(out)memcpy(out,n,sizeof(n)); return sizeof(n); }
        default: return 0;
        }
    case WTI_CURSORS:
        switch (idx) {
        case 1: { static const WCHAR n[]=L"Pen"; if(out)memcpy(out,n,sizeof(n)); return sizeof(n); }
        case 8: { WTPKT m=OUR_PKTDATA; if(out)*(WTPKT*)out=m; return sizeof(WTPKT); }
        default: { UINT z=0; if(out)*(UINT*)out=z; return sizeof(UINT); }
        }
    default: return 0;
    }
}

static void log_ctx(const char *who, const LOGCONTEXTW *lc) {
    log_line("%s: pktData=%#lx pktMode=%#lx moveMask=%#lx opts=%#x msgBase=%#x rate=%u "
         "in=(%ld,%ld ext %ld,%ld) out=(%ld,%ld ext %ld,%ld) sys=(%d,%d ext %d,%d) sysMode=%d",
         who, (unsigned long)lc->lcPktData, (unsigned long)lc->lcPktMode,
         (unsigned long)lc->lcMoveMask, lc->lcOptions, lc->lcMsgBase, lc->lcPktRate,
         (long)lc->lcInOrgX, (long)lc->lcInOrgY, (long)lc->lcInExtX, (long)lc->lcInExtY,
         (long)lc->lcOutOrgX, (long)lc->lcOutOrgY, (long)lc->lcOutExtX, (long)lc->lcOutExtY,
         lc->lcSysOrgX, lc->lcSysOrgY, lc->lcSysExtX, lc->lcSysExtY, lc->lcSysMode);
}

HANDLE WINAPI WTOpenW(HWND hwnd, LOGCONTEXTW *lc, BOOL enable) {
    log_line("WTOpenW hwnd=%p enable=%d", hwnd, enable);
    g_hwnd = hwnd;
    g_open = enable ? TRUE : FALSE;
    if (lc) {
        log_ctx("WTOpenW ctx from SAI", lc);
        lc->lcPktData = OUR_PKTDATA; lc->lcMsgBase = WT_DEFBASE;
        EnterCriticalSection(&g_cs);
        g_ctx = *lc; g_have_ctx = TRUE;
        LeaveCriticalSection(&g_cs);
    }
    return (HANDLE)(ULONG_PTR)0xC0FFEE01;
}

BOOL WINAPI WTClose(HANDLE ctx) { (void)ctx; log_line("WTClose"); g_open=FALSE; g_hwnd=NULL; return TRUE; }

/* SAI polls this to fetch the packet a WT_PACKET message referenced —
 * return the packet MATCHING that serial (from the ring), not just the
 * latest, or bursts of queued messages all collapse to one point */
int WINAPI WTPacket(HANDLE ctx, UINT serial, LPVOID buf) {
    static LONG count;
    (void)ctx;
    if (!buf) return 0;
    EnterCriticalSection(&g_cs);
    OURPKT pk = (g_ring_serial[serial % RING_SZ] == serial) ? g_ring[serial % RING_SZ] : g_last;
    LeaveCriticalSection(&g_cs);
    memcpy(buf, &pk, sizeof(pk));       /* 36 bytes, layout 0x15e2 */
    g_fetched = serial;                 /* track how current SAI is (backlog probe) */
    g_fetch_count++;                    /* points SAI actually drew (draw-rate probe) */
    LONG n = InterlockedIncrement(&count);
    if (n == 1 || (n & 63) == 0) {      /* log 1st + every 64th fetch */
        DWORD lat = GetTickCount() - g_ring_time[serial % RING_SZ];  /* post->fetch latency */
        log_line("WTPacket #%ld serial=%u x=%ld y=%ld press=%u lat=%lums", n, serial,
             (long)pk.x, (long)pk.y, pk.pressure, (unsigned long)lat);
    }
    return 1;
}

UINT WINAPI WTQueueSizeSet(HANDLE ctx, int n) { log_line("WTQueueSizeSet n=%d", n); (void)ctx; (void)n; return 1; }
BOOL WINAPI WTGetW(HANDLE ctx, LOGCONTEXTW *lc) { log_line("WTGetW"); (void)ctx; if(lc) fill_default_context(lc); return TRUE; }
BOOL WINAPI WTEnable(HANDLE ctx, BOOL enable) { log_line("WTEnable enable=%d", enable); (void)ctx; g_open = enable?TRUE:FALSE; return TRUE; }
int  WINAPI WTPacketsGet(HANDLE ctx, int max, LPVOID buf) {
    log_line("WTPacketsGet max=%d", max);
    (void)ctx;
    if (max <= 0 || !buf) return 0;
    EnterCriticalSection(&g_cs);
    OURPKT pk = g_last;
    LeaveCriticalSection(&g_cs);
    /* read_pressure() does file I/O and only touches g_sample (not g_cs-guarded
     * state), so keep it OUT of the critical section — don't hold the lock
     * across blocking I/O. */
    int have = (read_pressure() > 0);
    if (!have) return 0;
    memcpy(buf, &pk, sizeof(pk));
    return 1;
}

/* ---- ANSI variants (SAI's "Ver.1 compatible" path may use these) ---------- */

typedef struct {
    char  lcName[LCNAMELEN];
    UINT  lcOptions, lcStatus, lcLocks, lcMsgBase, lcDevice, lcPktRate;
    WTPKT lcPktData, lcPktMode, lcMoveMask;
    DWORD lcBtnDnMask, lcBtnUpMask;
    LONG  lcInOrgX, lcInOrgY, lcInOrgZ, lcInExtX, lcInExtY, lcInExtZ;
    LONG  lcOutOrgX, lcOutOrgY, lcOutOrgZ, lcOutExtX, lcOutExtY, lcOutExtZ;
    DWORD lcSensX, lcSensY, lcSensZ;
    BOOL  lcSysMode;
    int   lcSysOrgX, lcSysOrgY, lcSysExtX, lcSysExtY;
    DWORD lcSysSensX, lcSysSensY;
} LOGCONTEXTA;

static void fill_default_context_a(LOGCONTEXTA *lc) {
    LOGCONTEXTW w; fill_default_context(&w);
    memset(lc, 0, sizeof(*lc));
    strcpy(lc->lcName, "OurDefault");
    memcpy(&lc->lcOptions, &w.lcOptions, sizeof(LOGCONTEXTA) - LCNAMELEN);
}

UINT WINAPI WTInfoA(UINT cat, UINT idx, LPVOID out) {
    log_line("WTInfoA cat=%u idx=%u out=%p", cat, idx, out);
    switch (cat) {
    case 0: return 200;
    case WTI_INTERFACE:
        switch (idx) {
        case 1: { static const char id[]="Wine OwnTab 1.1"; if(out) memcpy(out,id,sizeof(id)); return sizeof(id); }
        case 2: { WORD v=(1)|(1<<8); if(out)*(WORD*)out=v; return sizeof(WORD); }
        case 3: { WORD v=(0)|(1<<8); if(out)*(WORD*)out=v; return sizeof(WORD); }
        case 4: case 5: case 6: { UINT n=1; if(out)*(UINT*)out=n; return sizeof(UINT); }
        default: return 0;
        }
    case WTI_DEFCONTEXT: case WTI_DDCTXS:
        if (idx==0) { if(out) fill_default_context_a((LOGCONTEXTA*)out); return sizeof(LOGCONTEXTA); }
        return 0;
    case WTI_DEVICES:
        switch (idx) {
        case 15: { AXIS a={0,MAX_PRESS,0,0}; if(out)*(AXIS*)out=a; return sizeof(AXIS); }
        case 17: { AXIS a[3]={{0,3600,0,0},{0,900,0,0},{0,0,0,0}}; if(out)memcpy(out,a,sizeof(a)); return sizeof(a); }
        case 1: { static const char n[]="Wine OwnTab"; if(out)memcpy(out,n,sizeof(n)); return sizeof(n); }
        default: return 0;
        }
    case WTI_CURSORS:
        switch (idx) {
        case 1: { static const char n[]="Pen"; if(out)memcpy(out,n,sizeof(n)); return sizeof(n); }
        case 8: { WTPKT m=OUR_PKTDATA; if(out)*(WTPKT*)out=m; return sizeof(WTPKT); }
        default: { UINT z=0; if(out)*(UINT*)out=z; return sizeof(UINT); }
        }
    default: return 0;
    }
}

HANDLE WINAPI WTOpenA(HWND hwnd, LOGCONTEXTA *lc, BOOL enable) {
    log_line("WTOpenA hwnd=%p enable=%d", hwnd, enable);
    g_hwnd = hwnd;
    g_open = enable ? TRUE : FALSE;
    if (lc) { lc->lcPktData = OUR_PKTDATA; lc->lcMsgBase = WT_DEFBASE; }
    return (HANDLE)(ULONG_PTR)0xC0FFEE01;
}

BOOL WINAPI WTGetA(HANDLE ctx, LOGCONTEXTA *lc) { log_line("WTGetA"); (void)ctx; if(lc) fill_default_context_a(lc); return TRUE; }
BOOL WINAPI WTSetA(HANDLE ctx, LOGCONTEXTA *lc) { log_line("WTSetA"); (void)ctx; (void)lc; return TRUE; }
BOOL WINAPI WTSetW(HANDLE ctx, LOGCONTEXTW *lc) {
    log_line("WTSetW"); (void)ctx;
    if (lc) {
        log_ctx("WTSetW ctx from SAI", lc);
        EnterCriticalSection(&g_cs);
        g_ctx = *lc; g_have_ctx = TRUE;
        LeaveCriticalSection(&g_cs);
    }
    return TRUE;
}

/* ---- remaining WinTab surface: well-behaved stubs so GetProcAddress never
 * fails. SAI resolves the whole API up front and aborts with "Windows function
 * call failed" if ANY export is missing — this was the startup crash. -------- */

BOOL WINAPI WTOverlap(HANDLE ctx, BOOL toTop) { log_line("WTOverlap %d", toTop); (void)ctx; (void)toTop; return TRUE; }
BOOL WINAPI WTConfig(HANDLE ctx, HWND hwnd) { log_line("WTConfig"); (void)ctx; (void)hwnd; return FALSE; }
BOOL WINAPI WTExtGet(HANDLE ctx, UINT ext, LPVOID out) { log_line("WTExtGet ext=%u", ext); (void)ctx; (void)out; return FALSE; }
BOOL WINAPI WTExtSet(HANDLE ctx, UINT ext, LPVOID in) { log_line("WTExtSet ext=%u", ext); (void)ctx; (void)in; return FALSE; }
BOOL WINAPI WTSave(HANDLE ctx, LPVOID save) { log_line("WTSave"); (void)ctx; (void)save; return FALSE; }
HANDLE WINAPI WTRestore(HWND hwnd, LPVOID save, BOOL enable) { log_line("WTRestore"); (void)hwnd; (void)save; (void)enable; return NULL; }
int  WINAPI WTPacketsPeek(HANDLE ctx, int max, LPVOID buf) { log_line("WTPacketsPeek max=%d", max); return WTPacketsGet(ctx, max, buf); }
int  WINAPI WTDataGet(HANDLE ctx, UINT b, UINT e, int max, LPVOID buf, LPINT n) { log_line("WTDataGet"); (void)ctx;(void)b;(void)e;(void)max;(void)buf; if(n)*n=0; return 0; }
int  WINAPI WTDataPeek(HANDLE ctx, UINT b, UINT e, int max, LPVOID buf, LPINT n) { log_line("WTDataPeek"); (void)ctx;(void)b;(void)e;(void)max;(void)buf; if(n)*n=0; return 0; }
BOOL WINAPI WTQueuePacketsEx(HANDLE ctx, UINT *o, UINT *n) { log_line("WTQueuePacketsEx"); (void)ctx; if(o)*o=0; if(n)*n=0; return FALSE; }
int  WINAPI WTQueueSizeGet(HANDLE ctx) { log_line("WTQueueSizeGet"); (void)ctx; return 32; }
HANDLE WINAPI WTMgrOpen(HWND hwnd, UINT msgBase) { log_line("WTMgrOpen"); (void)hwnd; (void)msgBase; return NULL; }
BOOL WINAPI WTMgrClose(HANDLE mgr) { log_line("WTMgrClose"); (void)mgr; return FALSE; }
BOOL WINAPI WTMgrContextEnum(HANDLE mgr, LPVOID fn, LPARAM lp) { log_line("WTMgrContextEnum"); (void)mgr;(void)fn;(void)lp; return FALSE; }
HWND WINAPI WTMgrContextOwner(HANDLE mgr, HANDLE ctx) { log_line("WTMgrContextOwner"); (void)mgr;(void)ctx; return NULL; }
HANDLE WINAPI WTMgrDefContext(HANDLE mgr, BOOL sys) { log_line("WTMgrDefContext"); (void)mgr;(void)sys; return NULL; }
HANDLE WINAPI WTMgrDefContextEx(HANDLE mgr, UINT dev, BOOL sys) { log_line("WTMgrDefContextEx"); (void)mgr;(void)dev;(void)sys; return NULL; }

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r) {
    (void)h; (void)r;
    if (reason == DLL_PROCESS_DETACH && g_click_hook) {
        UnhookWindowsHookEx(g_click_hook);
        g_click_hook = NULL;
    }
    if (reason == DLL_PROCESS_ATTACH) {
        InitializeCriticalSection(&g_cs);
        g_screenW = GetSystemMetrics(SM_CXSCREEN);
        g_screenH = GetSystemMetrics(SM_CYSCREEN);
        /* full virtual desktop spanning all monitors (single screen: == primary) */
        g_virtW = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        g_virtH = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        if (g_virtW <= 0) g_virtW = g_screenW;
        if (g_virtH <= 0) g_virtH = g_screenH;
        /* logging is OFF unless WT_DEBUG is set: without a log file, log_line() is a
         * no-op (g_log stays NULL) so there's zero per-packet fflush overhead. */
        if (getenv("WT_DEBUG")) g_log = fopen("C:\\wtlog.txt", "w");
        /* Must happen before SAI calls WTInfo/WTOpen — it reads the pressure
         * axis exactly once, at open time. */
        load_max_press();
        log_line("==== OwnTab wintab32.dll loaded; screen %dx%d virtual %dx%d maxPress=%d ====",
             g_screenW, g_screenH, g_virtW, g_virtH, g_max_press);
        CreateThread(NULL, 0, producer, NULL, 0, NULL);
    }
    return TRUE;
}
