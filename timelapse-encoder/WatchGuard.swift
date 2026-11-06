// WatchGuard.swift — a --watch encoder never outlives the app that started it.
//
// THE TRAP this file exists for: the frames folder is SHARED. The DLL inside SAI
// writes every session's frames into the same folder, and whichever watcher
// reads a frame first encodes it and deletes it. So a watcher that outlives its
// app does not sit idle. It takes the NEXT session's frames into a video named
// after its own, older session, and the new session's video stays empty.
//
// That is what happened on 2026-11-06. The app quit through a bare exit(0)
// (pollUntilSAICloses, when SAI closed), which skips applicationWillTerminate,
// the only place that stopped the encoder. macOS does not end a child with its
// parent: it hands it to launchd. The watcher started at 17:16 was still taking
// frames at 19:40, into "session 2026-11-06 1716.NewCanvas1.000.mp4", while the
// real session's file stayed at 0 bytes.
//
// Two rules, enforced HERE rather than in the app, because a crashed or
// force-quit app runs no code at all:
//   * a watcher lives only as long as the process that started it, and closes
//     its own video when that process goes;
//   * a watcher starting on a folder first stops any ORPHANED watcher there
//     (including ones left by 0.3.6 and earlier, which have no first rule) and
//     waits for it to close its video before reading a single frame.
//
// tests/run-tests.sh builds a second encoder with tests/PreFixWatchGuard.swift
// linked in place of this file, as a real stand-in for an orphan from 0.3.6.

import Darwin
import Foundation

enum WatchGuard {
    /// True once the process that started this watcher has gone, however it
    /// went: Quit, exit(), a crash or a force quit all look the same from here.
    ///
    /// `parent` must be getppid() taken at startup. When a parent exits, the
    /// kernel reparents its children to launchd (pid 1), so a CHANGED parent is
    /// the signal. Starting with pid 1 already means whoever started us is gone.
    static func parentIsGone(startedBy parent: pid_t) -> Bool {
        parent <= 1 || getppid() != parent
    }

    /// Stop every orphaned watcher on `framesDir` and wait for each to exit.
    ///
    /// Only ORPHANS, meaning watchers whose parent is now launchd. A watcher
    /// whose app is still running is that app's to stop, and stopping it would
    /// just make that app start another one a second later.
    ///
    /// SIGTERM, never SIGKILL: every version of the encoder answers SIGTERM by
    /// finishing its writers, and a video that never gets finishWriting() is one
    /// no player will open. The stale session keeps its frames; it just stops
    /// taking new ones. Waiting for the exit, not just signalling, is the point:
    /// until it has gone it may still be reading this folder.
    ///
    /// Call this before opening any writer, and AFTER installing the signal
    /// handlers on another queue, so this process can still be stopped while it
    /// waits (main.swift says why the order matters).
    static func stopOrphanedWatchers(of framesDir: String, log: (String) -> Void) {
        guard let mine = EncoderCore.canonicalFolder(framesDir) else { return }
        let me = getpid(), uid = getuid()
        let ownName = (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent }) ?? ""
        var stopping: [pid_t] = []
        for pid in allPids() where pid > 1 && pid != me {
            guard let info = bsdInfo(pid), info.pbi_uid == uid, info.pbi_ppid == 1,
                  let args = procArgs(pid),
                  EncoderCore.isEncoder(exe: args.exe, ownName: ownName),
                  let theirs = EncoderCore.watchedFolder(argv: args.argv),
                  EncoderCore.canonicalFolder(theirs) == mine
            else { continue }
            log("stopping an orphaned watcher on this folder (pid \(pid)); it closes its video first")
            if kill(pid, SIGTERM) == 0 { stopping.append(pid) }
        }
        guard !stopping.isEmpty else { return }

        // Finishing an open segment takes well under a second. The limit is only
        // there so a wedged process cannot keep a new session from recording.
        let deadline = Date().addingTimeInterval(20)
        while !stopping.isEmpty, Date() < deadline {
            stopping.removeAll { kill($0, 0) != 0 && errno == ESRCH }
            if !stopping.isEmpty { usleep(100_000) }
        }
        for pid in stopping { log("orphaned watcher pid \(pid) did not stop within 20s; carrying on") }
        if stopping.isEmpty { log("orphaned watcher(s) stopped") }
    }

    // --- kernel queries -----------------------------------------------------

    private static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)   // room for new arrivals
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(0, got))))
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func procArgs(_ pid: pid_t) -> (exe: String, argv: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return EncoderCore.parseProcArgs(Array(buf.prefix(size)))
    }
}
