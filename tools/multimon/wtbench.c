/*
 * wtbench.c: what do the Win32 calls the DLL makes per pen sample cost
 * under Wine? (issue #37, "does the fix make drawing feel wobbly?")
 *
 * The #37 fix added, per HOVER sample, GetCursorPos + GetWindowRect (the
 * self-check), and once a second four GetSystemMetrics calls (the screen
 * re-check). The DLL's own "lat=" only measures post -> fetch, so these were
 * never timed. This times them the way the DLL calls them: from a worker
 * thread, against a window owned by another thread that pumps messages.
 *
 * Nothing is shown: the window is message-only (HWND_MESSAGE). No SAI, no
 * input, the cursor is only read. Build and run:
 *
 *   x86_64-w64-mingw32-gcc -O2 -o wtbench.exe wtbench.c -luser32
 *   WINEPREFIX=~/SAI2-pressure WINEDEBUG=-all wine wtbench.exe
 *
 * Wine answers GetCursorPos from shared memory while the cursor is moving,
 * and asks the Mac driver (a hop to the Cocoa main thread) once it has been
 * still for 100 ms. A benchmark with nobody touching the mouse measures that
 * slower path, so its GetCursorPos numbers are an upper bound.
 */
#include <windows.h>
#include <stdio.h>

static HWND g_win;
static LARGE_INTEGER g_freq;

static double now_us(void) {
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1e6 / (double)g_freq.QuadPart;
}

typedef struct { const char *name; double sum, max; int n; } STAT;

static void add(STAT *s, double us) { s->sum += us; if (us > s->max) s->max = us; s->n++; }

static void report(const STAT *s) {
    printf("  %-34s avg %8.2f us   max %9.2f us   (n=%d)\n", s->name, s->sum / s->n, s->max, s->n);
}

static DWORD WINAPI worker(LPVOID arg) {
    (void)arg;
    STAT cur = { "GetCursorPos", 0, 0, 0 };
    STAT rect = { "GetWindowRect (other thread's)", 0, 0, 0 };
    STAT check = { "self-check total (both + PtInRect)", 0, 0, 0 };
    STAT met = { "4x GetSystemMetrics (screen check)", 0, 0, 0 };
    STAT post = { "PostMessageW (what every sample does)", 0, 0, 0 };
    POINT p; RECT r;
    for (int i = 0; i < 3000; i++) {
        double t0 = now_us();
        GetCursorPos(&p);
        double t1 = now_us();
        GetWindowRect(g_win, &r);
        double t2 = now_us();
        (void)PtInRect(&r, p);
        double t3 = now_us();
        add(&cur, t1 - t0); add(&rect, t2 - t1); add(&check, t3 - t0);
        t0 = now_us();
        GetSystemMetrics(SM_XVIRTUALSCREEN); GetSystemMetrics(SM_YVIRTUALSCREEN);
        GetSystemMetrics(SM_CXVIRTUALSCREEN); GetSystemMetrics(SM_CYVIRTUALSCREEN);
        add(&met, now_us() - t0);
        t0 = now_us();
        PostMessageW(g_win, WM_USER, 0, 0);
        add(&post, now_us() - t0);
        if ((i & 63) == 0) Sleep(1);     /* let the pump drain, like real pacing */
    }
    printf("wtbench: per-call cost under Wine (worker thread, window on another thread)\n");
    report(&cur); report(&rect); report(&check); report(&met); report(&post);
    printf("  for scale: 130 samples/s over Bluetooth = one every 7700 us\n");
    PostMessageW(g_win, WM_QUIT, 0, 0);
    return 0;
}

int main(void) {
    QueryPerformanceFrequency(&g_freq);
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"wtbench";
    RegisterClassW(&wc);
    g_win = CreateWindowExW(0, L"wtbench", L"wtbench", 0, 0, 0, 100, 100,
                            HWND_MESSAGE, NULL, wc.hInstance, NULL);
    if (!g_win) { printf("no window\n"); return 1; }
    HANDLE th = CreateThread(NULL, 0, worker, NULL, 0, NULL);
    MSG m;
    while (GetMessageW(&m, NULL, 0, 0) > 0) DispatchMessageW(&m);
    WaitForSingleObject(th, 5000);
    return 0;
}
