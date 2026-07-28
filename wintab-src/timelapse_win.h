/*
 * timelapse_win.h — the Win32 glue for the canvas timelapse recorder. Pure
 * logic lives in timelapse_core.h and is unit-tested natively; this file holds
 * only what needs Windows: a validated read, a capture thread, and frame files.
 *
 * INCLUDED BY wintab32.c, deliberately, rather than being its own .c file: the
 * build command (`x86_64-w64-mingw32-gcc -shared ... wintab32.c ...`) is spelled
 * out in README.md, CONTRIBUTING.md, TESTING.md, .github/workflows/build.yml and
 * the header of wintab32.c. A new translation unit would have to be added to all
 * of them, and whichever one got missed would hand somebody a link error. Same
 * reasoning as wintab_core.h. Must be included AFTER log_line() is defined.
 *
 * ---------------------------------------------------------------------------
 * OFF BY DEFAULT. Set WT_TIMELAPSE=1 to enable.
 * ---------------------------------------------------------------------------
 * This code runs INSIDE sai2.exe. A bad pointer here is not a failed read, it
 * is an access violation that takes SAI down and destroys unsaved artwork. It
 * is strictly more dangerous than everything else in this DLL, which is why it
 * is opt-in and why the guards below are worth their weight.
 *
 * ---------------------------------------------------------------------------
 * WHY NOT __try/__except
 * ---------------------------------------------------------------------------
 * The plan called for wrapping the pointer walk in SEH. mingw's GCC does not
 * support it — `__try` is an MSVC extension and fails to compile with
 * x86_64-w64-mingw32-gcc (verified, not assumed). So the defence is inverted:
 * rather than catching faults, we make them impossible.
 *
 *   1. EVERY read is validated with VirtualQuery first — the pages must be
 *      committed and readable across the whole range, or the read fails.
 *   2. timelapse_core.h refuses implausible structures before dereferencing
 *      anything they contain (see the tile-grid cross-check).
 *   3. A vectored exception handler latches the feature OFF if a fault ever
 *      does occur on our thread, so a one-off cannot become a repeat.
 *
 * The handler does not attempt to RESUME after a fault. Recovering would mean
 * either longjmp out of a VEH (undefined) or rewriting RIP in the context
 * record, and adding a fragile mechanism to protect against a case the
 * validated reads should already prevent is a poor trade. If a field report
 * ever shows tl: FAULT in the log, that is the point to revisit this.
 */
#ifndef TIMELAPSE_WIN_H
#define TIMELAPSE_WIN_H

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include "timelapse_core.h"

/* Frames land in the prefix, where the macOS-side encoder can pick them up.
 * C:\ is the prefix root, so this is ~/SAI2-pressure/drive_c/sai-timelapse. */
#define TL_DIR      "C:\\sai-timelapse"
#define TL_FRAMEDIR TL_DIR "\\frames"

#define TL_MAX_FRAME_BYTES (64u << 20)   /* refuse anything larger            */
#define TL_DEFAULT_TARGET  1024          /* longest side of a recorded frame  */
#define TL_DEFAULT_DEBOUNCE 150          /* ms of zero pressure = stroke end  */
#define TL_SETTLE_MS       120           /* let SAI finish compositing        */

typedef struct {
    char     magic[8];        /* "SAITLF1"                                    */
    uint32_t width, height;
    uint32_t stride;          /* bytes per row                                */
    uint32_t format;          /* 0 = BGRA8, matches kCVPixelFormatType_32BGRA */
    uint64_t seq;
    uint64_t tick_ms;
} TL_FRAME_HDR;

static volatile LONG  g_tl_disabled = 0;   /* latched off after a fault       */
static int            g_tl_on = 0;
static int            g_tl_probe = 0;
static uint32_t       g_tl_target = TL_DEFAULT_TARGET;
static HANDLE         g_tl_evt = NULL;
static HANDLE         g_tl_thread = NULL;
static TLC_STROKE     g_tl_stroke;
static uint64_t       g_tl_image_base = 0;
static uint64_t       g_tl_last_hash = 0;
static uint64_t       g_tl_seq = 0;
static uint8_t       *g_tl_frame = NULL;
static size_t         g_tl_frame_cap = 0;
static uint8_t       *g_tl_tile  = NULL;
static size_t         g_tl_tile_cap  = 0;
static const TLC_LAYOUT *g_tl_layout = &TLC_LAYOUT_2026_07_27;

/* Statics that track the CURRENT canvas rather than the list head. Derived
 * alongside session_offset; the exact semantics ("active" vs "most recently
 * opened") were never pinned down, so this is used as a HINT only — validated
 * before use, with a fall back to the first user canvas in the list. */
#define TL_ACTIVE_OFFSET 0x471388

/* --- validated read ------------------------------------------------------ */

/* One-entry cache. Reading a canvas walks hundreds of tiles that all live in
 * the same region, so re-querying per read is pure overhead. */
static uintptr_t g_tl_ok_lo = 0, g_tl_ok_hi = 0;

static int tl_range_readable(uintptr_t addr, size_t len) {
    MEMORY_BASIC_INFORMATION mbi;
    uintptr_t p = addr, end = addr + len;

    if (addr >= g_tl_ok_lo && end <= g_tl_ok_hi) return 1;

    while (p < end) {
        DWORD prot;
        uintptr_t region_end;
        if (VirtualQuery((LPCVOID)p, &mbi, sizeof mbi) != sizeof mbi) return 0;
        if (mbi.State != MEM_COMMIT) return 0;
        if (mbi.Protect & PAGE_GUARD) return 0;
        prot = mbi.Protect & 0xff;
        if (prot != PAGE_READONLY && prot != PAGE_READWRITE &&
            prot != PAGE_WRITECOPY && prot != PAGE_EXECUTE_READ &&
            prot != PAGE_EXECUTE_READWRITE && prot != PAGE_EXECUTE_WRITECOPY)
            return 0;
        region_end = (uintptr_t)mbi.BaseAddress + mbi.RegionSize;
        if (region_end <= p) return 0;            /* no forward progress      */
        if (p == addr && region_end >= end) { g_tl_ok_lo = (uintptr_t)mbi.BaseAddress;
                                              g_tl_ok_hi = region_end; }
        p = region_end;
    }
    return 1;
}

/* The TLC_READ_FN production supplies. In-process, so the "remote" read is a
 * memcpy — but only after the whole range is proven readable. */
static int tl_read(void *ctx, uint64_t addr, void *dst, size_t len) {
    (void)ctx;
    if (g_tl_disabled) return 0;
    if (!addr || !len) return 0;
    if (addr > (uint64_t)UINTPTR_MAX - len) return 0;
    if (!tl_range_readable((uintptr_t)addr, len)) return 0;
    memcpy(dst, (const void *)(uintptr_t)addr, len);
    return 1;
}

static LONG CALLBACK tl_veh(EXCEPTION_POINTERS *info) {
    DWORD code = info && info->ExceptionRecord ? info->ExceptionRecord->ExceptionCode : 0;
    if (!g_tl_disabled &&
        (code == EXCEPTION_ACCESS_VIOLATION || code == EXCEPTION_IN_PAGE_ERROR)) {
        InterlockedExchange(&g_tl_disabled, 1);
        log_line("tl: FAULT code=%#lx — timelapse disabled for this session", (unsigned long)code);
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static void tl_disable(const char *why) {
    if (!g_tl_disabled) {
        InterlockedExchange(&g_tl_disabled, 1);
        log_line("tl: disabled — %s", why);
    }
}

/* --- picking the canvas -------------------------------------------------- */

/* Node [0] of the list is SAI's internal ScratchPad, never a user document.
 * Returns 0 if nothing usable is open. */
static uint64_t tl_first_user_canvas(void) {
    uint64_t cur = 0;
    TLC_CANVAS cv;
    int n;
    if (!tlc_list_head(tl_read, NULL, g_tl_layout, g_tl_image_base, &cur)) return 0;
    for (n = 0; n < 64 && cur; n++) {
        uint64_t next = 0;
        if (n > 0 && tlc_canvas_read(tl_read, NULL, g_tl_layout, cur, &cv)) return cur;
        if (!tlc_canvas_next(tl_read, NULL, g_tl_layout, cur, &next)) break;
        cur = next;
    }
    return 0;
}

static uint64_t tl_target_canvas(void) {
    uint64_t active = 0, head = 0;
    TLC_CANVAS cv;
    /* Prefer the active-canvas hint so drawing on the second of two open
     * documents records the right one — but only if it validates AND is not
     * the scratch pad.
     *
     * The scratch-pad check is not theoretical. First real capture run logged:
     *     tl: frame 1  199x878   level=0      <- ScratchPad1
     *     tl: frame 2  1000x700  level=0      <- the actual canvas
     * Before any document is open the hint points at the scratch pad, which
     * validates as a perfectly good canvas, so it bypassed the skip-node-0 rule
     * that only governs the list walk. Rejecting the head covers it: the scratch
     * pad is always node 0. */
    if (!tlc_list_head(tl_read, NULL, g_tl_layout, g_tl_image_base, &head)) return 0;
    if (tl_read(NULL, g_tl_image_base + TL_ACTIVE_OFFSET, &active, 8) &&
        active && active != head &&
        tlc_canvas_read(tl_read, NULL, g_tl_layout, active, &cv))
        return active;
    return tl_first_user_canvas();
}

/* --- frame output -------------------------------------------------------- */

static int tl_ensure_buf(uint8_t **buf, size_t *cap, size_t need) {
    if (need > TL_MAX_FRAME_BYTES) return 0;
    if (*cap >= need) return 1;
    { uint8_t *nb = (uint8_t *)realloc(*buf, need);
      if (!nb) return 0;
      *buf = nb; *cap = need; }
    return 1;
}

/* Write .tmp then rename, so the macOS-side encoder never observes a partial
 * frame. The filesystem is the queue: no socket, no backpressure protocol, and
 * an encoder restart loses nothing. */
static int tl_write_frame(const uint8_t *px, uint32_t w, uint32_t h) {
    char tmp[MAX_PATH], fin[MAX_PATH];
    TL_FRAME_HDR hdr;
    FILE *fp;
    size_t bytes = (size_t)w * h * 4u;

    memset(&hdr, 0, sizeof hdr);
    memcpy(hdr.magic, "SAITLF1", 7);
    hdr.width = w; hdr.height = h; hdr.stride = w * 4u; hdr.format = 0;
    hdr.seq = ++g_tl_seq; hdr.tick_ms = GetTickCount64();

    snprintf(tmp, sizeof tmp, "%s\\%08llu.tmp", TL_FRAMEDIR, (unsigned long long)hdr.seq);
    snprintf(fin, sizeof fin, "%s\\%08llu.frame", TL_FRAMEDIR, (unsigned long long)hdr.seq);

    fp = fopen(tmp, "wb");
    if (!fp) { log_line("tl: cannot open %s", tmp); return 0; }
    if (fwrite(&hdr, sizeof hdr, 1, fp) != 1 || fwrite(px, 1, bytes, fp) != bytes) {
        fclose(fp); remove(tmp);
        log_line("tl: short write on frame %llu", (unsigned long long)hdr.seq);
        return 0;
    }
    fclose(fp);
    if (!MoveFileExA(tmp, fin, MOVEFILE_REPLACE_EXISTING)) {
        remove(tmp);
        log_line("tl: rename failed for frame %llu", (unsigned long long)hdr.seq);
        return 0;
    }
    return 1;
}

/* --- capture ------------------------------------------------------------- */

static void tl_capture_once(void) {
    uint64_t canvas, hash;
    TLC_TILEMAP tm;
    uint32_t w = 0, h = 0;
    int level;

    if (g_tl_disabled) return;

    canvas = tl_target_canvas();
    if (!canvas) return;                     /* nothing open; not an error    */

    level = tlc_pick_level(tl_read, NULL, g_tl_layout, canvas, g_tl_target);
    if (!tlc_tilemap_read(tl_read, NULL, g_tl_layout, canvas, level, &tm)) {
        tl_disable("tile map unreadable — offsets likely wrong for this SAI build");
        return;
    }
    if (!tl_ensure_buf(&g_tl_frame, &g_tl_frame_cap, (size_t)tm.width * tm.height * 4u) ||
        !tl_ensure_buf(&g_tl_tile,  &g_tl_tile_cap,  (size_t)tm.tile_w * tm.tile_h * 4u)) {
        tl_disable("frame too large to buffer");
        return;
    }
    if (!tlc_read_level(tl_read, NULL, g_tl_layout, canvas, level,
                        g_tl_frame, g_tl_frame_cap, g_tl_tile, g_tl_tile_cap, &w, &h)) {
        log_line("tl: level read failed (canvas closed mid-read?)");
        return;                              /* transient; do not latch off   */
    }

    /* Undo, pan, zoom and toolbar clicks all end a "stroke" without changing a
     * pixel. Dropping them here keeps them out of the video AND off the disk. */
    hash = tlc_hash(g_tl_frame, (size_t)w * h * 4u);
    if (hash == g_tl_last_hash) return;
    g_tl_last_hash = hash;

    if (tl_write_frame(g_tl_frame, w, h))
        log_line("tl: frame %llu  %ux%u  level=%d", (unsigned long long)g_tl_seq, w, h, level);
}

/* WT_TIMELAPSE_INTERVAL=<ms>: capture on a timer instead of waiting for a
 * stroke to end. A TEST AID, not a feature — it decouples "does the pixel
 * reading work" (stride, BGRA order, cropping) from "does the pen trigger
 * work", so the image path can be verified by drawing with a mouse and no
 * tablet connected. Stroke-driven capture is what ships. */
static uint32_t g_tl_interval = 0;

static DWORD WINAPI tl_thread(LPVOID arg) {
    (void)arg;
    for (;;) {
        DWORD w = WaitForSingleObject(g_tl_evt, g_tl_interval ? g_tl_interval : INFINITE);
        if (w != WAIT_OBJECT_0 && w != WAIT_TIMEOUT) break;
        if (g_tl_disabled) break;
        /* SAI composites the finished stroke into the tile map slightly after
         * the pen leaves the surface; reading immediately can catch the frame
         * before the last dab lands. */
        Sleep(TL_SETTLE_MS);
        tl_capture_once();
    }
    return 0;
}

/* --- probe --------------------------------------------------------------- */

/* WT_TIMELAPSE_PROBE=1: log the canvas list once and capture nothing. This is
 * the first thing to run against a new SAI build — if the names and sizes match
 * what is open, the offsets are right. */
static DWORD WINAPI tl_probe_thread(LPVOID arg) {
    uint64_t cur = 0;
    int n;
    (void)arg;
    Sleep(8000);                              /* give the user time to open one */
    log_line("tl probe: image_base=%#llx session_offset=%#llx",
             (unsigned long long)g_tl_image_base,
             (unsigned long long)g_tl_layout->session_offset);
    if (!tlc_list_head(tl_read, NULL, g_tl_layout, g_tl_image_base, &cur)) {
        log_line("tl probe: could not read the list head — offsets wrong for this build");
        return 0;
    }
    for (n = 0; n < 64 && cur; n++) {
        TLC_CANVAS cv;
        char name[64];
        uint64_t next = 0;
        if (tlc_canvas_read(tl_read, NULL, g_tl_layout, cur, &cv) &&
            tlc_canvas_name(tl_read, NULL, g_tl_layout, cur, name, sizeof name))
            log_line("tl probe: [%d] %#llx  %dx%d  \"%s\"%s", n,
                     (unsigned long long)cur, cv.width, cv.height, name,
                     n == 0 ? "  (scratch pad — skipped when recording)" : "");
        else
            log_line("tl probe: [%d] %#llx  not a plausible canvas", n,
                     (unsigned long long)cur);
        if (!tlc_canvas_next(tl_read, NULL, g_tl_layout, cur, &next)) break;
        cur = next;
    }
    log_line("tl probe: done");
    return 0;
}

/* --- entry points used by wintab32.c ------------------------------------- */

/* Called on every pressure sample from the producer. Cheap by construction:
 * a comparison and, at most, one SetEvent. The actual canvas read happens on
 * tl_thread so a slow read can never stall pressure delivery. */
static void tl_on_pressure(int press) {
    if (!g_tl_on || g_tl_probe || g_tl_disabled) return;
    if (tlc_stroke_update(&g_tl_stroke, press, (uint32_t)GetTickCount64()))
        SetEvent(g_tl_evt);
}

static void tl_startup(void) {
    const char *e;
    if (!getenv("WT_TIMELAPSE") && !getenv("WT_TIMELAPSE_PROBE")) return;

    g_tl_image_base = (uint64_t)(uintptr_t)GetModuleHandleW(NULL);
    if (!g_tl_image_base) { log_line("tl: GetModuleHandle(NULL) failed"); return; }

    AddVectoredExceptionHandler(1, tl_veh);

    if (getenv("WT_TIMELAPSE_PROBE")) {
        g_tl_probe = 1;
        log_line("tl: PROBE mode — logging the canvas list in 8s, capturing nothing");
        CreateThread(NULL, 0, tl_probe_thread, NULL, 0, NULL);
        return;
    }

    if ((e = getenv("WT_TIMELAPSE_SIZE")) != NULL) {
        long v = strtol(e, NULL, 10);
        if (v >= 64 && v <= 8192) g_tl_target = (uint32_t)v;
    }
    if ((e = getenv("WT_TIMELAPSE_INTERVAL")) != NULL) {
        long v = strtol(e, NULL, 10);
        if (v >= 200 && v <= 60000) g_tl_interval = (uint32_t)v;
    }
    tlc_stroke_init(&g_tl_stroke, TL_DEFAULT_DEBOUNCE);
    if ((e = getenv("WT_TIMELAPSE_DEBOUNCE")) != NULL) {
        long v = strtol(e, NULL, 10);
        if (v >= 0 && v <= 5000) g_tl_stroke.debounce_ms = (uint32_t)v;
    }

    CreateDirectoryA(TL_DIR, NULL);
    CreateDirectoryA(TL_FRAMEDIR, NULL);

    g_tl_evt = CreateEventA(NULL, FALSE, FALSE, NULL);
    if (!g_tl_evt) { log_line("tl: CreateEvent failed"); return; }
    g_tl_thread = CreateThread(NULL, 0, tl_thread, NULL, 0, NULL);
    if (!g_tl_thread) { log_line("tl: CreateThread failed"); return; }

    g_tl_on = 1;
    log_line("tl: recording enabled  base=%#llx target=%upx debounce=%ums interval=%ums -> %s",
             (unsigned long long)g_tl_image_base, g_tl_target,
             g_tl_stroke.debounce_ms, g_tl_interval, TL_FRAMEDIR);
}

#endif /* TIMELAPSE_WIN_H */
