// StatsTests.swift: drawing stats (StatsCore): strokes, time, pauses, days,
// the stats file, streaks and the text the tab and menu show.

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

/// A fixed calendar, so the tests do not depend on the Mac's time zone.
var utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
func day(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }

@main
struct StatsTests {
    static func main() {
        print("StatsCore tests:")

        // --- one stroke ----------------------------------------------------
        var t = StrokeTally()
        t.penDown(at: 100)
        expect(t.isDown, "tally: pen down opens a stroke")
        expect(t.penUp(at: 102.5, day: "2026-11-15"), "tally: pen up closes it")
        var d = t.days["2026-11-15"]!
        expect(d.strokes == 1 && d.penSeconds == 2.5 && d.activeSeconds == 2.5,
               "tally: one stroke of 2.5 s is 2.5 s of pen and of drawing")

        // --- a second pen down while down is the same stroke ---------------
        // TRAP: send() reports every sample, so penDown arrives many times per
        // stroke in practice if the caller ever stops filtering. Restarting the
        // clock each time would shrink every stroke to its last sample.
        t.penDown(at: 200); t.penDown(at: 201)
        t.penUp(at: 203, day: "2026-11-15")
        d = t.days["2026-11-15"]!
        expect(d.strokes == 2 && d.penSeconds == 5.5, "tally: a repeated pen down does not restart the stroke")

        // --- pen up without a stroke ---------------------------------------
        expect(!t.penUp(at: 300, day: "2026-11-15") && t.days["2026-11-15"]!.strokes == 2,
               "tally: a pen up with no stroke counts nothing")

        // --- pauses --------------------------------------------------------
        var p = StrokeTally()
        p.penDown(at: 0);  p.penUp(at: 1, day: "d")     // 1 s
        p.penDown(at: 11); p.penUp(at: 12, day: "d")    // 10 s pause, counted
        p.penDown(at: 12 + StatsCore.idleGap + 1); p.penUp(at: 12 + StatsCore.idleGap + 2, day: "d")   // a break
        expect(p.days["d"]!.strokes == 3 && p.days["d"]!.penSeconds == 3 && p.days["d"]!.activeSeconds == 13,
               "tally: a short pause counts as drawing, a pause over a minute does not")

        // --- clock and lost pen up guards ----------------------------------
        var g = StrokeTally()
        g.penDown(at: 50); g.penUp(at: 40, day: "d")
        expect(g.days["d"]!.penSeconds == 0, "tally: a clock going backwards books nothing")
        g.penDown(at: 0); g.penUp(at: 5 * 3600, day: "d")
        expect(g.days["d"]!.penSeconds == StatsCore.longestStroke,
               "tally: a stroke left open for hours counts as ten minutes at most")

        // --- cancel (SAI left the front mid-stroke) ------------------------
        var c = StrokeTally()
        c.penDown(at: 0); c.penUp(at: 1, day: "d")
        c.penDown(at: 2); c.cancel()
        expect(!c.isDown && c.days["d"]!.strokes == 1, "cancel: the open stroke is dropped")
        c.penDown(at: 20); c.penUp(at: 21, day: "d")
        expect(c.days["d"]!.activeSeconds == 2, "cancel: the pause around a switch away is not counted")

        // --- days ----------------------------------------------------------
        expect(StatsCore.dayKey(day(2026, 3, 7), calendar: utc) == "2026-03-07", "day key: zero padded")
        expect(StatsCore.date(ofKey: "2026-03-07", calendar: utc).map { StatsCore.dayKey($0, calendar: utc) } == "2026-03-07",
               "day key: reads back")
        expect(StatsCore.date(ofKey: "yesterday") == nil, "day key: junk is not a day")

        // --- file ----------------------------------------------------------
        let sample: [String: DayStats] = ["2026-11-14": DayStats(strokes: 340, penSeconds: 1200, activeSeconds: 2700),
                                          "2026-11-15": DayStats(strokes: 12, penSeconds: 30, activeSeconds: 95)]
        expect(StatsCore.parse(StatsCore.serialize(sample)) == sample, "file: survives saving")
        expect(StatsCore.serialize(sample).hasPrefix(StatsCore.header), "file: starts with its header")
        let messy = "# header\n2026-11-14 5 10 20\ngarbage\n2026-13-99x 1 1 1\n2026-11-15 -3 1 1\n2026-11-16 2 9 4\n"
        let read = StatsCore.parse(messy)
        expect(read.count == 2 && read["2026-11-14"]?.strokes == 5,
               "file: bad lines are skipped, good ones kept")
        expect(read["2026-11-16"]?.activeSeconds == 9, "file: drawing time is never less than pen time")
        expect(StatsCore.parse("").isEmpty, "file: an empty file is no stats, not a crash")

        // --- sessions and times of day ------------------------------------
        var ss = StrokeTally()
        ss.penDown(at: 0);    ss.penUp(at: 2, day: "2026-11-15", clock: 9 * 3600 + 2)          // 09:00
        ss.penDown(at: 32);   ss.penUp(at: 34, day: "2026-11-15", clock: 9 * 3600 + 34)        // 30 s pause
        ss.penDown(at: 334);  ss.penUp(at: 336, day: "2026-11-15", clock: 9 * 3600 + 336)      // 5 min: break, same session
        ss.penDown(at: 1336); ss.penUp(at: 1337, day: "2026-11-15", clock: 9 * 3600 + 1337)    // 16 min: new session
        let sd = ss.days["2026-11-15"]!
        expect(sd.sessions == 2, "sessions: a break over ten minutes starts a new one, a shorter one does not")
        expect(sd.longestSession == 36, "sessions: the longest is counted in drawing time (2 + 30 + 2 + 2)")
        expect(sd.firstAt == 9 * 3600 && sd.lastAt == 9 * 3600 + 1337, "times: first stroke's start, last stroke's end")
        ss.penDown(at: 1340); ss.penUp(at: 1341, day: "2026-11-16", clock: 1)
        expect(ss.days["2026-11-16"]!.sessions == 1, "sessions: a new day starts a new one")
        var sw = StrokeTally()
        sw.penDown(at: 0); sw.penUp(at: 1, day: "d")
        sw.penDown(at: 2); sw.cancel()                     // switched to a reference image
        sw.penDown(at: 40); sw.penUp(at: 41, day: "d")
        expect(sw.days["d"]!.sessions == 1, "sessions: looking at another app for a moment does not split one")

        // --- hours of the day ------------------------------------------------
        let sh = ss.days["2026-11-15"]!.hourly!
        expect(sh.count == 24 && sh[9] == 37 && sh.reduce(0, +) == sd.activeSeconds,
               "hours: each stroke's drawing time lands in the hour it ended in, and they add up to the day")
        expect(ss.days["2026-11-16"]!.hourly![0] == ss.days["2026-11-16"]!.activeSeconds,
               "hours: just after midnight is hour 0")
        expect(StatsCore.hour(of: -5) == 0 && StatsCore.hour(of: 24.5 * 3600) == 23,
               "hours: a 25-hour daylight saving day stays inside 0 to 23")
        var noClock = StrokeTally()
        noClock.penDown(at: 0); noClock.penUp(at: 1, day: "d")
        expect(noClock.days["d"]!.hourly == nil, "hours: without a time of day, nothing is guessed")

        var h1 = Array(repeating: 0.0, count: 24); h1[21] = 3000; h1[14] = 600
        var h2 = Array(repeating: 0.0, count: 24); h2[21] = 600; h2[8] = 1200
        let hd: [String: DayStats] = [
            "2026-11-15": DayStats(strokes: 1, penSeconds: 1, activeSeconds: 3600, hourly: h1),
            "2026-11-14": DayStats(strokes: 1, penSeconds: 1, activeSeconds: 1800, hourly: h2),
            "2026-10-01": DayStats(strokes: 1, penSeconds: 1, activeSeconds: 99999,
                                   hourly: Array(repeating: 9999, count: 24)),
            "2026-11-13": DayStats(strokes: 5, penSeconds: 9, activeSeconds: 9)]   // saved before hours
        let ht = StatsCore.hourTotals(hd, count: 30, today: day(2026, 11, 15), calendar: utc)
        expect(ht[21] == 3600 && ht[14] == 600 && ht[8] == 1200 && ht.reduce(0, +) == 5400,
               "hours: the last 30 days are added up; older days and days without hours are left out")
        expect(StatsCore.whenText(ht) == "Mostly evenings, around 21:00", "hours: the busiest hour names the part of the day")
        var morning = Array(repeating: 0.0, count: 24); morning[7] = 1
        var night = Array(repeating: 0.0, count: 24); night[2] = 1
        expect(StatsCore.whenText(morning) == "Mostly mornings, around 07:00"
               && StatsCore.whenText(night) == "Mostly at night, around 02:00", "hours: mornings and nights")
        expect(StatsCore.whenText(Array(repeating: 0, count: 24)) == nil, "hours: no line before anything is counted")
        expect(!(StatsCore.whenText(ht) ?? "").contains("\u{2014}"), "hours: no dash in the line")

        // --- file: the first format still reads ---------------------------
        let v1 = StatsCore.parse("# day strokes pen-seconds active-seconds\n2026-11-14 340 1200 2700\n")
        expect(v1["2026-11-14"] == DayStats(strokes: 340, penSeconds: 1200, activeSeconds: 2700),
               "file: a day saved before sessions were counted reads, with no sessions and no times")
        let full: [String: DayStats] = ["2026-11-15": DayStats(strokes: 4, penSeconds: 7, activeSeconds: 37, sessions: 2,
                                                               longestSession: 36, firstAt: 32400, lastAt: 33737)]
        expect(StatsCore.parse(StatsCore.serialize(full)) == full, "file: sessions and times survive saving")
        expect(StatsCore.parse(StatsCore.serialize(sample)) == sample, "file: unknown times stay unknown, not 00:00")
        let withHours = ["2026-11-15": hd["2026-11-15"]!]
        expect(StatsCore.parse(StatsCore.serialize(withHours)) == withHours, "file: the 24 hours survive saving")
        let v2 = StatsCore.parse("2026-11-15 4 7 37 2 36 32400 33737\n")
        expect(v2["2026-11-15"]?.sessions == 2 && v2["2026-11-15"]?.hourly == nil,
               "file: a day saved with sessions but before hours reads")
        expect(StatsCore.parse("2026-11-15 4 7 37 2 36 32400 33737 1 2 3\n").isEmpty,
               "file: a line cut off inside the hours is skipped, not half read")

        // --- CSV export ----------------------------------------------------
        let csv = StatsCore.csv(sample, calendar: utc).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        expect(csv.first == StatsCore.csvHeader, "csv: header row")
        expect(csv.count == 4 && csv[1] == "2026-11-14,Saturday,340,45.0,20.0,3.53,7.6,,,,,,,,,,,,,,,,,,,,,,,,,,,,"
               && csv[2] == "2026-11-15,Sunday,12,1.6,0.5,2.50,7.6,,,,,,,,,,,,,,,,,,,,,,,,,,,,",
               "csv: one row per day, oldest first; what an older day never counted is left empty")
        // TRAP: String(format:) without a locale follows the Mac's language, and
        // on a German or French Mac "45.0" becomes "45,0": an extra comma that
        // splits every number into two columns.
        let cols = StatsCore.csvHeader.split(separator: ",").count
        expect(csv.dropFirst().filter { !$0.isEmpty }.allSatisfy {
                   $0.split(separator: ",", omittingEmptySubsequences: false).count == cols },
               "csv: the same number of columns on every row, whatever the Mac's language")
        let fullRow = StatsCore.csv(full, calendar: utc).split(separator: "\n").map(String.init)[1]
        expect(fullRow == "2026-11-15,Sunday,4,0.6,0.1,1.75,,2,0.6,09:00,09:22,,,,,,,,,,,,,,,,,,,,,,,,",
               "csv: sessions, longest session and times of day; no rate under a minute of drawing")
        expect(StatsCore.csv([:]) == StatsCore.csvHeader + "\n", "csv: no days is just the header")
        expect(StatsCore.csvHeader.hasSuffix("Minutes 22:00,Minutes 23:00") && cols == 35,
               "csv: 24 hour columns at the end")
        let hourRow = StatsCore.csv(withHours, calendar: utc).split(separator: "\n").map(String.init)[1]
        let hcells = hourRow.split(separator: ",", omittingEmptySubsequences: false)
        expect(hcells.count == 35 && hcells[11 + 21] == "50.0" && hcells[11 + 14] == "10.0" && hcells[11] == "0.0",
               "csv: minutes in each hour, 0.0 where nothing was drawn on a day that counted hours")

        // --- summaries -----------------------------------------------------
        let today = day(2026, 11, 15)
        let hist: [String: DayStats] = ["2026-11-15": DayStats(strokes: 1, penSeconds: 1, activeSeconds: 60),
                                        "2026-11-14": DayStats(strokes: 1, penSeconds: 1, activeSeconds: 600),
                                        "2026-11-13": DayStats(strokes: 1, penSeconds: 1, activeSeconds: 60),
                                        "2026-11-01": DayStats(strokes: 9, penSeconds: 9, activeSeconds: 9000)]
        let last7 = StatsCore.lastDays(hist, count: 7, today: today, calendar: utc)
        expect(last7.count == 7 && last7.first?.key == "2026-11-09" && last7.last?.key == "2026-11-15",
               "last days: seven, oldest first, ending today")
        expect(StatsCore.total(last7.map { $0.stats }).activeSeconds == 720, "last days: the 1st is outside the week")
        expect(StatsCore.streak(hist, today: today, calendar: utc) == 3, "streak: three days in a row")
        var noToday = hist; noToday["2026-11-15"] = nil
        expect(StatsCore.streak(noToday, today: today, calendar: utc) == 2,
               "streak: an empty today does not break it yet")
        noToday["2026-11-14"] = nil
        expect(StatsCore.streak(noToday, today: today, calendar: utc) == 0,
               "streak: an empty yesterday and today does")
        expect(StatsCore.bestDay(hist)?.key == "2026-11-01", "best day: the most drawing time")
        expect(StatsCore.bestDay([:]) == nil, "best day: none before anything is counted")

        // --- text ----------------------------------------------------------
        expect(StatsCore.duration(0) == "nothing yet" && StatsCore.duration(20) == "under a minute",
               "text: below a minute")
        expect(StatsCore.duration(8 * 60 + 59) == "8 min", "text: minutes round down")
        expect(StatsCore.duration(3600) == "1 h" && StatsCore.duration(4320) == "1 h 12 min", "text: hours")
        expect(StatsCore.strokes(1) == "1 stroke" && StatsCore.strokes(2) == "2 strokes", "text: stroke plural")
        expect(StatsCore.menuLine(DayStats()) == nil, "menu: no line on a day with nothing drawn")
        expect(StatsCore.menuLine(DayStats(strokes: 340, penSeconds: 1, activeSeconds: 4320)) == "Today: 1 h 12 min, 340 strokes",
               "menu: today's line")
        for s in [StatsCore.duration(4320), StatsCore.menuLine(DayStats(strokes: 1, penSeconds: 1, activeSeconds: 1))!] {
            expect(!s.contains("\u{2014}") && !s.contains("\u{2013}"), "text: no dash in \"\(s)\"")
        }

        // --- which app counts ----------------------------------------------
        expect(StatsCore.isSAIFront(bundleId: "org.winehq.wine", name: "wine64-preloader", path: nil, isSelf: false),
               "front: Wine counts")
        // TRAP: this app is called "SAI Pen Pressure", so the wake code's
        // "contains sai" test matches it. Drawing on the Test pen pad would
        // otherwise be counted as drawing in SAI.
        expect(!StatsCore.isSAIFront(bundleId: "com.example.sai-pen-pressure", name: "SAI Pen Pressure", path: nil, isSelf: true),
               "front: this app does not count, though its name says SAI")
        expect(!StatsCore.isSAIFront(bundleId: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app", isSelf: false),
               "front: other apps do not count")

        // --- the counter: only strokes begun with SAI in front ---------------
        let at = { (day: "d", clock: Optional(100.0)) }
        var k = StatsCounter()
        expect(!k.note(pressure: 500, at: 0, now: at) && !k.note(pressure: 0, at: 1, now: at) && k.days.isEmpty,
               "gate: a stroke in another app counts nothing")
        k.setSAIFront(true)
        _ = k.note(pressure: 300, at: 10, now: at)
        _ = k.note(pressure: 800, at: 10.5, now: at)             // still down: no change
        expect(k.note(pressure: 0, at: 12, now: at) && k.days["d"]?.strokes == 1 && k.days["d"]?.penSeconds == 2,
               "gate: a stroke in SAI counts once, however many samples it has")
        expect(!k.note(pressure: 0, at: 13, now: at) && k.days["d"]?.strokes == 1, "gate: hover samples count nothing")
        // TRAP: leaving SAI mid-stroke. The pen up arrives while another app is
        // in front; counting it would book a stroke nobody drew in SAI.
        _ = k.note(pressure: 400, at: 20, now: at)
        k.setSAIFront(false)
        expect(!k.note(pressure: 0, at: 25, now: at) && k.days["d"]?.strokes == 1,
               "gate: switching away mid-stroke drops that stroke")
        // TRAP: the mirror image. The pen goes down in another app, SAI comes
        // forward, the pen is still down. Starting the clock there would count
        // the tail of a stroke made somewhere else.
        var m = StatsCounter()
        _ = m.note(pressure: 400, at: 0, now: at)
        m.setSAIFront(true)
        _ = m.note(pressure: 600, at: 1, now: at)
        expect(!m.note(pressure: 0, at: 2, now: at) && m.days.isEmpty,
               "gate: a pen already down when SAI comes forward is not a stroke")
        _ = m.note(pressure: 400, at: 3, now: at)
        expect(m.note(pressure: 0, at: 4, now: at) && m.days["d"]?.strokes == 1,
               "gate: and the next stroke, begun in SAI, is")
        var asked = 0
        var q = StatsCounter(); q.setSAIFront(true)
        for i in 0..<1000 { _ = q.note(pressure: i == 0 ? 0 : 500, at: Double(i)) { asked += 1; return ("d", nil) } }
        expect(asked == 0, "gate: the date is never asked for while the pen stays down")

        // --- the file on disk -------------------------------------------------
        let dir = NSTemporaryDirectory() + "stats-tests-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/drawing-stats.txt"
        func asides() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.contains(".damaged-") }
        }

        let none = StatsFile.load(path: path)
        expect(none.days.isEmpty && none.setAside == nil && asides().isEmpty, "disk: no file is no stats, and nothing is set aside")

        var live = StatsCounter(days: none.days); live.setSAIFront(true)
        _ = live.note(pressure: 9, at: 0, now: { ("2026-11-15", 75600) })
        _ = live.note(pressure: 0, at: 3, now: { ("2026-11-15", 75603) })
        expect(StatsFile.save(live.days, path: path), "disk: saving works")
        let back = StatsFile.load(path: path)
        expect(back.days == live.days && back.setAside == nil,
               "disk: what was counted comes back after a restart, hours and all")
        var again = StatsCounter(days: back.days); again.setSAIFront(true)
        _ = again.note(pressure: 9, at: 0, now: { ("2026-11-15", 75700) })
        _ = again.note(pressure: 0, at: 1, now: { ("2026-11-15", 75701) })
        expect(again.days["2026-11-15"]?.strokes == 2, "disk: counting carries on from the loaded day")

        // TRAP: the next save writes memory over the file. One unreadable line
        // would be gone for good, so the file is copied aside first.
        let good = StatsCore.serialize(live.days)
        try? (good + "2026-11-14 12 notanumber 40\n").write(toFile: path, atomically: true, encoding: .utf8)
        let part = StatsFile.load(path: path)
        expect(part.days == live.days, "disk: a file with one bad line keeps its good days")
        expect(part.setAside != nil && asides().count == 1
               && (try? String(contentsOfFile: part.setAside!, encoding: .utf8))?.contains("notanumber") == true,
               "disk: and the whole file, bad line included, is copied aside before any save")
        StatsFile.save(part.days, path: path)
        expect(StatsFile.load(path: path).setAside == nil && asides().count == 1,
               "disk: once saved clean, it is not set aside again")

        // TRAP: a file that is not text at all reads as nothing. Without the
        // copy, the first stroke afterwards would save "one day" over a year.
        FileManager.default.createFile(atPath: path, contents: Data([0xFF, 0xFE, 0x00, 0xD8, 0xFF]))
        let junk = StatsFile.load(path: path, now: Date(timeIntervalSince1970: 1))
        expect(junk.days.isEmpty && junk.setAside != nil
               && FileManager.default.contents(atPath: junk.setAside!) == Data([0xFF, 0xFE, 0x00, 0xD8, 0xFF]),
               "disk: an unreadable file is copied aside untouched")
        expect(StatsCore.parseReport("# c\n\n2026-11-15 1 1 1\n").skipped == 0
               && StatsCore.parseReport("2026-11-15 1 1\nhello\n").skipped == 2,
               "disk: comments and blank lines are not damage; lines that are not days are")

        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("all StatsCore tests passed")
    }
}
