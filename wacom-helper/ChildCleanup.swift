// ChildCleanup.swift: stopping the processes this app started, before it exits.
//
// macOS does not end a child process when its parent exits. Whatever the app
// has not stopped by the time it exits is handed to launchd and keeps running.
// That has bitten twice: a --watch encoder that took later sessions' frames
// (2026-11-06, see endRecordingAndExit), and a Test pen probe that held the pen
// port so SAI read the pen from a file and missed quick strokes (2026-11-11,
// see stopStrayProbes).
//
// Foundation only, so tests/QuitTests.swift can build it with a stand-in "app"
// and check with ps that a real child is gone after each way out.

import Foundation

enum ChildCleanup {

    /// The user's processes, as `ps -x -ww -o pid=,command=` lists them.
    /// Empty if ps cannot run.
    static func psListing() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-x", "-ww", "-o", "pid=,command="]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()   // drain before waiting
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Stop every process that `find` picks out of the process list, and wait,
    /// up to `seconds`, until they are really gone. SIGTERM first, then SIGKILL
    /// halfway to the deadline for any still there. Returns the pids found, and
    /// the ones still running at the deadline (empty when all of them stopped).
    ///
    /// THE TRAP: this has to be SYNCHRONOUS when the app is about to exit.
    /// BridgeProbeStream.stop() sends SIGTERM and schedules its SIGKILL two
    /// seconds later, which is fine while the app keeps running and never
    /// happens when it exits straight after. A Wine process does not reliably
    /// pass a SIGTERM on to the Windows program behind it, so without the wait
    /// and the SIGKILL here, a probe outlives the app.
    @discardableResult
    static func stop(find: (String) -> [Int32], waitUpTo seconds: Double = 1.5)
        -> (found: [Int32], left: [Int32]) {
        // Never ourselves, whatever `find` matched: a command line that merely
        // MENTIONS a probe's path would otherwise have the app SIGTERM itself.
        let me = getpid()
        let found = find(psListing()).filter { $0 != me }
        guard !found.isEmpty else { return ([], []) }
        for pid in found { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(seconds)
        var killed = false
        while true {
            let left = Set(find(psListing())).intersection(found)
            if left.isEmpty { return (found, []) }
            if Date() >= deadline { return (found, left.sorted()) }
            if !killed, Date() >= deadline.addingTimeInterval(-seconds / 2) {
                for pid in left { kill(pid, SIGKILL) }
                killed = true
            }
            usleep(50_000)
        }
    }

    /// Kept alive for as long as the app runs: a released source stops firing.
    private static var signalSources: [DispatchSourceSignal] = []

    /// Turn SIGTERM, SIGINT and SIGHUP into `cleanExit`, run on the main queue.
    ///
    /// THE TRAP: by default these signals end the app at once, in the middle of
    /// whatever it was doing, and no cleanup runs: not applicationWillTerminate,
    /// not endRecordingAndExit. `kill <pid>`, `killall`, and the terminal the
    /// app was started from closing all arrive this way. So the Test pen probe
    /// was left running, and the recording was left half open for the next
    /// launch to write into. Replacing the default action first is what keeps
    /// the app alive long enough for the dispatch source to see the signal.
    ///
    /// A do-nothing handler rather than SIG_IGN: an IGNORED signal stays ignored
    /// in every child started afterwards, across exec, and a Wine or SAI that
    /// ignores SIGTERM does not end at logout. A HANDLED one is reset to the
    /// default in the child. (Foundation's Process resets both, as measured on
    /// 2026-11-11, but nothing guarantees every way of starting a child does.)
    static func exitCleanlyOnSignals(_ cleanExit: @escaping () -> Void) {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig) { _ in }
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler(handler: cleanExit)
            src.resume()
            signalSources.append(src)
        }
    }
}
