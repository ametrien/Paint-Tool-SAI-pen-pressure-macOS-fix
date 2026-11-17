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

        // === the tab: periods, pages and what each page shows ==============
        var mon = utc; mon.firstWeekday = 2          // weeks from Monday
        func key(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%04d-%02d-%02d", y, m, d) }
        func drawn(_ secs: Double, strokes n: Int = 10, hourly: [Double]? = nil) -> DayStats {
            DayStats(strokes: n, penSeconds: secs / 2, activeSeconds: secs, hourly: hourly)
        }
        let nov16 = day(2026, 11, 16)                // a Monday

        // --- periods ----------------------------------------------------------
        let hist2: [String: DayStats] = [key(2026, 6, 1): drawn(600), key(2026, 11, 10): drawn(3600),
                                         key(2026, 11, 16): drawn(1200)]
        let wk = StatsCore.range(.week, today: nov16, days: hist2, calendar: utc)
        expect(StatsCore.dayKey(wk.from, calendar: utc) == "2026-11-10" && StatsCore.dayKey(wk.to, calendar: utc) == "2026-11-16",
               "period: Week is the last 7 days, today included")
        expect(StatsCore.daysIn(StatsCore.range(.month, today: nov16, days: hist2, calendar: utc), hist2, calendar: utc).count == 30,
               "period: Month is the last 30 days")
        expect(StatsCore.daysIn(StatsCore.range(.year, today: nov16, days: hist2, calendar: utc), hist2, calendar: utc).count == 365,
               "period: Year is the last 365 days")
        let allR = StatsCore.range(.all, today: nov16, days: hist2, calendar: utc)
        expect(StatsCore.dayKey(allR.from, calendar: utc) == "2026-06-01", "period: All time starts at the first counted day")
        let emptyAll = StatsCore.range(.all, today: nov16, days: [:], calendar: utc)
        expect(StatsCore.daysIn(emptyAll, [:], calendar: utc).count == 1, "period: All time before anything is counted is just today")
        for p in StatsPeriod.allCases { expect(!p.title.contains("\u{2014}") && !p.title.contains("\u{2013}"), "text: no dash in period \"\(p.title)\"") }
        for p in StatsPage.allCases { expect(!p.title.contains("\u{2014}") && !p.title.contains("\u{2013}"), "text: no dash in page \"\(p.title)\"") }

        // TRAP: stepping days by adding 86400 seconds. A day with a daylight
        // saving change is 23 or 25 hours, so a range across one would show a
        // day twice or skip one. Berlin changes clocks on 29 March and 25 October.
        var berlin = Calendar(identifier: .gregorian); berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        for (m, d) in [(3, 29), (10, 25)] {
            let mid = berlin.date(from: DateComponents(year: 2026, month: m, day: d, hour: 12))!
            let r = DayRange(from: berlin.date(byAdding: .day, value: -3, to: berlin.startOfDay(for: mid))!,
                             to: berlin.date(byAdding: .day, value: 3, to: berlin.startOfDay(for: mid))!)
            let keys = StatsCore.daysIn(r, [:], calendar: berlin).map { $0.key }
            expect(keys.count == 7 && Set(keys).count == 7 && keys[3] == key(2026, m, d),
                   "days: a range across the clock change on \(d).\(m) has each day once, none skipped")
        }
        let yr26 = StatsCore.yearRange(2026, today: nov16, calendar: utc)
        expect(StatsCore.daysIn(yr26, [:], calendar: utc).count == 320, "year: this year ends today (1 Jan to 16 Nov is 320 days)")
        expect(StatsCore.daysIn(StatsCore.yearRange(2024, today: nov16, calendar: utc), [:], calendar: utc).count == 366,
               "year: a past leap year is all 366 days")
        expect(StatsCore.daysIn(StatsCore.yearRange(2027, today: nov16, calendar: utc), [:], calendar: utc).isEmpty,
               "year: a year still to come has no days")

        // --- tiles --------------------------------------------------------------
        // TRAP: "Days drawn 2 of 30" when counting began a week ago reads as
        // 28 days skipped. Days from before the first counted day are not
        // days off; they were never counted.
        let fresh: [String: DayStats] = [key(2026, 11, 10): drawn(3600), key(2026, 11, 12): drawn(1800)]
        let sm = StatsCore.summary(fresh, range: StatsCore.range(.month, today: nov16, days: fresh, calendar: utc), calendar: utc)
        expect(sm.daysInRange == 30 && sm.daysCounted == 7 && sm.daysDrawn == 2,
               "tiles: of a 30-day month, only the 7 days since counting began are counted")
        expect(sm.total.activeSeconds == 5400 && sm.total.strokes == 20 && sm.averageDay == 2700,
               "tiles: total and the average of the days drawn")
        let nothing = StatsCore.summary([:], range: wk, calendar: utc)
        expect(nothing.daysCounted == 0 && nothing.daysDrawn == 0 && nothing.averageDay == 0,
               "tiles: before anything is counted, nothing is counted and the average is 0, not NaN")

        let parts = { (s: Double) in StatsCore.cardTimeParts(s).map { $0.text }.joined() }
        expect(parts(0) == "0 min" && parts(20) == "<1 min" && parts(59 * 60 + 59) == "59 min", "tile: minutes")
        expect(parts(7860) == "2 h 11 min" && parts(7200) == "2 h", "tile: hours and minutes")
        expect(parts(43 * 3600 + 25 * 60) == "43 h", "tile: from 20 h on, hours only (a tile is narrow)")
        expect(StatsCore.cardTimeParts(7860).map { $0.unit } == [false, true, false, true], "tile: numbers big, units small")

        // --- longest streak --------------------------------------------------
        var runs: [String: DayStats] = [:]
        for d in 3...5 { runs[key(2026, 8, d)] = drawn(60) }                       // 3 days
        for d in 29...31 { runs[key(2026, 10, d)] = drawn(60) }                    // 31 Oct ...
        for d in 1...2 { runs[key(2026, 11, d)] = drawn(60) }                      // ... runs into 1 and 2 Nov
        runs[key(2026, 11, 4)] = DayStats()                                        // a day with no strokes
        let ls = StatsCore.longestStreak(runs, calendar: utc)
        expect(ls?.length == 5 && ls?.from == "2026-10-29" && ls?.to == "2026-11-02",
               "longest streak: runs across the end of a month")
        var tie: [String: DayStats] = [:]
        for d in [1, 2, 10, 11] { tie[key(2026, 9, d)] = drawn(60) }
        expect(StatsCore.longestStreak(tie, calendar: utc)?.from == "2026-09-01", "longest streak: the earlier of two equal runs")
        expect(StatsCore.longestStreak([:], calendar: utc) == nil, "longest streak: none before anything is drawn")

        // --- Days page: bars -------------------------------------------------
        let r31 = DayRange(from: day(2026, 10, 1), to: day(2026, 10, 31))
        let r32 = DayRange(from: day(2026, 10, 1), to: day(2026, 11, 1))
        expect(StatsCore.bucketSize(r31, calendar: utc) == .day && StatsCore.bucketSize(r32, calendar: utc) == .week,
               "bars: up to 31 days a bar is a day, from 32 a week")
        expect(StatsCore.bucketSize(DayRange(from: day(2025, 11, 16), to: nov16), calendar: utc) == .week
               && StatsCore.bucketSize(DayRange(from: day(2025, 11, 15), to: nov16), calendar: utc) == .month,
               "bars: up to 366 days a bar is a week, longer a month")
        // Wed 4 Nov to Tue 10 Nov, weeks from Monday: two bars, Wed to Sun and Mon to Tue.
        let wb: [String: DayStats] = [key(2026, 11, 4): drawn(600), key(2026, 11, 8): drawn(1200), key(2026, 11, 9): drawn(300)]
        let weekR = DayRange(from: day(2026, 11, 4), to: day(2026, 11, 10))
        let weeks = StatsCore.buckets(wb, range: weekR, size: .week, calendar: mon)
        expect(weeks.count == 2 && weeks[0].seconds == 1800 && weeks[0].daysDrawn == 2 && weeks[1].seconds == 300,
               "bars: a week bar adds up its days, weeks start on the calendar's first weekday")
        expect(weeks.count == 2 && StatsCore.dayKey(weeks[1].start, calendar: mon) == "2026-11-09",
               "bars: the second week starts on Monday 9 Nov")
        let sunWeeks = StatsCore.buckets(wb, range: weekR, size: .week, calendar: utc)
        expect(sunWeeks.count == 2 && sunWeeks[0].seconds == 600 && sunWeeks[1].seconds == 1500,
               "bars: with weeks from Sunday, Sunday 8 Nov opens the second week")
        let months = StatsCore.buckets(hist2, range: allR, size: .month, calendar: utc)
        expect(months.count == 6 && months.first?.seconds == 600 && months.last?.seconds == 4800
               && months[1...4].allSatisfy { $0.seconds == 0 && $0.counted },
               "bars: month bars from June to November, empty months still counted")
        let dayBars = StatsCore.buckets(fresh, range: StatsCore.range(.month, today: nov16, days: fresh, calendar: utc),
                                        size: .day, calendar: utc)
        expect(dayBars.count == 30 && dayBars.prefix(23).allSatisfy { !$0.counted } && dayBars.suffix(7).allSatisfy { $0.counted },
               "bars: days from before counting began are marked not counted (their box says so, not Nothing drawn)")
        expect(StatsCore.averageBar(dayBars) == sm.averageDay, "bars: the average line for days is the Average day tile")
        expect(StatsCore.averageBar(StatsCore.buckets([:], range: wk, size: .day, calendar: utc)) == nil,
               "bars: no average line when nothing is drawn")

        // --- the average line says what the Average day tile says -----------
        // TRAP: the line rounded to the nearest minute, the tile cuts the
        // seconds off: 6 min 40 s was "6 min" on the tile and "average day
        // 7 min" right under it.
        expect(StatsCore.averageLabel(.day, 400) == "average day 6 min", "average line: 6 min 40 s is 6 min, as on the tile")
        expect(StatsCore.averageLabel(.day, 7199) == "average day 1 h 59", "average line: 1 h 59 min 59 s is not 2 h")
        expect(StatsCore.averageLabel(.day, 50) == "average day <1 min" && StatsCore.averageLabel(.day, 20) == "average day <1 min",
               "average line: under a minute says <1 min, as the tile does, not 0 or 1 min")
        // Every average from 1 s to 30 h, in 7 s steps: the line's minutes
        // are the tile's. The tile leaves the minutes out from 20 h on (it is
        // narrow), so there only the hours are compared.
        func minutes(_ t: String) -> Int? {
            let n = t.split(separator: " ").compactMap { Int($0) }
            if t.contains(" h") { return n.count == 2 ? n[0] * 60 + n[1] : n.first.map { $0 * 60 } }
            return n.first
        }
        var lineOK = true
        for s in stride(from: 60.0, through: 30 * 3600, by: 7) {
            let tile = StatsCore.cardTimeParts(s).map { $0.text }.joined()
            let line = String(StatsCore.averageLabel(.day, s).dropFirst("average day ".count))
            guard let tm = minutes(tile), let lm = minutes(line) else { lineOK = false; print("    unreadable at \(s): \(tile) / \(line)"); break }
            if s >= 20 * 3600 ? tm / 60 != lm / 60 : tm != lm {
                lineOK = false; print("    average line broke at \(s) s: tile \"\(tile)\", line \"\(line)\""); break
            }
        }
        expect(lineOK, "average line: for every average, the same minutes as the Average day tile")

        // --- the value axis --------------------------------------------------
        expect(StatsCore.timeAxis(max: 312 * 60) == (top: 6 * 3600, step: 3600), "axis: 5 h 12 min tops out at 6 h, a line each hour")
        expect(StatsCore.timeAxis(max: 0) == (top: 3600, step: 1800), "axis: nothing drawn shows 0 to 1 h")
        expect(StatsCore.timeAxis(max: 20) == (top: 60, step: 60), "axis: under a minute shows 0 to 1 min")
        // TRAP: the old chart had no axis and scaled to the tallest bar, so
        // the tallest bar always filled the chart whatever it was. Now the
        // top is a round number above it, and one minute never looks like
        // five hours.
        expect(StatsCore.timeAxis(max: 61 * 60).top == 75 * 60, "axis: 61 min is drawn against a 75 min top, not as a full bar")
        var axisOK = true
        for v in stride(from: 1.0, through: 400 * 3600, by: 97.0) {
            let a = StatsCore.timeAxis(max: v)
            let n = a.top / a.step
            if a.top < v || a.top - a.step >= v || n > 6 || n != n.rounded() || a.step.truncatingRemainder(dividingBy: 60) != 0 {
                axisOK = false; print("    axis broke at \(v): \(a)"); break
            }
        }
        expect(axisOK, "axis: for any tallest bar, the top is the first whole step above it, at most 6 lines, whole minutes")
        expect(StatsCore.axisLabel(0) == "0" && StatsCore.axisLabel(2700) == "45 min" && StatsCore.axisLabel(7200) == "2 h"
               && StatsCore.axisLabel(5400) == "1 h 30", "axis: labels with units")

        // --- Hours page -------------------------------------------------------
        var hA = Array(repeating: 0.0, count: 24); hA[21] = 1800; hA[22] = 600
        var hB = Array(repeating: 0.0, count: 24); hB[21] = 3600
        let hp: [String: DayStats] = [key(2026, 11, 14): drawn(2400, hourly: hA), key(2026, 11, 15): drawn(3600, hourly: hB),
                                      key(2026, 11, 13): drawn(900)]      // saved before hours were counted
        let prof = StatsCore.hourProfile(hp, range: wk, calendar: utc)
        expect(prof.days == 2 && prof.average[21] == 2700 && prof.average[22] == 300,
               "hours: the average day, over the days drawn that have hours")
        expect(prof.daysWithHour[21] == 2 && prof.daysWithHour[22] == 1 && prof.daysWithHour[3] == 0,
               "hours: on how many days each hour was used")
        expect(StatsCore.hourProfile([:], range: wk, calendar: utc).days == 0, "hours: nothing drawn, no days")

        // --- Weekdays page ---------------------------------------------------
        // Counting began Mon 2 Nov. Two Saturdays (7 and 14 Nov): one drawn for
        // an hour, one off. The Saturday average is 30 min, the day off included.
        let wd: [String: DayStats] = [key(2026, 11, 2): drawn(600), key(2026, 11, 7): drawn(3600)]
        let avgs = StatsCore.weekdayAverages(wd, range: StatsCore.range(.month, today: nov16, days: wd, calendar: mon), calendar: mon)
        expect(avgs.map { $0.weekday } == [2, 3, 4, 5, 6, 7, 1], "weekdays: in order from the calendar's first weekday")
        let sat = avgs.first { $0.weekday == 7 }!
        expect(sat.count == 2 && sat.drew == 1 && sat.average == 1800, "weekdays: a day off counts in the average")
        let monday = avgs.first { $0.weekday == 2 }!
        expect(monday.count == 3 && monday.average == 200,
               "weekdays: Mondays from before counting began are left out (2, 9 and 16 Nov count, 19 and 26 Oct do not)")
        expect(StatsCore.weekdayAverages(wd, range: wk, calendar: utc).map { $0.weekday } == [1, 2, 3, 4, 5, 6, 7],
               "weekdays: from Sunday on a Sunday-first calendar")

        // --- Calendar page --------------------------------------------------
        expect([0, 1, 1799, 1800, 3599, 3600, 7199, 7200].map(StatsCore.calendarLevel) == [0, 1, 1, 2, 2, 3, 3, 4],
               "calendar: colour steps at 30 min, 1 h and 2 h, both sides of each")
        for t in StatsCore.calendarLegend { expect(!t.contains("\u{2014}") && !t.contains("\u{2013}"), "text: no dash in legend \"\(t)\"") }
        expect(StatsCore.calendarYears([:], today: nov16, calendar: utc) == 2026...2026, "calendar: before anything is counted, only this year")
        let old: [String: DayStats] = [key(2024, 12, 30): drawn(60), key(2026, 1, 2): drawn(60)]
        let span = StatsCore.calendarYears(old, today: nov16, calendar: utc)
        expect(span == 2024...2026, "calendar: back to the first year anything was counted")
        // The arrows: back as far as the counting goes, and forward again,
        // but not past this year.
        var y = 2026
        y = StatsCore.stepYear(y, -1, span); expect(y == 2025, "years: back one")
        y = StatsCore.stepYear(y, -1, span); expect(y == 2024, "years: back to the first year")
        y = StatsCore.stepYear(y, -1, span); expect(y == 2024, "years: not before the first year")
        y = StatsCore.stepYear(y, 1, span); y = StatsCore.stepYear(y, 1, span); expect(y == 2026, "years: and forward again to this year")
        y = StatsCore.stepYear(y, 1, span); expect(y == 2026, "years: not past this year")
        // 1 Nov 2026 is a Sunday.
        expect(StatsCore.gridPosition(year: 2026, month: 11, day: 1, calendar: mon) == (row: 0, col: 6)
               && StatsCore.gridPosition(year: 2026, month: 11, day: 2, calendar: mon) == (row: 1, col: 0)
               && StatsCore.gridPosition(year: 2026, month: 11, day: 30, calendar: mon) == (row: 5, col: 0),
               "calendar: November 2026 from Monday, six rows")
        expect(StatsCore.gridPosition(year: 2026, month: 11, day: 1, calendar: utc) == (row: 0, col: 0),
               "calendar: and from Sunday it starts the first row")
        var gridOK = true
        for yy in 2024...2028 { for mm in 1...12 {
            let n = utc.range(of: .day, in: .month, for: utc.date(from: DateComponents(year: yy, month: mm, day: 1))!)!.count
            for cal in [utc, mon] where StatsCore.gridPosition(year: yy, month: mm, day: n, calendar: cal).row > 5 { gridOK = false }
        } }
        expect(gridOK, "calendar: every month of five years fits in six rows")
        // TRAP: a prefix without its trailing dash, "2026-1", would add
        // October, November and December into January.
        let mt: [String: DayStats] = [key(2026, 1, 5): drawn(600), key(2026, 11, 5): drawn(3600), key(2026, 10, 5): drawn(60)]
        expect(StatsCore.monthTotal(mt, year: 2026, month: 1) == 600 && StatsCore.monthTotal(mt, year: 2026, month: 11) == 3600,
               "calendar: January is January, not every month starting with 1")
        expect(StatsCore.monthTotalText(0) == "" && StatsCore.monthTotalText(35 * 60) == "35 min"
               && StatsCore.monthTotalText(22 * 3600 + 20 * 60) == "22 h", "calendar: month totals")
        expect(StatsCore.dayFacts(nil) == ["Nothing drawn"] && StatsCore.dayFacts(DayStats()) == ["Nothing drawn"],
               "day: a day with nothing drawn says so")
        expect(StatsCore.dayFacts(DayStats(strokes: 340, penSeconds: 1, activeSeconds: 4320)) == ["1 h 12 min", "340 strokes"],
               "day: an older day shows no sessions or times rather than zeros")
        let bestDayStats = DayStats(strokes: 7480, penSeconds: 9000, activeSeconds: 18720, sessions: 3, longestSession: 7500,
                            firstAt: 11 * 3600 + 27 * 60, lastAt: 22 * 3600 + 41 * 60)
        let facts = StatsCore.dayFacts(bestDayStats)
        expect(facts == ["5 h 12 min", StatsCore.strokes(7480), "3 sessions", "11:27 to 22:41"], "day: all its facts (the stroke count grouped as the Mac's language does)")
        for f in facts { expect(!f.contains("\u{2014}") && !f.contains("\u{2013}"), "text: no dash in \"\(f)\"") }

        // --- words on the tiles and charts ------------------------------------
        let dd = { (s: PeriodSummary) in StatsCore.daysDrawnParts(s).map { $0.text }.joined() }
        expect(dd(sm) == "2 of 7" && StatsCore.daysDrawnDetail(sm) == "29% of days",
               "tile: days drawn is out of the days counted, not the 30 of the month")
        expect(dd(nothing) == "0" && StatsCore.daysDrawnDetail(nothing) == "Nothing yet",
               "tile: before anything is counted, no \"0 of 0\" and no division by zero")
        expect(StatsCore.averageDetail(sm) == "when you drew" && StatsCore.averageDetail(nothing) == "No days drawn",
               "tile: an average of nothing does not say \"when you drew\"")
        expect(StatsCore.streakParts(1).map { $0.text }.joined() == "1 day"
               && StatsCore.streakParts(4).map { $0.text }.joined() == "4 days", "tile: streak, one day and many")
        expect(StatsCore.streakDetail(streak: 4, best: 16) == "Best: 16 days"
               && StatsCore.streakDetail(streak: 0, best: 16) == "Best: 16 days", "tile: the best run under the streak")
        expect(StatsCore.streakDetail(streak: 16, best: 16) == "Your longest yet", "tile: the streak is the best run")
        expect(StatsCore.streakDetail(streak: 0, best: nil) == "None yet", "tile: no run yet")
        // TRAP: the first version said "Nothing counted yet" and "Draw today
        // to start one", and on a fresh install both tiles ended in "…".
        let everyDay = PeriodSummary(total: DayStats(), daysDrawn: 1000, daysCounted: 1000, daysInRange: 1000)
        let details = [StatsCore.daysDrawnDetail(nothing), StatsCore.daysDrawnDetail(sm), StatsCore.daysDrawnDetail(everyDay),
                       StatsCore.averageDetail(sm), StatsCore.averageDetail(nothing),
                       StatsCore.streakDetail(streak: 0, best: nil), StatsCore.streakDetail(streak: 9, best: 9),
                       StatsCore.streakDetail(streak: 2, best: 1000), StatsCore.streakDetail(streak: 0, best: 1)]
        for t in details { expect(t.count <= StatsCore.tileDetailMax, "tile: \"\(t)\" fits under a tile") }

        expect(StatsCore.averageLabel(.day, 7860) == "average day 2 h 11"
               && StatsCore.averageLabel(.week, 2700) == "average week 45 min", "chart: the average line's label")

        // TRAP: Calendar counts weekdays from 1 (Sunday) to 7 (Saturday), the
        // names are indexed from 0. Indexing them with the weekday straight
        // calls every day by the next day's name: Mondays read "Tuesdays".
        // Saturday alone would still pass (the index is clamped at the end),
        // so the Monday, Sunday and Wednesday checks are the ones that catch it.
        expect(StatsCore.weekdayTip(sat) == "Saturdays\n30 min on an average Saturday\nYou drew on 1 of 2 Saturdays",
               "weekday tip: Saturday is Saturday, days off counted")
        expect(StatsCore.weekdayTip(monday).hasPrefix("Mondays\n") && StatsCore.weekdayTip(avgs[6]).hasPrefix("Sundays\n"),
               "weekday tip: Monday and Sunday by their own names")
        expect(StatsCore.weekdayTip(WeekdayAverage(weekday: 4, average: 0, drew: 0, count: 1))
               == "Wednesdays\nNothing drawn\nYou drew on 0 of 1 Wednesday", "weekday tip: one, with nothing drawn")
        expect(StatsCore.weekdayTip(WeekdayAverage(weekday: 4, average: 0, drew: 0, count: 0))
               == "Wednesdays\nNone counted in this period", "weekday tip: none in the period")

        expect(StatsCore.hourTip(prof, hour: 21) == "21:00 to 22:00\n45 min on an average day\nYou drew in this hour on 2 of 2 days",
               "hour tip: the average and on how many days")
        expect(StatsCore.hourTip(prof, hour: 23) == "23:00 to 00:00\nNothing drawn in this hour",
               "hour tip: the last hour ends at 00:00, not 24:00")
        expect(StatsCore.hourTip(HourProfile(), hour: 9) == "09:00 to 10:00\nNo hours counted in this period",
               "hour tip: no days with hours")
        expect(StatsCore.hoursNote(prof) == "Average of the 2 days you drew. An hour holds 60 min at most."
               && StatsCore.hoursNote(HourProfile()) == nil, "hours: what the bars are an average of")
        expect(StatsCore.hoursEmpty(prof, daysDrawn: 3) == nil
               && StatsCore.hoursEmpty(HourProfile(), daysDrawn: 3) == "Hours were not counted yet on these days"
               && StatsCore.hoursEmpty(HourProfile(), daysDrawn: 0) == StatsCore.nothingInPeriod,
               "hours: days saved before hours were counted are not \"nothing drawn\"")

        let wkBar = StatsBucket(start: day(2026, 11, 2), seconds: 5400, strokes: 900, daysDrawn: 3, counted: true)
        expect(StatsCore.bucketTip(wkBar, heading: "2 Nov to 8 Nov") == "2 Nov to 8 Nov\n1 h 30 min, 900 strokes\nDrawn on 3 days",
               "bar tip: a week")
        expect(StatsCore.bucketTip(StatsBucket(start: day(2026, 5, 1)), heading: "May").hasSuffix("\nBefore counting began")
               && StatsCore.bucketTip(StatsBucket(start: day(2026, 7, 1), counted: true), heading: "July").hasSuffix("\nNothing drawn"),
               "bar tip: before counting began is not the same as nothing drawn")
        expect(StatsCore.dayTip(DayStats(strokes: 340, penSeconds: 1, activeSeconds: 4320), counted: true, heading: "Sat")
               == "Sat\n1 h 12 min, 340 strokes", "bar tip: a day, its facts")
        expect(StatsCore.dayTip(bestDayStats, counted: true, heading: "Sat")
               == "Sat\n5 h 12 min, \(StatsCore.strokes(7480))\n3 sessions, 11:27 to 22:41",
               "bar tip: a full day on two lines, time and strokes first")
        expect(StatsCore.dayTip(nil, counted: true, heading: "Sat") == "Sat\nNothing drawn"
               && StatsCore.dayTip(nil, counted: false, heading: "Sat") == "Sat\nBefore counting began",
               "bar tip: a day off, and a day before counting began")

        var words = [StatsCore.notCountedText, StatsCore.nothingInPeriod, StatsCore.daysDrawnDetail(sm),
                     StatsCore.streakDetail(streak: 2, best: 9), StatsCore.averageLabel(.month, 90000),
                     StatsCore.hourTip(prof, hour: 21), StatsCore.hourTip(prof, hour: 23), StatsCore.hoursNote(prof)!,
                     StatsCore.weekdayTip(sat), StatsCore.bucketTip(wkBar, heading: "")]
        words += StatsBucketSize.allCases.flatMap { [StatsCore.daysHeading($0).title, StatsCore.daysHeading($0).note] }
        words += StatsCore.weekdayShort + StatsCore.weekdayMany
        for t in words { expect(!t.contains("\u{2014}") && !t.contains("\u{2013}"), "text: no dash in \"\(t)\"") }

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
