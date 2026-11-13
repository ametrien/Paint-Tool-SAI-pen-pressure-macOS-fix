// LatestFileWriter.swift — keeps a small file holding the NEWEST value it was
// given, without the caller ever waiting for the disk.
//
// It exists for wt_pressure.txt, the pen sample file the DLL falls back on. The
// file used to be written inside the event tap, once per pen sample: an atomic
// write is a new file plus a rename, measured at about 0.35 ms typically and
// 4 to 8 ms now and then, at up to 200 samples a second, and the next pen
// sample waited for every one of them. Now the tap only hands the value over,
// and a background queue does the writing.
//
// The one rule: THE LAST VALUE GIVEN IS THE ONE THE FILE ENDS UP HOLDING.
// Values that arrive while a write is in progress replace each other, so a
// slow disk skips stale samples instead of queueing them, but the newest is
// never dropped. That matters most for the final pen-up: the DLL's
// WTPacketsGet reads this file to learn whether the pen is down, and a lost
// pen-up would leave it believing in a touch that has ended.
//
// Pure Foundation, no globals, so tests/LatestFileWriterTests.swift drives it
// on its own.

import Foundation

final class LatestFileWriter {
    /// How one value reaches the disk. A parameter only so the tests can make
    /// the disk slow, or watch what was written, without touching a real one.
    typealias Store = (_ value: String, _ path: String) -> Void

    let path: String
    private let store: Store
    private let queue = DispatchQueue(label: "app.saipenpressure.latest-file", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: String?        // newest value not yet written
    private var draining = false        // a drain is queued or running

    init(path: String, store: @escaping Store = LatestFileWriter.atomicStore) {
        self.path = path
        self.store = store
    }

    /// The write the file always had: a new file, then a rename, so the DLL
    /// never reads a half-written sample.
    static let atomicStore: Store = { value, path in
        try? value.write(toFile: path, atomically: true, encoding: .ascii)
    }

    /// Hand over the newest value and return at once. Safe from any thread.
    func write(_ value: String) {
        lock.lock()
        pending = value                 // REPLACES an unwritten older value
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    /// Write until nothing newer is waiting. Runs on the queue only.
    private func drain() {
        while true {
            lock.lock()
            guard let value = pending else {
                // Cleared under the same lock write() takes: a value arriving
                // right now either was seen above, or starts a new drain.
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            store(value, path)
        }
    }

    /// Wait until everything handed over so far is on disk. For the moments
    /// that must not race a write still in flight (and for the tests).
    func flush() {
        queue.sync { self.drain() }
    }
}
