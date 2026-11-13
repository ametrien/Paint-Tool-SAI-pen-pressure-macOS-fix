// LatestFileWriterTests.swift — unit tests for LatestFileWriter, which writes
// the pen sample file (wt_pressure.txt) off the pen path.
//
// What is being protected, in order of how much it would hurt:
//   1. the LAST value handed over is the one the file ends up holding. The
//      final pen-up is a "last value"; lose it and the DLL's WTPacketsGet goes
//      on believing the pen is down;
//   2. write() never waits for the disk. That wait, inside the event tap, is
//      the whole reason this class exists;
//   3. a value written alone still reaches the disk, with nothing after it to
//      push it along.

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String,
            file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

/// Records what reached the "disk", in order. Thread-safe: the writer calls it
/// from its own queue while the test reads it from the main thread.
final class Disk {
    private let lock = NSLock()
    private var log: [String] = []
    var delay: TimeInterval = 0
    func store(_ value: String, _ path: String) {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock(); log.append(value); lock.unlock()
    }
    var written: [String] { lock.lock(); defer { lock.unlock() }; return log }
}

func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .ascii) }

@main
struct LatestFileWriterTests {
    static func main() {
        print("LatestFileWriter tests:")
        let dir = NSTemporaryDirectory() + "saipp-latestfile-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // --- 1. real disk: a burst ends on the last value ---------------------
        // 5000 samples as fast as they can be handed over: far faster than the
        // disk, so most are skipped. The file must still end on the last one.
        do {
            let path = dir + "/burst.txt"
            let w = LatestFileWriter(path: path)
            for i in 1...5000 { w.write("\(i) 100 200 27648 17920") }
            w.flush()
            expect(read(path) == "5000 100 200 27648 17920",
                   "real disk: after a burst of 5000 the file holds the last sample")
        }

        // --- 2. THE TRAP: the last value, every single time -------------------
        // A writer that drops a value arriving while a write is in progress
        // passes test 1 most of the time and loses a pen-up once in a while.
        // Stroke after stroke: a few samples, then the pen-up, then check.
        do {
            let path = dir + "/strokes.txt"
            let w = LatestFileWriter(path: path)
            var wrong = 0
            for stroke in 1...400 {
                for p in 1...6 { w.write("\(p * 100) \(stroke) 0 27648 17920") }
                w.write("0 \(stroke) 0 27648 17920")                 // pen-up
                w.flush()
                if read(path) != "0 \(stroke) 0 27648 17920" { wrong += 1 }
            }
            expect(wrong == 0, "real disk: 400 strokes, the file ends on the pen-up after every one (wrong: \(wrong))")
        }

        // --- 3. write() does not wait for the disk ----------------------------
        // A disk that takes 5 ms a write. Done on the caller's thread, as it was
        // before, 400 samples would take 2 seconds. Handing them over must take
        // a small fraction of that.
        do {
            let disk = Disk(); disk.delay = 0.005
            let w = LatestFileWriter(path: "unused", store: disk.store)
            let t0 = Date()
            for i in 1...400 { w.write("\(i)") }
            let handover = Date().timeIntervalSince(t0)
            expect(handover < 0.2,
                   String(format: "slow disk: handing over 400 samples took %.0f ms, not the 2000 the disk needs", handover * 1000))
            w.flush()
            let log = disk.written
            expect(log.last == "400", "slow disk: the last sample is the last thing written")
            expect(log.count < 400, "slow disk: stale samples were skipped, not queued (\(log.count) writes for 400 samples)")
            // Never backwards: an older sample written after a newer one would
            // leave the file describing the past.
            let nums = log.compactMap { Int($0) }
            expect(nums == nums.sorted() && Set(nums).count == nums.count,
                   "slow disk: what reaches the disk only ever moves forward")
        }

        // --- 4. a value on its own still lands --------------------------------
        // No flush and nothing written after it: the pen lifted and went away.
        do {
            let path = dir + "/alone.txt"
            let w = LatestFileWriter(path: path)
            // Polled, never flushed: flush() writes whatever is waiting, so it
            // would hide a writer that had stopped doing so by itself.
            func lands(_ want: String) -> Bool {
                for _ in 0..<200 {
                    if read(path) == want { return true }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                return false
            }
            w.write("0 1 2 27648 17920")
            expect(lands("0 1 2 27648 17920"), "a single value reaches the disk by itself, with nothing after it")
            // THE TRAP: a writer left believing a write is still in progress
            // takes the first value and silently ignores every later one.
            w.write("512 3 4 27648 17920")
            expect(lands("512 3 4 27648 17920"), "and so does the next one after a pause")
        }

        // --- 5. several threads at once ---------------------------------------
        // The tap is one thread, but the engine start and the keepalive timer
        // write too. Nothing may be torn, and the writer must not wedge.
        do {
            let path = dir + "/threads.txt"
            let w = LatestFileWriter(path: path)
            DispatchQueue.concurrentPerform(iterations: 8) { t in
                for i in 1...500 { w.write("\(t) \(i) 0 27648 17920") }
            }
            w.flush()
            let parts = (read(path) ?? "").split(separator: " ")
            expect(parts.count == 5 && parts[1] == "500",
                   "8 threads: the file holds one whole sample, a last one (\(read(path) ?? "nothing"))")
        }

        // --- 6. the default store is the atomic write the DLL relies on -------
        do {
            let path = dir + "/atomic.txt"
            LatestFileWriter.atomicStore("123 4 5 6 7", path)
            expect(read(path) == "123 4 5 6 7", "atomicStore writes the value as given")
            let left = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasPrefix("atomic") }
            expect(left == ["atomic.txt"], "atomicStore leaves no temporary file behind")
        }

        if failures > 0 { print("\(failures) LatestFileWriter test(s) FAILED"); exit(1) }
        print("All LatestFileWriter tests passed.")
    }
}
