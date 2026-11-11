/* A stand-in for wtprobe.exe running inside Wine, for the quit tests in
 * run-tests.sh. Never Wine, never the pen port: just a process with the same
 * name that behaves like the leftover probe found on 2026-11-11.
 *
 *   fake_wtprobe <seconds> [stubborn]
 *
 * It ticks to stdout ten times a second, like the real probe, and IGNORES a
 * failed write: it does not end when the app's end of its pipe closes. That is
 * the case the app has to handle, because a probe did outlive the app, for
 * whatever reason its own pipe check did not catch. "stubborn" also ignores
 * SIGTERM, as a Windows program behind the wine loader can: only SIGKILL
 * ends it then. It gives up by itself after <seconds>, as the real one does. */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
    int secs = argc > 1 ? atoi(argv[1]) : 60;
    signal(SIGPIPE, SIG_IGN);
    if (argc > 2 && strcmp(argv[2], "stubborn") == 0) signal(SIGTERM, SIG_IGN);
    setvbuf(stdout, NULL, _IONBF, 0);
    time_t until = time(NULL) + secs;
    while (time(NULL) < until) {
        (void)printf("tick=1 p=0\n");   /* a failed write is ignored ON PURPOSE */
        usleep(100000);
    }
    return 0;
}
