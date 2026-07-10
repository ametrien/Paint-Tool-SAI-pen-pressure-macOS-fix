/*
 * Minimal custom wintab32.dll for PaintTool SAI Ver.2 under Wine on macOS.
 *
 * Purpose: feed SAI pen pressure. SAI already gets POSITION from the normal
 * cursor (it draws lines fine); this DLL supplies the WinTab pressure stream.
 *
 * Architecture:
 *   - No synthetic/test injection (so no phantom stroke on startup).
 *   - A producer thread reads the current pressure (0..1023) from a small file
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
#define MAX_PRESS  1023
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

static void logf(const char *fmt, ...) {
    if (!g_log) return;
    va_list ap; va_start(ap, fmt); vfprintf(g_log, fmt, ap); va_end(ap);
    fputc('\n', g_log); fflush(g_log);
}

static void fill_default_context(LOGCONTEXTW *lc) {
    memset(lc, 0, sizeof(*lc));
    static const WCHAR nm[] = L"OurDefault";
    memcpy(lc->lcName, nm, sizeof(nm));
    lc->lcOptions  = 0x0004;          /* CXO_MESSAGES */
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
typedef struct { int press, x, y, w, h, has_pos; } SAMPLE;
static SAMPLE g_sample;   /* last good sample */

static SAMPLE read_sample(void) {
    FILE *f = fopen("C:\\wt_pressure.txt", "rb");
    if (!f) return g_sample;
    int p=-1, x=0, y=0, w=0, h=0;
    int n = fscanf(f, "%d %d %d %d %d", &p, &x, &y, &w, &h);
    fclose(f);
    if (n < 1 || p < 0) return g_sample;
    if (p > MAX_PRESS) p = MAX_PRESS;
    g_sample.press = p;
    if (n == 5 && w > 0 && h > 0) {
        g_sample.x = x; g_sample.y = y; g_sample.w = w; g_sample.h = h;
        g_sample.has_pos = 1;
    } else {
        g_sample.has_pos = 0;
    }
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
        if (!eX) eX = IN_EXT;
        if (!eY) eY = IN_EXT;
        pk.x = oX + (LONG)((LONGLONG)s->x * eX / s->w);
        if (eY > 0)  /* y-up: mac y is already y-up */
            pk.y = oY + (LONG)((LONGLONG)s->y * eY / s->h);
        else         /* y-down */
            pk.y = oY + (LONG)((LONGLONG)(s->h - 1 - s->y) * (-eY) / s->h);
    }
    /* else: keep pk.x/pk.y from g_last (position-less pen-up) */

    int transition = (down != g_was_down);
    if (transition)           /* log tip transitions to investigate stray clicks */
        logf("PEN %s buttons=%u pk=(%ld,%ld) press=%u t=%lu",
             down ? "DOWN" : "UP", pk.buttons, (long)pk.x, (long)pk.y, pk.pressure, GetTickCount());
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
    int outstanding = (int)(g_serial - 1 - g_fetched);
    post = transition || outstanding < POST_WINDOW;
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
    if (g_dirty && (int)(g_serial - 1 - g_fetched) < POST_WINDOW) {
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

/* parse "p [x y w h]" into a SAMPLE */
static int parse_sample(const char *buf, SAMPLE *out) {
    int p=-1, x=0, y=0, w=0, h=0;
    int n = sscanf(buf, "%d %d %d %d %d", &p, &x, &y, &w, &h);
    if (n < 1 || p < 0) return 0;
    if (p > MAX_PRESS) p = MAX_PRESS;
    out->press = p;
    if (n == 5 && w > 0 && h > 0) { out->x=x; out->y=y; out->w=w; out->h=h; out->has_pos=1; }
    else out->has_pos = 0;
    return 1;
}

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
                logf("producer: UDP bind :%d failed (%d) — file mode only", SAMPLE_PORT, WSAGetLastError());
                closesocket(sock); sock = INVALID_SOCKET;
            } else {
                DWORD tv = 15;          /* ms; short so pending flush + housekeeping are prompt */
                setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
                logf("producer: listening on UDP 127.0.0.1:%d (blocking, immediate post)", SAMPLE_PORT);
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
                    logf("RATE recv=%lu fetches=%lu gap=%d tick=%lu",
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
        flush_pending();                /* pen still/lifted: deliver the final point */
        if (now - lastBeat > 2000) {
            lastBeat = now;
            logf("producer: open=%d hwnd=%p posted=%lu recv=%lu gaps=%lu fetched=%u udp=%s",
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
                char b[128]; int nb = (int)fread(b, 1, sizeof(b)-1, f); fclose(f);
                if (nb < 0) nb = 0; b[nb] = 0;
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
    logf("WTInfoW cat=%u idx=%u out=%p", cat, idx, out);
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
    logf("%s: pktData=%#lx pktMode=%#lx moveMask=%#lx opts=%#x msgBase=%#x rate=%u "
         "in=(%ld,%ld ext %ld,%ld) out=(%ld,%ld ext %ld,%ld) sys=(%d,%d ext %d,%d) sysMode=%d",
         who, (unsigned long)lc->lcPktData, (unsigned long)lc->lcPktMode,
         (unsigned long)lc->lcMoveMask, lc->lcOptions, lc->lcMsgBase, lc->lcPktRate,
         (long)lc->lcInOrgX, (long)lc->lcInOrgY, (long)lc->lcInExtX, (long)lc->lcInExtY,
         (long)lc->lcOutOrgX, (long)lc->lcOutOrgY, (long)lc->lcOutExtX, (long)lc->lcOutExtY,
         lc->lcSysOrgX, lc->lcSysOrgY, lc->lcSysExtX, lc->lcSysExtY, lc->lcSysMode);
}

HANDLE WINAPI WTOpenW(HWND hwnd, LOGCONTEXTW *lc, BOOL enable) {
    logf("WTOpenW hwnd=%p enable=%d", hwnd, enable);
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

BOOL WINAPI WTClose(HANDLE ctx) { (void)ctx; logf("WTClose"); g_open=FALSE; g_hwnd=NULL; return TRUE; }

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
        logf("WTPacket #%ld serial=%u x=%ld y=%ld press=%u lat=%lums", n, serial,
             (long)pk.x, (long)pk.y, pk.pressure, (unsigned long)lat);
    }
    return 1;
}

UINT WINAPI WTQueueSizeSet(HANDLE ctx, int n) { logf("WTQueueSizeSet n=%d", n); (void)ctx; (void)n; return 1; }
BOOL WINAPI WTGetW(HANDLE ctx, LOGCONTEXTW *lc) { logf("WTGetW"); (void)ctx; if(lc) fill_default_context(lc); return TRUE; }
BOOL WINAPI WTEnable(HANDLE ctx, BOOL enable) { logf("WTEnable enable=%d", enable); (void)ctx; g_open = enable?TRUE:FALSE; return TRUE; }
int  WINAPI WTPacketsGet(HANDLE ctx, int max, LPVOID buf) {
    logf("WTPacketsGet max=%d", max);
    (void)ctx; if (max<=0||!buf) return 0;
    EnterCriticalSection(&g_cs); OURPKT pk=g_last; int have = (read_pressure()>0); LeaveCriticalSection(&g_cs);
    if (!have) return 0; memcpy(buf,&pk,sizeof(pk)); return 1;
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
    logf("WTInfoA cat=%u idx=%u out=%p", cat, idx, out);
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
    logf("WTOpenA hwnd=%p enable=%d", hwnd, enable);
    g_hwnd = hwnd;
    g_open = enable ? TRUE : FALSE;
    if (lc) { lc->lcPktData = OUR_PKTDATA; lc->lcMsgBase = WT_DEFBASE; }
    return (HANDLE)(ULONG_PTR)0xC0FFEE01;
}

BOOL WINAPI WTGetA(HANDLE ctx, LOGCONTEXTA *lc) { logf("WTGetA"); (void)ctx; if(lc) fill_default_context_a(lc); return TRUE; }
BOOL WINAPI WTSetA(HANDLE ctx, LOGCONTEXTA *lc) { logf("WTSetA"); (void)ctx; (void)lc; return TRUE; }
BOOL WINAPI WTSetW(HANDLE ctx, LOGCONTEXTW *lc) {
    logf("WTSetW"); (void)ctx;
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

BOOL WINAPI WTOverlap(HANDLE ctx, BOOL toTop) { logf("WTOverlap %d", toTop); (void)ctx; (void)toTop; return TRUE; }
BOOL WINAPI WTConfig(HANDLE ctx, HWND hwnd) { logf("WTConfig"); (void)ctx; (void)hwnd; return FALSE; }
BOOL WINAPI WTExtGet(HANDLE ctx, UINT ext, LPVOID out) { logf("WTExtGet ext=%u", ext); (void)ctx; (void)out; return FALSE; }
BOOL WINAPI WTExtSet(HANDLE ctx, UINT ext, LPVOID in) { logf("WTExtSet ext=%u", ext); (void)ctx; (void)in; return FALSE; }
BOOL WINAPI WTSave(HANDLE ctx, LPVOID save) { logf("WTSave"); (void)ctx; (void)save; return FALSE; }
HANDLE WINAPI WTRestore(HWND hwnd, LPVOID save, BOOL enable) { logf("WTRestore"); (void)hwnd; (void)save; (void)enable; return NULL; }
int  WINAPI WTPacketsPeek(HANDLE ctx, int max, LPVOID buf) { logf("WTPacketsPeek max=%d", max); return WTPacketsGet(ctx, max, buf); }
int  WINAPI WTDataGet(HANDLE ctx, UINT b, UINT e, int max, LPVOID buf, LPINT n) { logf("WTDataGet"); (void)ctx;(void)b;(void)e;(void)max;(void)buf; if(n)*n=0; return 0; }
int  WINAPI WTDataPeek(HANDLE ctx, UINT b, UINT e, int max, LPVOID buf, LPINT n) { logf("WTDataPeek"); (void)ctx;(void)b;(void)e;(void)max;(void)buf; if(n)*n=0; return 0; }
BOOL WINAPI WTQueuePacketsEx(HANDLE ctx, UINT *o, UINT *n) { logf("WTQueuePacketsEx"); (void)ctx; if(o)*o=0; if(n)*n=0; return FALSE; }
int  WINAPI WTQueueSizeGet(HANDLE ctx) { logf("WTQueueSizeGet"); (void)ctx; return 32; }
HANDLE WINAPI WTMgrOpen(HWND hwnd, UINT msgBase) { logf("WTMgrOpen"); (void)hwnd; (void)msgBase; return NULL; }
BOOL WINAPI WTMgrClose(HANDLE mgr) { logf("WTMgrClose"); (void)mgr; return FALSE; }
BOOL WINAPI WTMgrContextEnum(HANDLE mgr, LPVOID fn, LPARAM lp) { logf("WTMgrContextEnum"); (void)mgr;(void)fn;(void)lp; return FALSE; }
HWND WINAPI WTMgrContextOwner(HANDLE mgr, HANDLE ctx) { logf("WTMgrContextOwner"); (void)mgr;(void)ctx; return NULL; }
HANDLE WINAPI WTMgrDefContext(HANDLE mgr, BOOL sys) { logf("WTMgrDefContext"); (void)mgr;(void)sys; return NULL; }
HANDLE WINAPI WTMgrDefContextEx(HANDLE mgr, UINT dev, BOOL sys) { logf("WTMgrDefContextEx"); (void)mgr;(void)dev;(void)sys; return NULL; }

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r) {
    (void)h; (void)r;
    if (reason == DLL_PROCESS_ATTACH) {
        InitializeCriticalSection(&g_cs);
        g_screenW = GetSystemMetrics(SM_CXSCREEN);
        g_screenH = GetSystemMetrics(SM_CYSCREEN);
        /* full virtual desktop spanning all monitors (single screen: == primary) */
        g_virtW = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        g_virtH = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        if (g_virtW <= 0) g_virtW = g_screenW;
        if (g_virtH <= 0) g_virtH = g_screenH;
        /* logging is OFF unless WT_DEBUG is set: without a log file, logf() is a
         * no-op (g_log stays NULL) so there's zero per-packet fflush overhead. */
        if (getenv("WT_DEBUG")) g_log = fopen("C:\\wtlog.txt", "w");
        logf("==== OwnTab wintab32.dll loaded; screen %dx%d virtual %dx%d ====",
             g_screenW, g_screenH, g_virtW, g_virtH);
        CreateThread(NULL, 0, producer, NULL, 0, NULL);
    }
    return TRUE;
}
