// PreFixWatchGuard.swift — the watch guard as it was in 0.3.6 and earlier: none.
//
// tests/run-tests.sh links this IN PLACE OF timelapse-encoder/WatchGuard.swift to
// build an encoder that behaves like the one that left an orphan behind on
// 2026-11-06: it never notices its app has gone, and it stops nobody. That gives
// the tests a real orphan to point the fixed encoder at, rather than a mock.
//
// Never part of a shipped build: it is not in timelapse-encoder/sources.txt.

import Foundation

enum WatchGuard {
    static func parentIsGone(startedBy parent: pid_t) -> Bool { false }
    static func stopOrphanedWatchers(of framesDir: String, log: (String) -> Void) {}
}
