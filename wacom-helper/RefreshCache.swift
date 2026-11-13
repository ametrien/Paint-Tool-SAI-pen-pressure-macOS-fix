// RefreshCache.swift — two small caches that keep the once-a-second window
// refresh from holding up the pen.
//
// The event tap that reads the pen runs on the main thread, and so does the
// timer that refreshes the setup window every second. Measured on 2026-11-13:
// one refresh took about 55 ms, and every pen sample that arrived meanwhile
// waited, up to 20 ms, once a second, for the whole drawing session. Three
// questions made up most of it, each asked from scratch every second though
// its answer changes a few times a day at most:
//
//   * which tablets are connected (an IOKit scan, about 20 ms, asked twice);
//   * what user.reg says about our DLL (reading and searching the whole
//     registry file, about 4 ms, asked five times per refresh);
//   * SAI's build date (reading and splitting its history.txt, about 7 ms).
//
// FileStampCache answers the two file questions from memory until the file
// changes. BackgroundLatest asks the tablet question on another thread and
// hands the window the newest answer it has.
//
// Pure Foundation, no globals, so tests/RefreshCacheTests.swift drives both.

import Foundation

/// A value worked out from a file, worked out again only when the file changes.
///
/// "Changed" is the file's modification time, size and existence. The answer
/// is therefore exactly as fresh as reading the file every time, for the price
/// of one stat. Safe from any thread.
final class FileStampCache<T> {
    struct Stamp: Equatable {
        let path: String
        let exists: Bool
        let modified: Date?
        let size: UInt64?
    }

    private let lock = NSLock()
    private var stamp: Stamp?
    private var value: T?

    static func stamp(of path: String) -> Stamp {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else {
            return Stamp(path: path, exists: false, modified: nil, size: nil)
        }
        return Stamp(path: path, exists: true,
                     modified: a[.modificationDate] as? Date,
                     size: (a[.size] as? NSNumber)?.uint64Value)
    }

    /// The value for `path`: the remembered one while the file is unchanged,
    /// otherwise whatever `compute` makes of the file as it is now.
    func value(for path: String, compute: () -> T) -> T {
        // Stamped BEFORE computing. If the file changes while it is being read,
        // the old stamp is what gets remembered, so the next call sees a
        // difference and reads again. Stamping after would pair a stale value
        // with a fresh stamp, and keep it.
        let now = FileStampCache.stamp(of: path)
        lock.lock(); defer { lock.unlock() }
        if let s = stamp, s == now, let v = value { return v }
        let v = compute()
        stamp = now; value = v
        return v
    }

    /// Forget the answer, for the caller that knows better than the file's date.
    func invalidate() {
        lock.lock(); stamp = nil; value = nil; lock.unlock()
    }
}

/// The newest answer to a slow question, asked somewhere other than the
/// caller's thread.
///
/// get() never waits, except the very first time, when there is nothing to
/// return yet. After that it returns the answer it has and, if that answer is
/// older than `maxAge`, starts asking again in the background; a later get()
/// returns the new one. So the caller is at most one ask behind, and never
/// blocked.
final class BackgroundLatest<T> {
    typealias Runner = (@escaping () -> Void) -> Void

    private let maxAge: TimeInterval
    private let compute: () -> T
    private let run: Runner
    private let clock: () -> Date
    private let lock = NSLock()
    private var value: T?
    private var askedAt: Date?
    private var asking = false

    /// `run` and `clock` are parameters for the tests, which must decide when
    /// the background work happens and what time it is.
    init(maxAge: TimeInterval, compute: @escaping () -> T,
         run: @escaping Runner = { work in DispatchQueue.global(qos: .utility).async(execute: work) },
         clock: @escaping () -> Date = { Date() }) {
        self.maxAge = maxAge; self.compute = compute; self.run = run; self.clock = clock
    }

    func get() -> T {
        lock.lock()
        guard let have = value, let at = askedAt else {
            // First time: nothing to show, so this one call waits.
            lock.unlock()
            let v = compute()
            lock.lock(); value = v; askedAt = clock(); lock.unlock()
            return v
        }
        let stale = clock().timeIntervalSince(at) >= maxAge
        let start = stale && !asking          // one ask at a time, never a pile
        if start { asking = true }
        lock.unlock()
        if start {
            run { [self] in
                let v = compute()
                lock.lock(); value = v; askedAt = clock(); asking = false; lock.unlock()
            }
        }
        return have
    }
}
