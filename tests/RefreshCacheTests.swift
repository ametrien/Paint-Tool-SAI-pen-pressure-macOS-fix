// RefreshCacheTests.swift — unit tests for the two caches that keep the
// once-a-second window refresh off the pen's back (RefreshCache.swift).
//
// What is being protected:
//   1. a cached answer is never STALE: the bridge row saying "installed" from
//      memory after user.reg changed is the wrong yes #29 was made of;
//   2. an unchanged file is not read again, which is the whole saving;
//   3. the tablet question never makes the caller wait after the first time.

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String,
            file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

func put(_ text: String, _ path: String) { try! text.write(toFile: path, atomically: true, encoding: .utf8) }
func slurp(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

@main
struct RefreshCacheTests {
    static func main() {
        print("RefreshCache tests:")
        let dir = NSTemporaryDirectory() + "saipp-refreshcache-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // ================= FileStampCache =====================================
        do {
            let path = dir + "/user.reg"
            let cache = FileStampCache<String?>()
            var reads = 0
            func ask() -> String? { cache.value(for: path) { reads += 1; return slurp(path) } }

            expect(ask() == nil && reads == 1, "file: a missing file is asked about once, and the answer is nil")
            expect(ask() == nil && reads == 1, "file: and not asked about again while it stays missing")

            put("native,builtin", path)
            expect(ask() == "native,builtin" && reads == 2, "file: a file that appears is read")
            for _ in 0..<50 { _ = ask() }
            expect(reads == 2, "file: 50 more questions about an unchanged file read it 0 more times")

            // THE TRAP: same length, different content. A cache keyed on size
            // alone answers "native,builtin" for ever, which is the bridge row
            // staying green over a prefix that lost its override.
            put("builtin,native", path)
            expect(ask() == "builtin,native", "file: a rewrite of the SAME SIZE is noticed, not served from memory")

            put("x", path)
            expect(ask() == "x", "file: a rewrite of another size is noticed")

            try? FileManager.default.removeItem(atPath: path)
            expect(ask() == nil, "file: a deleted file stops being answered from memory")

            put("back", path)
            let before = reads
            _ = ask()
            cache.invalidate()
            expect(ask() == "back" && reads == before + 2, "file: invalidate() makes the next question read again")
        }

        // THE TRAP: the file changes WHILE it is being read. If the cache
        // remembered the stamp taken after reading, it would pair the old
        // content with the new stamp and never look again.
        do {
            let path = dir + "/racing.reg"
            put("old content", path)
            let cache = FileStampCache<String?>()
            let first = cache.value(for: path) {
                let seen = slurp(path)
                put("new content", path)            // wineserver rewrites it under us
                return seen
            }
            let second = cache.value(for: path) { slurp(path) }
            expect(first == "old content" && second == "new content",
                   "file: a change during the read is picked up by the next question (got \(second ?? "nil"))")
        }

        // Two paths through one cache must not answer for each other.
        do {
            let a = dir + "/a.txt", b = dir + "/b.txt"
            put("A", a); put("B", b)
            // THE TRAP: same size AND the same modification time, as two files
            // written by one copy can have. Only the path tells them apart.
            let when = Date(timeIntervalSince1970: 1_700_000_000)
            for f in [a, b] { try! FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: f) }
            let cache = FileStampCache<String?>()
            _ = cache.value(for: a) { slurp(a) }
            expect(cache.value(for: b) { slurp(b) } == "B", "file: another path is never answered with the first one's value")
        }

        // ================= BackgroundLatest ===================================
        // The test owns the clock and decides when background work runs.
        do {
            var now = Date(timeIntervalSince1970: 1_000)
            var answer = ["none"]                    // what a scan would find
            var scans = 0
            var queued: [() -> Void] = []
            /// Let the background scan finish. Says so, rather than crashing,
            /// when a broken cache never started one.
            func finishScan() {
                guard !queued.isEmpty else { expect(false, "tablets: a background scan was expected and none was started"); return }
                queued.removeFirst()()
            }
            let tablets = BackgroundLatest<[String]>(
                maxAge: 2, compute: { scans += 1; return answer },
                run: { queued.append($0) }, clock: { now })

            expect(tablets.get() == ["none"] && scans == 1 && queued.isEmpty,
                   "tablets: the first question is answered on the spot (there is nothing else to show)")
            now += 1.9
            expect(tablets.get() == ["none"] && scans == 1 && queued.isEmpty,
                   "tablets: a fresh answer is reused, with no scan")

            answer = ["Wacom Intuos BT S"]           // the tablet is switched on
            now += 0.2                               // 2.1 s old: stale
            expect(tablets.get() == ["none"] && scans == 1,
                   "tablets: a stale answer is still returned AT ONCE, with no scan on the caller's thread")
            expect(queued.count == 1, "tablets: and a scan is started in the background")
            _ = tablets.get(); _ = tablets.get()
            expect(queued.count == 1, "tablets: asking again while it runs starts no second scan")

            finishScan()                             // the background scan finishes
            expect(tablets.get() == ["Wacom Intuos BT S"] && scans == 2,
                   "tablets: once it finishes, the next question gets the new answer")

            // THE TRAP: a cache left believing a scan is still running never
            // scans again, and the Pen tab shows the first tablet for ever.
            answer = ["none"]
            now += 2.5
            _ = tablets.get()
            expect(queued.count == 1, "tablets: after one scan finished, a later stale answer starts another")
            finishScan()
            expect(tablets.get() == ["none"], "tablets: and its answer arrives too")
        }

        // With the real background queue: a slow scan must not hold the caller.
        do {
            let slow = BackgroundLatest<Int>(maxAge: 0, compute: { Thread.sleep(forTimeInterval: 0.05); return 1 })
            _ = slow.get()                           // the first one waits, by design
            let t0 = Date()
            for _ in 0..<20 { _ = slow.get() }       // done on the caller's thread: 1 second
            let took = Date().timeIntervalSince(t0)
            expect(took < 0.04, String(format: "tablets: 20 questions during a 50 ms scan took %.1f ms, not 1000", took * 1000))
        }

        if failures > 0 { print("\(failures) RefreshCache test(s) FAILED"); exit(1) }
        print("All RefreshCache tests passed.")
    }
}
