// StatsCore.swift: drawing stats (strokes and time per day), the pure half.
//
// Counted in the Mac app, not taken from the timelapse: a recording session only
// stores when it started and how many frames it has, and a frame is a stroke
// only in "Record every stroke separately" mode. The Mac app sees every pen
// down and pen up anyway, so it counts them, and stats work with recording off.
//
// Nothing here touches AppKit or the disk, so tests/StatsTests.swift can run it
// on its own. StatsUI.swift does the saving and the tab.

import Foundation

/// One day of drawing.
struct DayStats: Equatable {
    var strokes = 0
    /// Time the pen was on the surface.
    var penSeconds: Double = 0
    /// Time spent drawing: pen time plus the short pauses between strokes.
    /// A pause longer than `StatsCore.idleGap` is a break and is left out.
    var activeSeconds: Double = 0
    /// Stretches of drawing with no break over `StatsCore.sessionGap`.
    /// 0 on days saved before this was counted.
    var sessions = 0
    /// The longest of those, in drawing time.
    var longestSession: Double = 0
    /// Time of day of the first stroke's start and the last stroke's end, in
    /// seconds after midnight. nil when unknown (days saved before this).
    var firstAt: Double?
    var lastAt: Double?
    /// Drawing time in each hour of the day, 0 to 23. nil on days saved
    /// before this was counted.
    var hourly: [Double]?
}

/// Turns pen down / pen up into strokes and time. Fed only on changes, never
/// per sample, so the pen path pays one comparison per sample.
struct StrokeTally {
    private(set) var days: [String: DayStats] = [:]
    private var downAt: Double?
    private var lastUpAt: Double?
    private var lastUpDay: String?
    /// The pause before the next stroke is not drawing (SAI was not in front).
    private var skipNextGap = false
    private var sessionSoFar: Double = 0

    init(days: [String: DayStats] = [:]) { self.days = days }

    var isDown: Bool { downAt != nil }

    mutating func penDown(at t: Double) {
        if downAt == nil { downAt = t }
    }

    /// Ends the stroke and files it under `day` (the day it ended). `clock` is
    /// the time of day at pen up, in seconds after midnight, when known.
    /// Returns false when there was no stroke to end.
    @discardableResult
    mutating func penUp(at t: Double, day: String, clock: Double? = nil) -> Bool {
        guard let start = downAt else { return false }
        downAt = nil
        // A clock going backwards or a lost pen up must not book hours.
        let pen = min(max(0, t - start), StatsCore.longestStroke)
        var d = days[day] ?? DayStats()
        d.strokes += 1
        d.penSeconds += pen
        var added = pen
        let gap = lastUpAt.map { start - $0 }
        if let g = gap, g > 0, g <= StatsCore.idleGap, !skipNextGap { added += g }
        d.activeSeconds += added

        // A new session after a long break, at the first stroke of a day, or
        // the first stroke ever. Switching to another app and back is not a
        // break by itself: looking at a reference for a minute is drawing.
        let newSession = gap == nil || gap! > StatsCore.sessionGap || lastUpDay != day
        if newSession { d.sessions += 1; sessionSoFar = 0 }
        sessionSoFar += added
        d.longestSession = max(d.longestSession, sessionSoFar)

        if let c = clock {
            let began = max(0, c - pen)
            d.firstAt = min(d.firstAt ?? began, began)
            d.lastAt = max(d.lastAt ?? c, c)
            // Filed under the hour the stroke ended in. A stroke and the pause
            // before it last seconds, so one that crosses the hour puts at
            // most a minute in the wrong bar.
            var hours = d.hourly ?? Array(repeating: 0, count: 24)
            hours[StatsCore.hour(of: c)] += added
            d.hourly = hours
        }
        days[day] = d
        lastUpAt = t
        lastUpDay = day
        skipNextGap = false
        return true
    }

    /// SAI left the front (or closed) mid-stroke: drop the open stroke without
    /// counting it, and do not count the time away as drawing.
    mutating func cancel() {
        downAt = nil
        skipNextGap = true
    }
}

enum StatsCore {
    /// A pause longer than this between strokes is a break, not drawing.
    static let idleGap: Double = 60
    /// A single stroke counts for at most this long. A missed pen up (the app
    /// switched away mid-stroke) would otherwise book the whole evening.
    static let longestStroke: Double = 600
    /// A break longer than this ends a drawing session.
    static let sessionGap: Double = 600

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The hour (0 to 23) a time of day falls in, clamped: a day with a
    /// daylight saving change has 23 or 25 hours.
    static func hour(of secondsAfterMidnight: Double) -> Int {
        max(0, min(23, Int(secondsAfterMidnight / 3600)))
    }

    static func secondsAfterMidnight(_ date: Date, calendar: Calendar = .current) -> Double {
        date.timeIntervalSince(calendar.startOfDay(for: date))
    }

    static func date(ofKey key: String, calendar: Calendar = .current) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    // MARK: file

    static let header = "# day strokes pen-seconds active-seconds sessions longest-session first-at last-at [24 hourly seconds] (-1 = unknown)"

    static func serialize(_ days: [String: DayStats]) -> String {
        var out = header + "\n"
        for k in days.keys.sorted() {
            let d = days[k]!
            func i(_ x: Double?) -> Int { x.map { Int($0.rounded()) } ?? -1 }
            var line = "\(k) \(d.strokes) \(i(d.penSeconds)) \(i(d.activeSeconds)) "
                + "\(d.sessions) \(i(d.longestSession)) \(i(d.firstAt)) \(i(d.lastAt))"
            if let h = d.hourly, h.count == 24 { line += " " + h.map { String(i($0)) }.joined(separator: " ") }
            out += line + "\n"
        }
        return out
    }

    /// Unreadable lines are skipped, not fatal: one bad line must not wipe a
    /// year of stats. Reads every format there has been (four fields, eight,
    /// and eight plus 24 hours), so an update never loses what was counted.
    static func parse(_ text: String) -> [String: DayStats] { parseReport(text).days }

    /// The same, and how many lines that should have been a day were not.
    static func parseReport(_ text: String) -> (days: [String: DayStats], skipped: Int) {
        var out: [String: DayStats] = [:]
        var skipped = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ")
            if f.isEmpty || f[0].hasPrefix("#") { continue }
            skipped += 1                       // taken back below once the line reads
            guard [4, 8, 32].contains(f.count), date(ofKey: String(f[0])) != nil,
                  let s = Int(f[1]), let p = Double(f[2]), let a = Double(f[3]),
                  s >= 0, p >= 0, a >= 0 else { continue }
            var d = DayStats(strokes: s, penSeconds: p, activeSeconds: max(a, p))
            if f.count >= 8, let n = Int(f[4]), let l = Double(f[5]), let fa = Double(f[6]), let la = Double(f[7]) {
                d.sessions = max(0, n)
                d.longestSession = max(0, l)
                d.firstAt = fa >= 0 ? fa : nil
                d.lastAt = la >= 0 ? la : nil
            }
            if f.count == 32 {
                let h = f[8...].compactMap { Double($0) }
                if h.count == 24, h.allSatisfy({ $0 >= 0 }) { d.hourly = h }
            }
            out[String(f[0])] = d
            skipped -= 1
        }
        return (out, skipped)
    }

    // MARK: CSV export

    /// One row per counted day, oldest first. Plain comma-separated with a dot
    /// for decimals, whatever the Mac's language: Numbers, Google Sheets and
    /// LibreOffice all read that. Times are in minutes, which is what people
    /// add up. A value that was not counted yet on that day (older days have no
    /// sessions or times of day) is an empty cell, never a made-up 0.
    static let csvHeader = "Date,Weekday,Strokes,Drawing minutes,Pen minutes,Average stroke seconds,"
        + "Strokes per drawing minute,Sessions,Longest session minutes,First stroke,Last stroke,"
        + (0..<24).map { String(format: "Minutes %02d:00", $0) }.joined(separator: ",")

    static func csv(_ days: [String: DayStats], calendar: Calendar = .current) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        func num(_ x: Double, _ places: Int = 1) -> String { String(format: "%.\(places)f", locale: posix, x) }
        func clock(_ s: Double?) -> String {
            guard let s else { return "" }
            let m = Int(s / 60)
            return String(format: "%02d:%02d", min(m / 60, 23), m % 60)
        }
        let weekday = DateFormatter()
        weekday.locale = posix
        weekday.calendar = calendar
        weekday.timeZone = calendar.timeZone
        weekday.dateFormat = "EEEE"
        var out = csvHeader + "\n"
        for k in days.keys.sorted() {
            let d = days[k]!
            let wd = date(ofKey: k, calendar: calendar).map { weekday.string(from: $0) } ?? ""
            let avg = d.strokes > 0 ? num(d.penSeconds / Double(d.strokes), 2) : ""
            let rate = d.activeSeconds >= 60 ? num(Double(d.strokes) / (d.activeSeconds / 60)) : ""
            let sessions = d.sessions > 0 ? String(d.sessions) : ""
            let longest = d.sessions > 0 ? num(d.longestSession / 60) : ""
            let hours = d.hourly.map { $0.map { num($0 / 60) } } ?? Array(repeating: "", count: 24)
            out += ([k, wd, String(d.strokes), num(d.activeSeconds / 60), num(d.penSeconds / 60),
                     avg, rate, sessions, longest, clock(d.firstAt), clock(d.lastAt)] + hours)
                .joined(separator: ",") + "\n"
        }
        return out
    }

    // MARK: summaries

    /// The last `count` days ending with `today`, oldest first, zeros included.
    static func lastDays(_ days: [String: DayStats], count: Int, today: Date,
                         calendar: Calendar = .current) -> [(key: String, stats: DayStats)] {
        (0..<max(0, count)).reversed().compactMap { back in
            guard let d = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            let k = dayKey(d, calendar: calendar)
            return (k, days[k] ?? DayStats())
        }
    }

    /// Drawing time per hour of the day, added up over the last `count` days.
    static func hourTotals(_ days: [String: DayStats], count: Int, today: Date,
                           calendar: Calendar = .current) -> [Double] {
        var out = Array(repeating: 0.0, count: 24)
        for (_, d) in lastDays(days, count: count, today: today, calendar: calendar) {
            guard let h = d.hourly, h.count == 24 else { continue }
            for i in 0..<24 { out[i] += h[i] }
        }
        return out
    }

    /// "Mostly evenings, around 21:00", or nil before any hours are counted.
    /// The busiest hour names the part of the day.
    static func whenText(_ hours: [Double]) -> String? {
        guard hours.count == 24, let top = hours.max(), top > 0,
              let h = hours.firstIndex(of: top) else { return nil }
        let part: String
        switch h {
        case 5..<12: part = "mornings"
        case 12..<17: part = "afternoons"
        case 17..<22: part = "evenings"
        default: part = "at night"
        }
        return "Mostly \(part), around " + String(format: "%02d:00", h)
    }

    static func total(_ list: [DayStats]) -> DayStats {
        list.reduce(into: DayStats()) {
            $0.strokes += $1.strokes; $0.penSeconds += $1.penSeconds; $0.activeSeconds += $1.activeSeconds
        }
    }

    /// Days in a row with at least one stroke. A streak still counts while
    /// today is empty, as long as yesterday was not: the day is not over.
    static func streak(_ days: [String: DayStats], today: Date, calendar: Calendar = .current) -> Int {
        func drew(_ back: Int) -> Bool {
            guard let d = calendar.date(byAdding: .day, value: -back, to: today) else { return false }
            return (days[dayKey(d, calendar: calendar)]?.strokes ?? 0) > 0
        }
        var back = drew(0) ? 0 : 1
        var n = 0
        while drew(back) { n += 1; back += 1 }
        return n
    }

    /// The day with the most drawing time, or nil before anything is counted.
    static func bestDay(_ days: [String: DayStats]) -> (key: String, stats: DayStats)? {
        days.filter { $0.value.strokes > 0 }
            .max { ($0.value.activeSeconds, $1.key) < ($1.value.activeSeconds, $0.key) }
            .map { ($0.key, $0.value) }
    }

    // MARK: text

    static func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded(.down))
        if m < 1 { return s > 0 ? "under a minute" : "nothing yet" }
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    static func strokes(_ n: Int) -> String {
        if n == 1 { return "1 stroke" }
        let f = NumberFormatter(); f.numberStyle = .decimal
        return "\(f.string(from: NSNumber(value: n)) ?? String(n)) strokes"
    }

    /// The big number on a card: short, never a sentence.
    static func cardTime(_ s: Double) -> String {
        if s <= 0 { return "0 min" }
        if s < 60 { return "<1 min" }
        return duration(s)
    }

    /// The line under the streak.
    static func streakHint(streak: Int, drewToday: Bool) -> String {
        if streak == 0 { return "Draw today to start one" }
        return drewToday ? "Including today" : "Draw today to keep it"
    }

    /// The menu bar line, or nil on a day with nothing drawn yet.
    static func menuLine(_ today: DayStats) -> String? {
        guard today.strokes > 0 else { return nil }
        return "Today: \(duration(today.activeSeconds)), \(strokes(today.strokes))"
    }

    /// Whether the app in front is SAI. Same test the wake code uses (SAI runs
    /// as a Wine process), except that this app's own name contains "SAI" too,
    /// and drawing on the Test pen pad must not count.
    static func isSAIFront(bundleId: String?, name: String?, path: String?, isSelf: Bool) -> Bool {
        if isSelf { return false }
        let hay = "\(bundleId ?? "") \(name ?? "") \(path ?? "")".lowercased()
        return hay.contains("wine") || hay.contains("sai")
    }
}

/// The stroke counter as the pen path sees it: every sample's pressure goes in,
/// and only strokes made while SAI is the app in front come out counted.
struct StatsCounter {
    private(set) var tally: StrokeTally
    private(set) var saiFront = false
    /// Whether the pen is touching, whichever app is in front.
    private var touching = false

    init(days: [String: DayStats] = [:]) { tally = StrokeTally(days: days) }

    var days: [String: DayStats] { tally.days }

    /// SAI came to the front or left it. Leaving mid-stroke drops that stroke.
    mutating func setSAIFront(_ front: Bool) {
        if !front && saiFront { tally.cancel() }
        saiFront = front
    }

    /// One sample. Returns true when a stroke was just counted. `now` is only
    /// asked for at a pen up, so a sample that changes nothing costs one compare.
    ///
    /// A stroke counts only if it BEGAN with SAI in front: a pen already down
    /// when SAI comes forward is the end of something done elsewhere.
    mutating func note(pressure p: Int, at t: Double, now: () -> (day: String, clock: Double?)) -> Bool {
        let down = p > 0
        if down == touching { return false }
        touching = down
        if down {
            if saiFront { tally.penDown(at: t) }
            return false
        }
        guard tally.isDown else { return false }
        let n = now()
        return tally.penUp(at: t, day: n.day, clock: n.clock)
    }
}

/// The stats file on disk.
enum StatsFile {
    /// What was read, and where a damaged file was put, if it was.
    struct Loaded {
        var days: [String: DayStats]
        var setAside: String?
    }

    /// Read the file. No file is simply no stats yet.
    ///
    /// THE TRAP: the next save writes whatever is in memory over this file. A
    /// file that cannot be read, or that has lines which are not days, would
    /// be replaced by less than it held: a year of stats gone after one bad
    /// write. So before anything is saved, such a file is copied aside, and the
    /// days that did read are kept.
    static func load(path: String, now: Date = Date()) -> Loaded {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return Loaded(days: [:], setAside: nil) }
        let text = try? String(contentsOfFile: path, encoding: .utf8)
        let report = text.map(StatsCore.parseReport) ?? (days: [:], skipped: 1)
        guard report.skipped > 0 else { return Loaded(days: report.days, setAside: nil) }
        let stamp = Int(now.timeIntervalSince1970)
        let aside = path + ".damaged-\(stamp)"
        let copied = (try? fm.copyItem(atPath: path, toPath: aside)) != nil
        return Loaded(days: report.days, setAside: copied ? aside : nil)
    }

    @discardableResult
    static func save(_ days: [String: DayStats], path: String) -> Bool {
        (try? StatsCore.serialize(days).write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }
}
