/*
 * wtprobe.exe — a stand-in for SAI, so the RECEIVING half of the bridge can be
 * tested with SAI closed.
 *
 * Why this exists
 * ---------------
 * The app could always prove the SENDING half: the Test pen bar shows the exact
 * number the mac side just produced. Nothing proved the other half — that a
 * WinTab client inside Wine actually receives it — without launching SAI and
 * drawing. So a report of "the bar moves but strokes are flat" (#29) left the
 * whole far side unexamined, and the one thing that was wrong lived there.
 *
 * What makes it a real test rather than a self-check: this runs as a separate
 * Windows process and calls LoadLibrary("wintab32.dll"), so Wine resolves the
 * name through the SAME DllOverrides key SAI's load goes through. If that key
 * sends Wine to its own built-in wintab32, this probe gets the built-in one and
 * sees nothing — reproducing #29 exactly, with SAI closed. Then it follows SAI's
 * own path: open a context, and answer the WT_PACKET messages the DLL posts by
 * calling WTPacket() for each one. Every link the pen depends on is exercised.
 *
 * It prints key=value lines on stdout for the app to parse; it never decides
 * what the answer MEANS — that is BridgeCheck.probeVerdict(), which is pure and
 * unit-tested. Keep it that way: this file cannot be run by the test suite,
 * because it needs Wine.
 *
 * Build (see make-app.sh):
 *   x86_64-w64-mingw32-gcc -O2 -o wtprobe.exe wtprobe.c -luser32
 */

#include <windows.h>
#include <stdio.h>

/* ---- the subset of WinTab we need, copied from wintab32.c so the two agree -- */
typedef DWORD WTPKT;
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

#define WTI_DEFCONTEXT 3

typedef UINT   (WINAPI *PFN_WTInfoW)(UINT, UINT, LPVOID);
typedef HANDLE (WINAPI *PFN_WTOpenW)(HWND, LOGCONTEXTW *, BOOL);
typedef BOOL   (WINAPI *PFN_WTClose)(HANDLE);
typedef int    (WINAPI *PFN_WTPacket)(HANDLE, UINT, LPVOID);
typedef const char * (WINAPI *PFN_BridgeBuild)(void);

static PFN_WTPacket p_WTPacket;
static HANDLE       g_ctx;
static UINT         g_msgBase = 0x7ff0;   /* WT_DEFBASE until the context says otherwise */

static unsigned long g_msgs;      /* WT_PACKET messages the DLL posted to us */
static unsigned long g_fetched;   /* of those, the ones WTPacket actually handed over */
static unsigned      g_pmax_seen; /* strongest pressure that reached us */
static unsigned      g_last_press; /* pressure in the MOST RECENT packet */
static unsigned long g_down;      /* packets with the tip switch down */

/* SAI's own path: the DLL posts WT_PACKET carrying a serial, and the client
 * calls WTPacket() with that serial to collect it. Counting the messages AND
 * the successful fetches separately matters — a DLL that posts but hands back
 * nothing is a different fault from one that never posts. */
static LRESULT CALLBACK wnd_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == g_msgBase) {
        g_msgs++;
        OURPKT pk;
        memset(&pk, 0, sizeof pk);
        if (p_WTPacket && g_ctx && p_WTPacket(g_ctx, (UINT)wp, &pk)) {
            g_fetched++;
            g_last_press = pk.pressure;
            if (pk.pressure > g_pmax_seen) g_pmax_seen = pk.pressure;
            if (pk.buttons) g_down++;
        }
        return 0;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

int main(int argc, char **argv) {
    int secs = (argc > 1) ? atoi(argv[1]) : 6;
    /* Up to an hour: when the Pen tab runs this ALONGSIDE the pressure bar it
     * lives for as long as the test does, and is killed from the app rather
     * than timing out. The cap is a backstop against a stranded process. */
    if (secs < 1 || secs > 3600) secs = 6;

    printf("probe=1\n");

    /* Through Wine's DllOverrides, exactly as SAI's own load goes. */
    HMODULE h = LoadLibraryA("wintab32.dll");
    if (!h) {
        printf("dll=missing\nerr=%lu\n", (unsigned long)GetLastError());
        return 2;
    }
    printf("dll=loaded\n");

    /* The one question that cannot be answered from the mac side: WHICH
     * wintab32 did Wine just hand us? Only ours exports this. */
    PFN_BridgeBuild bb = (PFN_BridgeBuild)(void*)GetProcAddress(h, "SAIPP_BridgeBuild");
    printf("ours=%s\n", bb ? "yes" : "no");
    printf("build=%s\n", bb ? bb() : "-");

    PFN_WTInfoW p_info  = (PFN_WTInfoW)(void*)GetProcAddress(h, "WTInfoW");
    PFN_WTOpenW p_open  = (PFN_WTOpenW)(void*)GetProcAddress(h, "WTOpenW");
    PFN_WTClose p_close = (PFN_WTClose)(void*)GetProcAddress(h, "WTClose");
    p_WTPacket          = (PFN_WTPacket)(void*)GetProcAddress(h, "WTPacket");
    if (!p_info || !p_open || !p_WTPacket) {
        printf("entrypoints=missing\n");
        return 3;
    }
    printf("entrypoints=ok\n");

    /* WTInfo(0,0,NULL) is the standard "is a tablet there at all" probe. */
    printf("info=%u\n", p_info(0, 0, NULL));

    LOGCONTEXTW lc;
    memset(&lc, 0, sizeof lc);
    if (!p_info(WTI_DEFCONTEXT, 0, &lc)) {
        printf("defcontext=none\n");
    } else {
        printf("defcontext=ok\n");
        if (lc.lcMsgBase) g_msgBase = lc.lcMsgBase;
    }

    WNDCLASSW wc;
    memset(&wc, 0, sizeof wc);
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"SAIPPProbe";
    RegisterClassW(&wc);
    /* Never shown: the DLL only needs somewhere to post to, and a window
     * appearing over the user's screen mid-test would be its own bug report. */
    HWND win = CreateWindowExW(0, L"SAIPPProbe", L"SAI Pen Pressure probe",
                               WS_OVERLAPPEDWINDOW, 0, 0, 200, 100,
                               NULL, NULL, wc.hInstance, NULL);
    if (!win) { printf("window=failed\n"); return 4; }

    g_ctx = p_open(win, &lc, TRUE);
    printf("ctx=%s\n", g_ctx ? "open" : "failed");
    if (!g_ctx) { printf("secs=0\n"); return 5; }
    /* The context we ended up with decides which message to listen for. */
    if (lc.lcMsgBase) g_msgBase = lc.lcMsgBase;
    printf("msgbase=%u\n", g_msgBase);

    /* Unbuffered: these ticks are read live by the app through a pipe, and the
     * default block buffering would hold a second of them back and make the
     * receive bar lag the send bar for no reason at all. */
    setvbuf(stdout, NULL, _IONBF, 0);

    DWORD until = GetTickCount() + (DWORD)secs * 1000;
    DWORD next_tick = GetTickCount();
    for (;;) {
        MSG m;
        while (PeekMessageW(&m, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&m);
            DispatchMessageW(&m);
        }
        DWORD now = GetTickCount();
        /* ~10/s: fast enough to track a stroke next to a 60fps bar, slow
         * enough that the pipe carries nothing worth worrying about. */
        if (now >= next_tick) {
            /* If the app has gone, so has the reason to exist. A tick that
             * cannot be written means the read end of the pipe is closed, and
             * without this the process outlives the test that started it: four
             * of them were found running at once, each holding a WinTab context
             * and keeping wineserver alive with a stale registry. Terminating
             * from the mac side is not enough on its own — a signal to the wine
             * loader does not reliably take the Windows process with it. */
            if (printf("tick=1 p=%u msgs=%lu fetched=%lu pmax=%u down=%lu\n",
                       g_last_press, g_msgs, g_fetched, g_pmax_seen, g_down) < 0) break;
            next_tick = now + 100;
        }
        if (now >= until) break;
        Sleep(5);
    }

    if (p_close) p_close(g_ctx);

    printf("msgs=%lu\n", g_msgs);
    printf("fetched=%lu\n", g_fetched);
    printf("down=%lu\n", g_down);
    printf("pmax_seen=%u\n", g_pmax_seen);
    printf("secs=%d\n", secs);
    return 0;
}
