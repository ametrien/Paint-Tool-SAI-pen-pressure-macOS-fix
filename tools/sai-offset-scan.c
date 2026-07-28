/* sai-offset-scan — find SAI's canvas struct and the static pointer to it.
 *
 * DEV TOOL, not shipped. Read-only: it attaches to a running sai2.exe (under
 * Wine) and never writes a byte back. Used once per SAI build to derive the
 * offsets the timelapse reader needs, so we never copy anyone else's table.
 *
 *   clang -O2 -o sai-offset-scan tools/sai-offset-scan.c
 *   sudo ./sai-offset-scan <pid> <width> <height>
 *
 * How it works:
 *   1. Locate the sai2.exe PE image base (region backed by a file named sai2.exe).
 *   2. Scan private writable memory for two adjacent int32s == (width, height).
 *      That pair is the canvas dimensions, so each hit is a candidate canvas struct.
 *   3. Chase pointers backwards: find 8-byte values pointing at each candidate,
 *      then values pointing at those, up to MAX_DEPTH levels, stopping when a
 *      pointer lives inside the sai2.exe image — that is the static anchor, and
 *      its offset from the image base is the session_offset we want.
 *   4. Hexdump around the best candidate so the surrounding field layout
 *      (name, tile maps) can be read off directly.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <libproc.h>

#define MAX_REGIONS   4096
#define MAX_HITS      256
#define MAX_DEPTH     4
#define DUMP_BEFORE   0x40     /* bytes of context before the w/h pair */
#define DUMP_LEN      0xC00    /* enough to cover name + tile map array */

typedef struct { mach_vm_address_t base; mach_vm_size_t size; int writable; } Region;

static Region  g_regions[MAX_REGIONS];
static int     g_region_count = 0;
static mach_vm_address_t g_image_base = 0, g_image_end = 0;

static int read_mem(task_t task, mach_vm_address_t addr, void *dst, size_t len) {
    mach_vm_size_t out = 0;
    kern_return_t kr = mach_vm_read_overwrite(task, addr, len, (mach_vm_address_t)dst, &out);
    return (kr == KERN_SUCCESS && out == len);
}

/* Walk the whole VM map once, recording readable regions and spotting the
 * sai2.exe image. Wine maps the PE from the real file on disk, so the region
 * backing the module carries the .exe path — same trick the Linux path of
 * art-timelapse uses via /proc/pid/maps, just through proc_regionfilename. */
static void enumerate_regions(task_t task, pid_t pid) {
    mach_vm_address_t addr = 0;
    /* MUST live outside the loop. Declared inside, it reset to 0 every
     * iteration, so hitting a submap re-queried the same address at depth 0
     * forever — the scan hung before printing a single region. */
    natural_t depth = 0;
    unsigned long guard = 0;
    while (g_region_count < MAX_REGIONS) {
        mach_vm_size_t size = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (++guard > 200000) {                 /* belt and braces */
            fprintf(stderr, "[scan] region walk hit iteration guard\n");
            break;
        }
        if (mach_vm_region_recurse(task, &addr, &size, &depth,
                                   (vm_region_recurse_info_t)&info, &cnt) != KERN_SUCCESS)
            break;
        if (info.is_submap) { depth++; continue; }

        if (info.protection & VM_PROT_READ) {
            char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
            if (proc_regionfilename(pid, addr, path, sizeof(path)) > 0) {
                const char *slash = strrchr(path, '/');
                const char *name  = slash ? slash + 1 : path;
                /* Several unrelated mappings get attributed to sai2.exe (Wine's
                 * KUSER_SHARED_DATA page at 0x7ffe1000 among them), so taking
                 * min/max over them spanned 3 GB. Identify the PE properly:
                 * the image starts with 'MZ', and its true extent comes from
                 * SizeOfImage in the optional header. */
                if (strcasecmp(name, "sai2.exe") == 0 && !g_image_base) {
                    uint8_t mz[2] = {0};
                    if (read_mem(task, addr, mz, 2) && mz[0] == 'M' && mz[1] == 'Z') {
                        uint32_t e_lfanew = 0, size_of_image = 0;
                        if (read_mem(task, addr + 0x3c, &e_lfanew, 4) &&
                            e_lfanew < 0x1000 &&
                            read_mem(task, addr + e_lfanew + 0x50, &size_of_image, 4) &&
                            size_of_image > 0 && size_of_image < 0x10000000) {
                            g_image_base = addr;
                            g_image_end  = addr + size_of_image;
                            fprintf(stderr, "[scan] PE image at 0x%llx, SizeOfImage 0x%x\n",
                                    (unsigned long long)addr, size_of_image);
                        }
                    }
                }
            }
            g_regions[g_region_count].base     = addr;
            g_regions[g_region_count].size     = size;
            /* Private + writable is where heap objects like the canvas live;
             * the static pointer we are hunting lives in the image instead. */
            g_regions[g_region_count].writable =
                (info.protection & VM_PROT_WRITE) && (info.share_mode != SM_SHARED);
            g_region_count++;
        }
        addr += size;
    }
}

static int in_image(mach_vm_address_t a) {
    return g_image_base && a >= g_image_base && a < g_image_end;
}

/* Find every address holding the int32 pair (w,h) adjacently. */
static int find_dimension_pairs(task_t task, int32_t w, int32_t h,
                                mach_vm_address_t *hits, int max_hits) {
    int n = 0, scanned = 0;
    uint8_t *buf = malloc(1 << 20);
    if (!buf) return 0;
    for (int i = 0; i < g_region_count && n < max_hits; i++) {
        if (!g_regions[i].writable) continue;
        if ((++scanned % 50) == 0)
            fprintf(stderr, "\r[scan] region %d/%d, %d hits...", i, g_region_count, n);
        for (mach_vm_size_t off = 0; off < g_regions[i].size && n < max_hits; off += (1 << 20)) {
            size_t chunk = (size_t)((g_regions[i].size - off) < (1 << 20)
                                    ? (g_regions[i].size - off) : (1 << 20));
            if (!read_mem(task, g_regions[i].base + off, buf, chunk)) continue;
            for (size_t k = 0; k + 8 <= chunk; k += 4) {
                if (*(int32_t *)(buf + k) == w && *(int32_t *)(buf + k + 4) == h) {
                    hits[n++] = g_regions[i].base + off + k;
                    if (n >= max_hits) break;
                }
            }
        }
    }
    free(buf);
    return n;
}

/* Find every address whose 8-byte value falls in [target-slack, target]. Slack
 * lets us catch pointers to the struct BASE when we only know the address of a
 * field inside it (we don't know the field's offset yet). */
static int find_pointers_to(task_t task, mach_vm_address_t target, mach_vm_address_t slack,
                            mach_vm_address_t *hits, int max_hits, int want_image) {
    int n = 0;
    uint8_t *buf = malloc(1 << 20);
    if (!buf) return 0;
    for (int i = 0; i < g_region_count && n < max_hits; i++) {
        if (want_image) { if (!in_image(g_regions[i].base)) continue; }
        else            { if (!g_regions[i].writable)       continue; }
        for (mach_vm_size_t off = 0; off < g_regions[i].size && n < max_hits; off += (1 << 20)) {
            size_t chunk = (size_t)((g_regions[i].size - off) < (1 << 20)
                                    ? (g_regions[i].size - off) : (1 << 20));
            if (!read_mem(task, g_regions[i].base + off, buf, chunk)) continue;
            for (size_t k = 0; k + 8 <= chunk; k += 8) {
                mach_vm_address_t v = *(mach_vm_address_t *)(buf + k);
                if (v <= target && v + slack >= target) {
                    hits[n++] = g_regions[i].base + off + k;
                    if (n >= max_hits) break;
                }
            }
        }
    }
    free(buf);
    return n;
}

/* Find the canvas NAME as UTF-16LE. This is the discriminator that dimensions
 * alone can't give us: plenty of UI structs cache the canvas width/height (the
 * navigator panel among them), but only the canvas struct carries its name. */
static int find_utf16(task_t task, const char *ascii,
                      mach_vm_address_t *hits, int max_hits) {
    size_t nchars = strlen(ascii);
    size_t nbytes = nchars * 2;
    uint8_t *needle = calloc(1, nbytes);
    if (!needle) return 0;
    for (size_t i = 0; i < nchars; i++) needle[i * 2] = (uint8_t)ascii[i];

    int n = 0;
    uint8_t *buf = malloc(1 << 20);
    if (!buf) { free(needle); return 0; }
    for (int i = 0; i < g_region_count && n < max_hits; i++) {
        if (!g_regions[i].writable) continue;
        for (mach_vm_size_t off = 0; off < g_regions[i].size && n < max_hits; off += (1 << 20)) {
            size_t chunk = (size_t)((g_regions[i].size - off) < (1 << 20)
                                    ? (g_regions[i].size - off) : (1 << 20));
            if (!read_mem(task, g_regions[i].base + off, buf, chunk)) continue;
            for (size_t k = 0; k + nbytes <= chunk; k += 2) {
                if (memcmp(buf + k, needle, nbytes) == 0) {
                    hits[n++] = g_regions[i].base + off + k;
                    if (n >= max_hits) break;
                }
            }
        }
    }
    free(buf); free(needle);
    return n;
}

/* Does this address look like a SAICanvas? Cheap structural check used to prune
 * the backwards pointer walk: the list is linked through next_canvas at +0x000,
 * so a pointer to a canvas usually lives at (previous canvas + 0). Validating
 * width/height keeps us from recursing into unrelated structs. */
static int looks_like_canvas(task_t task, mach_vm_address_t base) {
    int32_t w = 0, h = 0;
    if (!read_mem(task, base + 0x28, &w, 4)) return 0;
    if (!read_mem(task, base + 0x2c, &h, 4)) return 0;
    return (w > 0 && w < 200000 && h > 0 && h < 200000);
}

/* Walk backwards from a known canvas toward the static pointer that anchors the
 * list. At each level, search the 5 MB image first (fast) before rescanning all
 * writable memory (slow). */
static void chase(task_t task, mach_vm_address_t target, int depth, int maxdepth) {
    if (depth > maxdepth) return;
    char pad[32]; memset(pad, ' ', sizeof(pad)); pad[depth * 2 < 30 ? depth * 2 : 30] = 0;

    mach_vm_address_t st[16];
    int ns = find_pointers_to(task, target, 0, st, 16, 1);      /* image only */
    for (int i = 0; i < ns; i++)
        printf("%s*** STATIC 0x%llx  =>  session_offset = 0x%llx  (depth %d)\n",
               pad, (unsigned long long)st[i],
               (unsigned long long)(st[i] - g_image_base), depth);

    if (depth == maxdepth) return;

    mach_vm_address_t heap[32];
    int nh = find_pointers_to(task, target, 0, heap, 32, 0);    /* writable */
    int followed = 0;
    for (int i = 0; i < nh && followed < 3; i++) {
        if (!looks_like_canvas(task, heap[i])) continue;        /* prune */
        printf("%s<- prev canvas 0x%llx\n", pad, (unsigned long long)heap[i]);
        followed++;
        chase(task, heap[i], depth + 1, maxdepth);
    }
    if (nh > 0 && followed == 0)
        printf("%s(%d heap pointer(s), none look like a canvas)\n", pad, nh);
}

static void hexdump(task_t task, mach_vm_address_t base, size_t len) {
    uint8_t *buf = calloc(1, len);
    if (!buf) return;
    for (size_t o = 0; o < len; o += 0x100)
        read_mem(task, base + o, buf + o, (len - o) < 0x100 ? (len - o) : 0x100);
    for (size_t o = 0; o < len; o += 16) {
        int nonzero = 0;
        for (int j = 0; j < 16; j++) if (buf[o + j]) { nonzero = 1; break; }
        if (!nonzero) continue;                      /* skip empty padding runs */
        printf("  +0x%04zx  ", o);
        for (int j = 0; j < 16; j++) printf("%02x ", buf[o + j]);
        printf(" |");
        for (int j = 0; j < 16; j++) {
            uint8_t c = buf[o + j];
            putchar((c >= 32 && c < 127) ? c : '.');
        }
        printf("|\n");
    }
    free(buf);
}

int main(int argc, char **argv) {
    /* Must allow argc == 3 so the flag modes below can dispatch; the scan mode
     * re-checks for its own extra arguments. */
    if (argc < 3) {
        fprintf(stderr,
                "usage:\n"
                "  %s <pid> <width_px> <height_px> [canvas_name]   scan for a canvas\n"
                "  %s <pid> --verify <offset>...                   walk the list at each offset\n"
                "  %s <pid> --canvases                             find all canvas-shaped objects\n",
                argv[0], argv[0], argv[0]);
        return 2;
    }
    pid_t pid = (pid_t)atoi(argv[1]);
    int32_t w = 0, h = 0;
    if (argv[2][0] != '-') {
        if (argc < 4) {
            fprintf(stderr, "scan mode needs <width_px> <height_px>\n");
            return 2;
        }
        w = atoi(argv[2]); h = atoi(argv[3]);
    }

    /* Line-buffer stdout: a redirected run is block-buffered by default, which
     * makes a slow scan look like a hang with an empty output file. */
    setvbuf(stdout, NULL, _IOLBF, 0);
    fprintf(stderr, "[scan] starting on pid %d, looking for %dx%d\n", pid, w, h);

    task_t task;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "task_for_pid(%d) failed: %s\n"
                        "Run under sudo, or grant this binary the debugger entitlement.\n",
                pid, mach_error_string(kr));
        return 1;
    }

    printf("== scanning pid %d for a %d x %d canvas ==\n\n", pid, w, h);
    /* --verify <offset>... : no scanning. Read the pointer at image_base+offset,
     * treat it as the head of the canvas list, walk next_canvas at +0x000 and
     * print each node's dimensions and name. A candidate offset is correct iff
     * this prints the canvases actually open in SAI — which is exactly what the
     * production reader will do, so a pass here validates the real code path. */
    if (argc >= 4 && strcmp(argv[2], "--verify") == 0) {
        fprintf(stderr, "[verify] locating image...\n");
        enumerate_regions(task, pid);
        if (!g_image_base) { fprintf(stderr, "no PE image found\n"); return 1; }
        printf("image base 0x%llx\n\n", (unsigned long long)g_image_base);

        for (int a = 3; a < argc; a++) {
            unsigned long long off = strtoull(argv[a], NULL, 0);
            mach_vm_address_t slot = g_image_base + off;
            mach_vm_address_t cur = 0;
            printf("== offset 0x%llx (slot 0x%llx) ==\n", off, (unsigned long long)slot);
            if (!read_mem(task, slot, &cur, 8)) { printf("  unreadable\n\n"); continue; }
            printf("  -> points at 0x%llx\n", (unsigned long long)cur);

            /* Rewind via prev_canvas (+0x008) to find the TRUE list head. A
             * static that points mid-list enumerates only the tail, which is
             * what 0x471380 did — it reached ScratchPad1 but not the canvases
             * before it. */
            mach_vm_address_t start = cur;
            for (int back = 0; back < 32; back++) {
                mach_vm_address_t prev = 0;
                if (!read_mem(task, start + 0x08, &prev, 8) || !prev || prev == start) break;
                int32_t pw = 0;
                if (!read_mem(task, prev + 0x28, &pw, 4)) break;   /* not readable => stop */
                start = prev;
            }
            if (start != cur)
                printf("  -> rewound via prev_canvas to head 0x%llx\n",
                       (unsigned long long)start);
            cur = start;

            for (int n = 0; n < 16 && cur; n++) {
                int32_t cw = 0, ch = 0;
                uint16_t nm[64] = {0};
                if (!read_mem(task, cur + 0x28, &cw, 4) ||
                    !read_mem(task, cur + 0x2c, &ch, 4)) { printf("  [%d] 0x%llx unreadable\n", n, (unsigned long long)cur); break; }
                read_mem(task, cur + 0x8f8, nm, sizeof(nm) - 2);
                char ascii[65] = {0};
                for (int k = 0; k < 64 && nm[k]; k++)
                    ascii[k] = (nm[k] >= 32 && nm[k] < 127) ? (char)nm[k] : '?';
                mach_vm_address_t nx = 0, pv = 0;
                read_mem(task, cur, &nx, 8);
                read_mem(task, cur + 0x08, &pv, 8);
                printf("  [%d] 0x%llx  %5d x %-5d  next=0x%-11llx prev=0x%-11llx name=\"%s\"\n",
                       n, (unsigned long long)cur, cw, ch,
                       (unsigned long long)nx, (unsigned long long)pv, ascii);

                /* Tile-map hunt. Tiles are 256x256, so the grid for this canvas
                 * is ceil(w/256) x ceil(h/256) — print it so the matching int32
                 * pair can be spotted by eye, and flag any qword that could be
                 * a heap pointer (the tile_maps array). */
                int tx = (cw + 255) / 256, ty = (ch + 255) / 256;
                printf("       expected tile grid: %d x %d\n", tx, ty);
                for (mach_vm_address_t o = 0x40; o < 0x1a0; o += 8) {
                    uint64_t qv = 0;
                    if (!read_mem(task, cur + o, &qv, 8)) continue;
                    if (!qv) continue;                       /* skip empty slots */
                    int32_t lo = (int32_t)(qv & 0xffffffff), hi = (int32_t)(qv >> 32);
                    const char *tag = "";
                    if (qv > 0x10000 && qv < 0x800000000000ULL) tag = "  <- pointer?";
                    if (lo == tx && hi == ty)                  tag = "  <- TILE GRID";
                    printf("       +0x%03llx = 0x%016llx  (%d, %d)%s\n",
                           (unsigned long long)o, (unsigned long long)qv, lo, hi, tag);
                }

                /* tile_maps[0] is expected to be a pointer to a pointer to a
                 * tile map (two dereferences), whose own header should carry a
                 * tree pointer plus width/height/count_x/count_y. Follow it and
                 * dump the header so the field offsets can be read off. */
                uint64_t v0 = 0, w0 = 0;
                if (read_mem(task, cur + 0x48, &v0, 8) && v0 &&
                    read_mem(task, v0, &w0, 8) && w0) {
                    printf("       tile_maps[0]: +0x048 = 0x%llx -> 0x%llx\n",
                           (unsigned long long)v0, (unsigned long long)w0);
                    for (int q = 0; q < 6; q++) {
                        uint64_t tv = 0;
                        if (!read_mem(task, w0 + q * 8, &tv, 8)) break;
                        printf("         tilemap+0x%02x = 0x%016llx  (%d, %d)\n",
                               q * 8, (unsigned long long)tv,
                               (int32_t)(tv & 0xffffffff), (int32_t)(tv >> 32));
                    }
                }
                mach_vm_address_t next = 0;
                if (!read_mem(task, cur, &next, 8)) break;
                if (next == cur) break;
                cur = next;
            }
            printf("\n");
        }
        return 0;
    }

    /* --canvases : find every canvas-shaped object by structural signature,
     * independent of the linked list. Comparing this against what --verify
     * enumerates answers "is the list complete?" without needing to know how
     * many documents are open in the UI. Doubles as the plausibility check the
     * production reader will use to reject a wrong session_offset. */
    if (argc >= 3 && strcmp(argv[2], "--canvases") == 0) {
        fprintf(stderr, "[canvases] enumerating regions...\n");
        enumerate_regions(task, pid);
        printf("image base 0x%llx\n\n== canvas-shaped objects ==\n",
               (unsigned long long)g_image_base);

        uint8_t *buf = malloc(1 << 20);
        if (!buf) return 1;
        int found = 0, scanned = 0;
        for (int i = 0; i < g_region_count; i++) {
            if (!g_regions[i].writable) continue;
            if ((++scanned % 50) == 0)
                fprintf(stderr, "\r[canvases] region %d/%d, %d found...",
                        i, g_region_count, found);
            for (mach_vm_size_t off = 0; off < g_regions[i].size; off += (1 << 20)) {
                size_t chunk = (size_t)((g_regions[i].size - off) < (1 << 20)
                                        ? (g_regions[i].size - off) : (1 << 20));
                if (!read_mem(task, g_regions[i].base + off, buf, chunk)) continue;
                /* Every canvas seen so far is page-aligned; step 0x100 anyway. */
                for (size_t k = 0; k + 0x900 <= chunk; k += 0x1000) {
                    /* Every real canvas seen so far is page-aligned. Requiring
                     * that cut ~770 mostly-garbage hits down to the real ones. */
                    mach_vm_address_t a = g_regions[i].base + off + k;
                    if (a & 0xfff) continue;
                    int32_t cw = *(int32_t *)(buf + k + 0x28);
                    int32_t ch = *(int32_t *)(buf + k + 0x2c);
                    if (cw <= 0 || cw > 200000 || ch <= 0 || ch > 200000) continue;
                    uint16_t *nm = (uint16_t *)(buf + k + 0x8f8);
                    if (nm[0] < 32 || nm[0] > 126) continue;        /* printable start */
                    char ascii[33] = {0};
                    int len = 0, ok = 1;
                    for (int c = 0; c < 32; c++) {
                        if (!nm[c]) break;
                        if (nm[c] < 32 || nm[c] > 126) { ok = 0; break; }
                        ascii[c] = (char)nm[c]; len++;
                    }
                    if (!ok || len < 3) continue;                   /* real names */
                    printf("  0x%-11llx %5d x %-5d \"%s\"\n", (unsigned long long)a,
                           cw, ch, ascii);
                    /* Dump every link-shaped field in the header. The document
                     * chain is whichever pair actually threads the user
                     * canvases — +0x000/+0x008 demonstrably does not. */
                    for (int q = 0; q < 8; q++)
                        printf("        +0x%03x = 0x%llx\n", q * 8,
                               (unsigned long long)*(uint64_t *)(buf + k + q * 8));
                    found++;
                }
            }
        }
        free(buf);
        fprintf(stderr, "\n");
        printf("\ntotal: %d\n", found);
        return 0;
    }

    fprintf(stderr, "[scan] enumerating memory regions...\n");
    enumerate_regions(task, pid);
    fprintf(stderr, "[scan] found %d regions\n", g_region_count);
    printf("regions: %d\n", g_region_count);
    if (g_image_base)
        printf("sai2.exe image: 0x%llx .. 0x%llx  (%llu KB)\n\n",
               (unsigned long long)g_image_base, (unsigned long long)g_image_end,
               (unsigned long long)(g_image_end - g_image_base) / 1024);
    else
        printf("WARNING: sai2.exe image not found — static offset cannot be computed.\n"
               "         (This is the key thing to report back.)\n\n");

    /* Correlate name hits against dimension hits: the canvas struct is the one
     * object that has BOTH, and the distance between them IS the field layout. */
    if (argc >= 5) {
        const char *cname = argv[4];
        mach_vm_address_t nhits_a[64];
        int nn = find_utf16(task, cname, nhits_a, 64);
        printf("\n== name \"%s\" (UTF-16LE): %d hits ==\n", cname, nn);

        mach_vm_address_t dims[MAX_HITS];
        int nd = find_dimension_pairs(task, w, h, dims, MAX_HITS);
        /* Confirmed layout for the 2026.07.x builds: name at +0x8f8, width at
         * +0x028, height at +0x02c. If a name hit implies a struct base whose
         * dimensions actually match, that IS the canvas — no guessing. */
        for (int i = 0; i < nn; i++) {
            printf("  name @ 0x%llx\n", (unsigned long long)nhits_a[i]);
            for (int j = 0; j < nd; j++) {
                long long delta = (long long)nhits_a[i] - (long long)dims[j];
                if (delta > 0 && delta < 0x4000)
                    printf("      dims @ 0x%llx   name is +0x%llx after dims\n",
                           (unsigned long long)dims[j], (unsigned long long)delta);
            }
            if (nhits_a[i] < 0x8f8) continue;
            mach_vm_address_t base = nhits_a[i] - 0x8f8;
            int32_t cw = 0, ch = 0;
            if (read_mem(task, base + 0x28, &cw, 4) &&
                read_mem(task, base + 0x2c, &ch, 4) && cw == w && ch == h) {
                printf("      >>> CONFIRMED CANVAS at 0x%llx"
                       " (name +0x8f8, dims +0x28 both check out)\n",
                       (unsigned long long)base);
                fprintf(stderr, "[scan] chasing list pointers from canvas 0x%llx (slow)\n",
                        (unsigned long long)base);
                printf("      --- walking the canvas list backwards ---\n");
                chase(task, base, 0, 4);
            }
        }
        printf("\n");
    }

    mach_vm_address_t hits[MAX_HITS];
    int nhits = find_dimension_pairs(task, w, h, hits, MAX_HITS);
    printf("candidate canvases (adjacent int32 %d,%d): %d\n\n", w, h, nhits);
    if (nhits == 0) {
        printf("No hits. Either the canvas is a different size than given, or SAI\n"
               "stores dimensions non-adjacently in this build.\n");
        return 0;
    }

    /* Each candidate costs a full re-scan per pointer level, so cap the count —
     * beyond a handful the extra candidates are almost always duplicates of the
     * same struct seen through different mappings. */
    int examine = nhits < 4 ? nhits : 4;
    for (int i = 0; i < examine; i++) {
        fprintf(stderr, "\n[scan] chasing pointers for candidate %d/%d (slow)...\n",
                i + 1, examine);
        printf("---- candidate %d: dimensions at 0x%llx ----\n",
               i, (unsigned long long)hits[i]);

        /* The canvas struct starts somewhere at or before the w/h field; look for
         * pointers landing anywhere in the 0x400 bytes before it. */
        mach_vm_address_t l1[32];
        int n1 = find_pointers_to(task, hits[i], 0x400, l1, 32, 0);
        printf("  level-1 pointers into this struct: %d\n", n1);

        for (int a = 0; a < n1 && a < 4; a++) {
            mach_vm_address_t stat[8];
            int ns = find_pointers_to(task, l1[a], 0x400, stat, 8, 1);
            for (int s = 0; s < ns; s++) {
                printf("  *** STATIC ANCHOR: 0x%llx  =>  session_offset = 0x%llx\n",
                       (unsigned long long)stat[s],
                       (unsigned long long)(stat[s] - g_image_base));
            }
            /* Also check whether the level-1 slot is itself static. */
            if (in_image(l1[a]))
                printf("  *** STATIC (direct): 0x%llx  =>  session_offset = 0x%llx\n",
                       (unsigned long long)l1[a],
                       (unsigned long long)(l1[a] - g_image_base));
        }
        printf("\n");
    }

    printf("---- hexdump around candidate 0 (struct field layout) ----\n");
    mach_vm_address_t dump_base = hits[0] - DUMP_BEFORE;
    printf("(dump starts 0x%x bytes before the w/h pair, at 0x%llx)\n",
           DUMP_BEFORE, (unsigned long long)dump_base);
    hexdump(task, dump_base, DUMP_LEN);

    return 0;
}
