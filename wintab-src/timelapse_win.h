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
/* How soon after the pen lifts a frame is taken (2026-11-18). These were
 * 150 + 120 ms, so a stroke started within ~270 ms of the last one shared its
 * frame: two quick strokes recorded as one. Capturing every stroke matters
 * more than that margin:
 *   - the debounce guards against a pressure dip mid-stroke, but the app
 *     already holds every pen-up back for its own latch (WT_UP_LATCH, 150 ms)
 *     before we see it, so a dip never reaches us as a zero. 30 ms is for
 *     jitter only. WT_TIMELAPSE_DEBOUNCE still overrides it.
 *   - SAI has finished the stroke by the time we hear of it: it saves its
 *     recovery point at the button-up, before our pen-up line. 40 ms is
 *     margin for the last dab, not a measured need. */
#define TL_DEFAULT_DEBOUNCE 30           /* ms of zero pressure = stroke end  */
#define TL_SETTLE_MS        40           /* let SAI finish compositing        */
#define TL_DEFAULT_QUIET   1000          /* ms the pen must rest before a capture */
#define TL_DEFAULT_MAX_WAIT 10000        /* nonstop drawing: a frame between
                                            strokes at least this often       */
#define TL_VERIFY_FIRST    5             /* first captures read every tile    */
#define TL_VERIFY_EVERY    10            /* then every Nth capture does       */
#define TL_DEFAULT_BUDGET_MB 2048        /* frames on disk before thinning    */

/* Frame header, v2. 112 bytes, naturally aligned, little-endian.
 *
 * canvas_id and name were added so several open documents can be recorded as
 * separate videos. IDENTITY IS THE STRUCT ADDRESS, not the name: SAI allocates
 * a canvas once and never moves it, whereas a name can be changed at any time.
 * Keying on the name would split one document in two the moment it was renamed,
 * and merge two documents that happened to share a name. The name rides along
 * only as a label for the output file — last one seen wins. */
typedef struct {
    char     magic[8];        /* "SAITLF2"                                    */
    uint32_t width, height;
    uint32_t stride;          /* bytes per row                                */
    uint32_t format;          /* 0 = BGRA8, matches kCVPixelFormatType_32BGRA */
    uint64_t seq;
    uint64_t tick_ms;
    uint64_t canvas_id;       /* canvas struct address — stable identity      */
    char     name[64];        /* UTF-8, NUL-padded; display label only        */
} TL_FRAME_HDR;

static volatile LONG  g_tl_disabled = 0;   /* latched off after a fault       */
static int            g_tl_on = 0;
static int            g_tl_probe = 0;
static uint32_t       g_tl_target = TL_DEFAULT_TARGET;
static HANDLE         g_tl_evt = NULL;
static HANDLE         g_tl_thread = NULL;
static TLC_STROKE     g_tl_stroke;
static uint64_t       g_tl_image_base = 0;
/* Dedup state is PER CANVAS. A single global last-hash meant switching between
 * two open documents compared each against the other, so every switch looked
 * like a change and produced a frame, while a genuine no-op stroke right after
 * a switch could be missed. */
#define TL_MAX_TRACKED 8
static TLC_SLOT g_tl_seen[TL_MAX_TRACKED];

/* What caused the pending capture: 0 = pen pressure, 1 = mouse button. Only
 * used for the log, so a racy write between the two trigger paths is fine. */
static volatile LONG  g_tl_trigger = 0;
static uint64_t       g_tl_seq = 0;
static uint64_t       g_tl_bytes = 0;    /* frame bytes currently on disk     */
static uint64_t       g_tl_budget = (uint64_t)TL_DEFAULT_BUDGET_MB << 20;
static uint8_t       *g_tl_frame = NULL;
static size_t         g_tl_frame_cap = 0;
static uint8_t       *g_tl_small = NULL;     /* the frame shrunk to g_tl_target */
static size_t         g_tl_small_cap = 0;
static uint8_t       *g_tl_tile  = NULL;
static size_t         g_tl_tile_cap  = 0;
/* The canvas fields are 07.27's for every build so far (issue #56); only
 * session_offset differs, and tl_anchor_ready sets it in this copy. */
static TLC_LAYOUT        g_tl_layout_rw;
static const TLC_LAYOUT *g_tl_layout = &g_tl_layout_rw;

/* Where the canvas list is, and how we know (TLC_TL_*; also the status line). */
static volatile LONG  g_tl_state = TLC_TL_OFF;
static uint64_t       g_tl_image_end = 0;
static uint32_t       g_tl_pe_stamp = 0, g_tl_pe_size = 0;
#define TL_MAX_RANGES 16
static uint64_t       g_tl_ranges[2 * TL_MAX_RANGES];   /* writable data sections */
static int            g_tl_nranges = 0;
static DWORD          g_tl_last_search = 0;
#define TL_SEARCH_GAP_MS 5000   /* a failed search is not repeated sooner      */

/* Capture only when the pen rests (RECORDING-SPEED-PLAN.md, package 2).
 * Written by the producer thread and SAI's UI thread, read by tl_thread. */
static volatile LONG  g_tl_last_activity = 0;   /* GetTickCount() of the last press */
static volatile LONG  g_tl_pen_down = 0;
static uint32_t       g_tl_quiet_ms = TL_DEFAULT_QUIET;
static uint32_t       g_tl_max_wait_ms = TL_DEFAULT_MAX_WAIT;

/* Reading only changed tiles (package 4). */
static TLC_TILECACHE  g_tl_cache;
static unsigned long  g_tl_captures = 0;
static int            g_tl_ptrs_unreliable = 0;

/* A static that tracks the CURRENT canvas sits right after the list head
 * (0x471388 in 07.27). The exact semantics ("active" vs "most recently
 * opened") were never pinned down, so it is a HINT only: used when it points
 * at a canvas in the open list, else the first user canvas is recorded. In a
 * build we found by search, +8 is a guess, and the list check is what keeps a
 * wrong guess harmless. */
#define TL_ACTIVE_AFTER_HEAD 8

/* --- validated read ------------------------------------------------------ */

/* Areas already confirmed readable (package 3). The old one-entry cache kept
 * missing, because tile pointers and tile pixels live in different blocks, so
 * nearly every read asked Wine again. Cleared at the start of every capture:
 * see the trap in tl_capture_once. */
static TLC_REGIONS    g_tl_regions;
static unsigned long  g_tl_vq_calls = 0;        /* VirtualQuery calls this capture */

static int tl_range_readable(uintptr_t addr, size_t len) {
    MEMORY_BASIC_INFORMATION mbi;
    uintptr_t p = addr, end = addr + len;

    if (tlc_regions_covers(&g_tl_regions, (uint64_t)addr, len)) return 1;

    while (p < end) {
        DWORD prot;
        uintptr_t region_end;
        g_tl_vq_calls++;
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
        tlc_regions_add(&g_tl_regions, (uint64_t)(uintptr_t)mbi.BaseAddress, (uint64_t)region_end);
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

/* --- finding the canvas list (issue #56) --------------------------------- */

/* sai2.exe's build stamp, size and writable data sections, from its own PE
 * header in memory. Called once at startup. */
static void tl_read_pe_info(void) {
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)(uintptr_t)g_tl_image_base;
    const IMAGE_NT_HEADERS *nth;
    const IMAGE_SECTION_HEADER *sec;
    WORD i;
    if (!dos || dos->e_magic != IMAGE_DOS_SIGNATURE) return;
    nth = (const IMAGE_NT_HEADERS *)((const BYTE *)dos + dos->e_lfanew);
    if (nth->Signature != IMAGE_NT_SIGNATURE) return;
    g_tl_pe_stamp = nth->FileHeader.TimeDateStamp;
    g_tl_pe_size = nth->OptionalHeader.SizeOfImage;
    g_tl_image_end = g_tl_image_base + g_tl_pe_size;
    sec = IMAGE_FIRST_SECTION(nth);
    for (i = 0; i < nth->FileHeader.NumberOfSections && g_tl_nranges < TL_MAX_RANGES; i++, sec++) {
        /* Data only: written by SAI, never run. The list head is a variable. */
        if (!(sec->Characteristics & IMAGE_SCN_MEM_WRITE) ||
            (sec->Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
        g_tl_ranges[2 * g_tl_nranges]     = g_tl_image_base + sec->VirtualAddress;
        g_tl_ranges[2 * g_tl_nranges + 1] = g_tl_image_base + sec->VirtualAddress + sec->Misc.VirtualSize;
        g_tl_nranges++;
    }
}

static void tl_set_state(LONG state, uint64_t offset) {
    g_tl_layout_rw.session_offset = offset;
    InterlockedExchange(&g_tl_state, state);
}

/* Is the canvas list known, and still where we think? Runs on the capture
 * thread before every capture, never on the pen path. Every change of answer
 * is logged once: recording used to fail without a word (issue #56). */
static int tl_anchor_ready(void) {
    LONG st = g_tl_state;
    DWORD now = GetTickCount();
    TLC_FOUND fd;
    if (st == TLC_TL_KNOWN || st == TLC_TL_FOUND) {
        if (tlc_anchor_ok(tl_read, NULL, g_tl_layout, g_tl_image_base, g_tl_layout_rw.session_offset))
            return 1;
        /* E.g. the slot taken while only the scratch pad was open was a
         * "current canvas" static, and now points at a drawing. Look again
         * straight away: it was working a moment ago. */
        log_line("tl: the canvas list is no longer at +%#llx; looking again",
                 (unsigned long long)g_tl_layout_rw.session_offset);
        g_tl_last_search = 0;
    }
    if (st != TLC_TL_FOUND) {
        const TLC_KNOWN_BUILD *kb = tlc_known_build(g_tl_pe_stamp, g_tl_pe_size);
        if (kb && tlc_anchor_ok(tl_read, NULL, g_tl_layout, g_tl_image_base, kb->session_offset)) {
            if (st != TLC_TL_KNOWN)
                log_line("tl: SAI %s, canvas list at +%#llx (checked build)",
                         kb->name, (unsigned long long)kb->session_offset);
            tl_set_state(TLC_TL_KNOWN, kb->session_offset);
            return 1;
        }
    }
    if (g_tl_last_search && now - g_tl_last_search < TL_SEARCH_GAP_MS) return 0;
    g_tl_last_search = now ? now : 1;

    tlc_find_session(tl_read, NULL, g_tl_layout, g_tl_image_base, g_tl_image_end,
                     g_tl_ranges, g_tl_nranges, &fd);
    if (fd.status == TLC_FIND_FOUND) {
        if (st != TLC_TL_FOUND || fd.offset != g_tl_layout_rw.session_offset)
            log_line("tl: found the canvas list at +%#llx (%d canvas(es), %d slot(s) hold it, "
                     "%lu looked at; SAI build stamp %#lx size %#lx)",
                     (unsigned long long)fd.offset, fd.nodes, fd.slots, fd.checked,
                     (unsigned long)g_tl_pe_stamp, (unsigned long)g_tl_pe_size);
        tl_set_state(TLC_TL_FOUND, fd.offset);
        return 1;
    }
    {
        LONG ns = fd.status == TLC_FIND_AMBIGUOUS ? TLC_TL_AMBIGUOUS : TLC_TL_NONE;
        if (st != ns)
            log_line(ns == TLC_TL_AMBIGUOUS
                     ? "tl: two canvas lists look alike; recording nothing rather than guess "
                       "(%lu slots looked at, SAI build stamp %#lx size %#lx)"
                     : "tl: no canvas list found; this SAI build is not supported yet "
                       "(%lu slots looked at, SAI build stamp %#lx size %#lx)",
                     fd.checked, (unsigned long)g_tl_pe_stamp, (unsigned long)g_tl_pe_size);
        tl_set_state(ns, 0);
    }
    return 0;
}

static uint64_t tl_target_canvas(void) {
    uint64_t active = 0, head = 0;
    TLC_CANVAS cv;
    if (!tl_anchor_ready()) return 0;
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
    if (tl_read(NULL, g_tl_image_base + g_tl_layout_rw.session_offset + TL_ACTIVE_AFTER_HEAD,
                &active, 8) &&
        active && active != head &&
        tlc_canvas_read(tl_read, NULL, g_tl_layout, active, &cv) &&
        tlc_list_contains(tl_read, NULL, g_tl_layout, head, active))
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
static int tl_write_frame(const uint8_t *px, uint32_t w, uint32_t h,
                          uint64_t canvas, const char *name) {
    char tmp[MAX_PATH], fin[MAX_PATH];
    TL_FRAME_HDR hdr;
    FILE *fp;
    size_t bytes = (size_t)w * h * 4u;

    memset(&hdr, 0, sizeof hdr);
    memcpy(hdr.magic, "SAITLF2", 7);
    hdr.width = w; hdr.height = h; hdr.stride = w * 4u; hdr.format = 0;
    hdr.seq = ++g_tl_seq; hdr.tick_ms = GetTickCount64();
    hdr.canvas_id = canvas;
    /* memcpy not strncpy: the name is already bounded and NUL-padded by the
     * memset above, and gcc warns about strncpy truncation here. */
    if (name) { size_t nl = strlen(name); if (nl > sizeof hdr.name - 1) nl = sizeof hdr.name - 1;
                memcpy(hdr.name, name, nl); }

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

/* Frames are raw BGRA — around 3 MB each — so an unbounded recording would eat
 * gigabytes: 2000 strokes of a 1000x700 canvas is 5.6 GB, and a bigger canvas
 * is worse. Something has to give.
 *
 * Deleting the OLDEST frames is the obvious move and the wrong one: it eats the
 * start of the drawing, which is the part people most want to watch. Deleting
 * every SECOND frame instead halves the size while still spanning the whole
 * session, just at coarser granularity — and it can repeat as often as needed,
 * each pass halving again. A long session degrades in temporal detail rather
 * than losing its beginning.
 *
 * This is the same idea as the encoder's --max-seconds resample, applied
 * earlier because disk, not video length, is the binding constraint. */
static void tl_enforce_budget(void) {
    WIN32_FIND_DATAA fd;
    char pat[MAX_PATH], full[MAX_PATH * 2];
    HANDLE h;
    int total = 0, i, deleted = 0;
    uint64_t kept = 0;

    if (g_tl_bytes <= g_tl_budget) return;

    snprintf(pat, sizeof pat, "%s\\*.frame", TL_FRAMEDIR);

    /* Two passes rather than one. Deleting while advancing the same iterator
     * needs the handle moved in two places at once, which is where the first
     * attempt at this went wrong; counting first keeps it obviously correct. */
    h = FindFirstFileA(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do { total++; } while (FindNextFileA(h, &fd));
    FindClose(h);
    h = FindFirstFileA(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    i = 0;
    do {
        uint64_t sz = ((uint64_t)fd.nFileSizeHigh << 32) | fd.nFileSizeLow;
        /* Never the last frame: it is the current state of the drawing, and a
         * timelapse missing its final image looks broken. */
        if (tlc_should_thin(i, total)) {
            snprintf(full, sizeof full, "%s\\%s", TL_FRAMEDIR, fd.cFileName);
            if (DeleteFileA(full)) deleted++;
            else kept += sz;
        } else {
            kept += sz;
        }
        i++;
    } while (FindNextFileA(h, &fd));
    FindClose(h);

    g_tl_bytes = kept;
    log_line("tl: over budget — thinned every 2nd frame (%d of %d removed, now %lluMB of %lluMB)",
             deleted, total, (unsigned long long)(kept >> 20),
             (unsigned long long)(g_tl_budget >> 20));
}

/* Count what is already on disk, so a budget set mid-session or frames left by
 * a previous run are accounted for rather than ignored. */
static void tl_scan_existing(void) {
    WIN32_FIND_DATAA fd;
    char pat[MAX_PATH];
    HANDLE h;
    g_tl_bytes = 0;
    snprintf(pat, sizeof pat, "%s\\*.frame", TL_FRAMEDIR);
    h = FindFirstFileA(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do { g_tl_bytes += ((uint64_t)fd.nFileSizeHigh << 32) | fd.nFileSizeLow; }
    while (FindNextFileA(h, &fd));
    FindClose(h);
}

/* --- capture ------------------------------------------------------------- */

/* Milliseconds between two QueryPerformanceCounter readings. */
static double tl_ms(LARGE_INTEGER a, LARGE_INTEGER b) {
    static LARGE_INTEGER f;
    if (!f.QuadPart) QueryPerformanceFrequency(&f);
    return f.QuadPart ? (double)(b.QuadPart - a.QuadPart) * 1000.0 / (double)f.QuadPart : 0.0;
}

/* Grow the per-tile arrays of g_tl_cache. Growing empties the cache, so the
 * next read is full. */
static int tl_ensure_cache(uint32_t n) {
    uint64_t *p, *h;
    if (g_tl_cache.cap >= n && g_tl_cache.ptr && g_tl_cache.hash) return 1;
    if (n > TLC_MAX_TILES) return 0;
    p = (uint64_t *)realloc(g_tl_cache.ptr, (size_t)n * 8u);
    if (!p) return 0;
    g_tl_cache.ptr = p;
    h = (uint64_t *)realloc(g_tl_cache.hash, (size_t)n * 8u);
    if (!h) return 0;
    g_tl_cache.hash = h;
    g_tl_cache.cap = n;
    g_tl_cache.ntiles = 0;
    return 1;
}

static void tl_capture_once(DWORD waited_ms) {
    uint64_t canvas, hash;
    TLC_TILEMAP tm;
    TLC_READSTATS st;
    LARGE_INTEGER t0, t1, t2, t3;
    uint32_t w = 0, h = 0;
    int level, verify;
    const char *result = "failed";

    if (g_tl_disabled) return;

    /* THE TRAP: forget every remembered-readable area before reading. SAI
     * frees memory between captures, and a stale "readable" answer would
     * memcpy from freed memory. tl_veh only logs, so that fault would take SAI
     * down with the drawing unsaved. Cleared here, an answer is at most one
     * capture old. (The old one-entry cache was never cleared.) */
    tlc_regions_clear(&g_tl_regions);
    g_tl_vq_calls = 0;
    memset(&st, 0, sizeof st);
    QueryPerformanceCounter(&t0);
    t1 = t2 = t3 = t0;

    canvas = tl_target_canvas();
    {
        /* Said once each time it changes, never once per stroke. When the
         * list itself is missing, tl_anchor_ready has already said why. */
        static int said_nothing_open = 0;
        int list_ok = g_tl_state == TLC_TL_KNOWN || g_tl_state == TLC_TL_FOUND;
        if (!canvas && list_ok && !said_nothing_open)
            log_line("tl: no drawing open, only the scratch pad; nothing to record yet");
        said_nothing_open = !canvas && list_ok;
    }
    if (!canvas) return;

    /* Level 0, the canvas itself, shrunk below to g_tl_target. SAI's reduced
     * copies were not always drawn (dark or blank frames, 2026-11-18). */
    level = tlc_full_level(tl_read, NULL, g_tl_layout, canvas, TL_MAX_FRAME_BYTES);
    if (!tlc_tilemap_read(tl_read, NULL, g_tl_layout, canvas, level, &tm)) {
        tl_disable("tile map unreadable — offsets likely wrong for this SAI build");
        return;
    }
    if (!tl_ensure_buf(&g_tl_frame, &g_tl_frame_cap, (size_t)tm.width * tm.height * 4u) ||
        !tl_ensure_buf(&g_tl_tile,  &g_tl_tile_cap,  (size_t)tm.tile_w * tm.tile_h * 4u)) {
        tl_disable("frame too large to buffer");
        return;
    }
    if (!tl_ensure_cache(tm.count_x * tm.count_y)) {
        tl_disable("tile cache too large");
        return;
    }

    /* Skipping unchanged tiles trusts that SAI gives a changed tile a new
     * block. Check that by reading every tile on the first captures and then
     * every Nth one; once it is ever wrong, read every tile for the session. */
    verify = g_tl_ptrs_unreliable || g_tl_captures < TL_VERIFY_FIRST ||
             (g_tl_captures % TL_VERIFY_EVERY) == 0;
    g_tl_captures++;

    if (!tlc_read_level_incremental(tl_read, NULL, g_tl_layout, canvas, level,
                                    g_tl_frame, g_tl_frame_cap, g_tl_tile, g_tl_tile_cap,
                                    &g_tl_cache, verify, &w, &h, &st)) {
        log_line("tl: level read failed (canvas closed mid-read?)");
        QueryPerformanceCounter(&t3);
        t1 = t2 = t3;
        goto done;                           /* transient; do not latch off   */
    }
    QueryPerformanceCounter(&t1);
    if (st.inplace_changes && !g_tl_ptrs_unreliable) {
        g_tl_ptrs_unreliable = 1;
        log_line("tl: SAI changed %u tile(s) in place; reading every tile from now on",
                 st.inplace_changes);
    }

    /* Undo, pan, zoom and toolbar clicks all end a "stroke" without changing a
     * pixel. Dropping them here keeps them out of the video AND off the disk.
     * The fingerprint is the hash of the per-tile hashes, so it costs nothing
     * extra and a new block holding the same pixels is still "no change". */
    {
    uint64_t *slot = tlc_hash_slot(g_tl_seen, TL_MAX_TRACKED, canvas);
    char cname[64];
    if (!tlc_canvas_name(tl_read, NULL, g_tl_layout, canvas, cname, sizeof cname))
        cname[0] = 0;
    hash = st.frame_hash;
    QueryPerformanceCounter(&t2);
    if (hash == *slot) {
        /* Logged, not silent: "why did I get fewer frames than strokes?" is
         * otherwise unanswerable, and the answer is usually that the trigger
         * was a toolbar click rather than a lost stroke. */
        log_line("tl: no pixel change (%s) — skipped", g_tl_trigger ? "mouse" : "pen");
        result = "nochange";
        t3 = t2;
        goto done;
    }
    *slot = hash;

    {
    /* Shrink to the chosen size here, after the dedup hash (which is of the
     * full canvas, so a change too small to survive shrinking still counts). */
    uint32_t ow, oh;
    const uint8_t *out = g_tl_frame;
    tlc_shrink_size(w, h, g_tl_target, &ow, &oh);
    if (ow != w || oh != h) {
        if (!tl_ensure_buf(&g_tl_small, &g_tl_small_cap, (size_t)ow * oh * 4u)) {
            tl_disable("shrunk frame too large to buffer");
            goto done;
        }
        tlc_downscale_bgra(g_tl_frame, w, h, g_tl_small, ow, oh);
        out = g_tl_small;
    }
    g_tl_bytes += (uint64_t)sizeof(TL_FRAME_HDR) + (uint64_t)ow * oh * 4u;
    tl_enforce_budget();
    if (tl_write_frame(out, ow, oh, canvas, cname)) {
        result = "written";
        /* The corner pixel, as #rrggbb: white paper reads #ffffff. A dark
         * corner (#171717) was SAI's reduced copy not drawn yet, before
         * recording read level 0; logged in case anything like it returns. */
        log_line("tl: frame %llu  %ux%u from %ux%u  level=%d  (%s)  \"%s\"  corner=#%02x%02x%02x",
                 (unsigned long long)g_tl_seq, ow, oh, w, h, level,
                 g_tl_trigger ? "mouse" : "pen", cname, out[2], out[1], out[0]);
    }
    }
    QueryPerformanceCounter(&t3);
    }

done:
    /* One line per capture, so the cost of each step is measured, not guessed
     * (package 1). waited = time from the trigger to the capture. */
    log_line("tl: capture waited=%lums read=%.1fms hash=%.1fms write=%.1fms total=%.1fms "
             "tiles=%u/%u vq=%lu verify=%d result=%s",
             (unsigned long)waited_ms, tl_ms(t0, t1), tl_ms(t1, t2), tl_ms(t2, t3), tl_ms(t0, t3),
             st.tiles_read, st.tiles_total, g_tl_vq_calls, verify, result);
}

/* WT_TIMELAPSE_INTERVAL=<ms>: capture on a timer instead of waiting for a
 * stroke to end. A TEST AID, not a feature — it decouples "does the pixel
 * reading work" (stride, BGRA order, cropping) from "does the pen trigger
 * work", so the image path can be verified by drawing with a mouse and no
 * tablet connected. Stroke-driven capture is what ships. */
static uint32_t g_tl_interval = 0;

/* How long after SAI starts the canvas list is first looked for, stroke or
 * no stroke, so the app can say whether recording will work before anyone
 * draws. SAI has made its scratch pad by then. */
#define TL_FIRST_LOOK_MS 15000

static DWORD WINAPI tl_thread(LPVOID arg) {
    int first_look_done = 0;
    (void)arg;
    for (;;) {
        DWORD pending_since;
        DWORD wait = g_tl_interval ? g_tl_interval : INFINITE;
        DWORD w;
        if (!first_look_done && (wait == INFINITE || wait > TL_FIRST_LOOK_MS)) wait = TL_FIRST_LOOK_MS;
        w = WaitForSingleObject(g_tl_evt, wait);
        if (w != WAIT_OBJECT_0 && w != WAIT_TIMEOUT) break;
        if (g_tl_disabled) break;
        if (w == WAIT_TIMEOUT && !first_look_done && !g_tl_interval) {
            first_look_done = 1;
            if (g_tl_state == TLC_TL_WAITING) {
                tlc_regions_clear(&g_tl_regions);   /* same rule as a capture */
                tl_anchor_ready();
            }
            continue;
        }
        first_look_done = 1;
        if (w == WAIT_TIMEOUT) {             /* WT_TIMELAPSE_INTERVAL test aid */
            Sleep(TL_SETTLE_MS);
            tl_capture_once(0);
            continue;
        }
        /* Wait until the pen rests. A capture running during a stroke made
         * SAI fall behind the pen (8% of points merged with recording on,
         * 0.5% off). The rest is at least TL_SETTLE_MS, which also gives SAI
         * time to finish compositing the last dab. */
        pending_since = GetTickCount();
        for (;;) {
            uint32_t rem;
            if (g_tl_disabled) return 0;
            rem = tlc_capture_wait((uint32_t)GetTickCount(), (uint32_t)g_tl_last_activity,
                                   (uint32_t)pending_since, (int)g_tl_pen_down,
                                   g_tl_quiet_ms, g_tl_max_wait_ms);
            if (!rem) break;
            Sleep(rem);
        }
        /* Triggers that arrived while we waited are covered by this capture,
         * which reads the canvas after all of them. Clear the auto-reset event
         * so they do not cause a second, pointless capture straight after. */
        WaitForSingleObject(g_tl_evt, 0);
        tl_capture_once(GetTickCount() - pending_since);
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
    /* Only a press is activity. Hover samples and the ~10 Hz idle tick both
     * arrive here with pressure 0; counting them would mean the pen never
     * rests. Hot path: one tick read and one store. */
    if (press > 0) {
        InterlockedExchange(&g_tl_last_activity, (LONG)GetTickCount());
        g_tl_pen_down = 1;
    } else {
        g_tl_pen_down = 0;
    }
    if (tlc_stroke_update(&g_tl_stroke, press, (uint32_t)GetTickCount64())) {
        g_tl_trigger = 0;
        SetEvent(g_tl_evt);
    }
}

/* Mouse button released over SAI. The SECOND stroke trigger, and not optional:
 * tying capture to pen pressure alone silently records nothing at all when the
 * user draws with a mouse or trackpad — which is a broken feature, not an
 * unsupported configuration. Found the hard way, by recording a whole session
 * that produced zero frames.
 *
 * Firing on any left-button release over SAI is deliberately crude: it also
 * fires for toolbar clicks, menu picks and canvas panning. That costs one
 * canvas read whose hash matches the previous frame, so nothing is written and
 * nothing reaches the video. Cheaper than trying to identify canvas-only
 * clicks, and it cannot miss a real stroke.
 *
 * Pen taps synthesise mouse clicks too, so a tablet stroke can trigger both
 * paths. The dedup hash collapses that to one frame. */
static void tl_on_mouse_up(void) {
    if (!g_tl_on || g_tl_probe || g_tl_disabled) return;
    InterlockedExchange(&g_tl_last_activity, (LONG)GetTickCount());  /* mouse/trackpad users */
    g_tl_trigger = 1;
    SetEvent(g_tl_evt);
}

static void tl_startup(void) {
    const char *e;
    if (!getenv("WT_TIMELAPSE") && !getenv("WT_TIMELAPSE_PROBE")) return;

    g_tl_image_base = (uint64_t)(uintptr_t)GetModuleHandleW(NULL);
    if (!g_tl_image_base) { log_line("tl: GetModuleHandle(NULL) failed"); return; }
    g_tl_layout_rw = TLC_LAYOUT_2026_07_27;  /* session_offset is set once found */
    tl_read_pe_info();

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

    if ((e = getenv("WT_TIMELAPSE_QUIET_MS")) != NULL) {
        long v = strtol(e, NULL, 10);
        if (v >= 0 && v <= 10000) g_tl_quiet_ms = (uint32_t)v;
    }
    if (g_tl_quiet_ms < TL_SETTLE_MS) g_tl_quiet_ms = TL_SETTLE_MS;
    if ((e = getenv("WT_TIMELAPSE_MAX_WAIT_MS")) != NULL) {
        long v = strtol(e, NULL, 10);
        if (v >= 1000 && v <= 120000) g_tl_max_wait_ms = (uint32_t)v;
    }

    if ((e = getenv("WT_TIMELAPSE_BUDGET_MB")) != NULL) {
        long v = strtol(e, NULL, 10);
        if (v >= 64 && v <= 200000) g_tl_budget = (uint64_t)v << 20;
    }
    CreateDirectoryA(TL_DIR, NULL);
    CreateDirectoryA(TL_FRAMEDIR, NULL);
    tl_scan_existing();

    g_tl_evt = CreateEventA(NULL, FALSE, FALSE, NULL);
    if (!g_tl_evt) { log_line("tl: CreateEvent failed"); return; }
    g_tl_thread = CreateThread(NULL, 0, tl_thread, NULL, 0, NULL);
    if (!g_tl_thread) { log_line("tl: CreateThread failed"); return; }
    /* Below SAI, so SAI wins when both want the processor (package 5).
     * Not IDLE: a resting pen should still get its frame promptly. Whether
     * Wine on macOS turns this into a real priority is logged, not assumed. */
    {
    BOOL low = SetThreadPriority(g_tl_thread, THREAD_PRIORITY_LOWEST);

    g_tl_on = 1;
    InterlockedExchange(&g_tl_state, TLC_TL_WAITING);
    log_line("tl: recording enabled  base=%#llx target=%upx debounce=%ums interval=%ums "
             "quiet=%ums max_wait=%ums priority=%s budget=%lluMB existing=%lluMB -> %s",
             (unsigned long long)g_tl_image_base, g_tl_target,
             g_tl_stroke.debounce_ms, g_tl_interval,
             g_tl_quiet_ms, g_tl_max_wait_ms, low ? "lowest" : "unchanged",
             (unsigned long long)(g_tl_budget >> 20),
             (unsigned long long)(g_tl_bytes >> 20), TL_FRAMEDIR);
    }
    log_line("tl: SAI build stamp %#lx size %#lx, %d data section(s)%s",
             (unsigned long)g_tl_pe_stamp, (unsigned long)g_tl_pe_size, g_tl_nranges,
             tlc_known_build(g_tl_pe_stamp, g_tl_pe_size) ? ", a checked build"
                                                          : ", not a checked build: the canvas list will be searched for");
}

#endif /* TIMELAPSE_WIN_H */
