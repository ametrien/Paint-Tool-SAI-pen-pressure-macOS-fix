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

// MARK: - the tab: periods, pages, and what each page shows
//
// Everything below reads the days already counted; nothing here changes what
// is counted or how it is saved. The tab has one switch for the page (Days,
// Hours, Weekdays, Calendar) and one for the period (Week, Month, Year, All
// time; a year stepper on the Calendar page).

enum StatsPeriod: Int, CaseIterable {
    case week, month, year, all
    var title: String { ["Week", "Month", "Year", "All time"][rawValue] }
}

enum StatsPage: Int, CaseIterable {
    case days, hours, weekdays, calendar
    var title: String { ["Days", "Hours", "Weekdays", "Calendar"][rawValue] }
}

/// A stretch of days, both ends included, each given as its start of day.
/// `from` after `to` is an empty range.
struct DayRange: Equatable {
    var from: Date
    var to: Date
}

/// What the tiles show for a range.
struct PeriodSummary: Equatable {
    /// Strokes, pen time and drawing time added up.
    var total = DayStats()
    var daysDrawn = 0
    /// Days of the range that could have been counted: on or after the first
    /// day anything was counted. "20 of 30" must not count days from before
    /// the app was counting at all.
    var daysCounted = 0
    /// Days in the range, counted or not.
    var daysInRange = 0
    /// Drawing time on an average day you drew.
    var averageDay: Double { daysDrawn > 0 ? total.activeSeconds / Double(daysDrawn) : 0 }
}

/// One bar of the Days page: a day, a week or a month.
struct StatsBucket: Equatable {
    var start: Date
    var seconds: Double = 0
    var strokes = 0
    var daysDrawn = 0
    /// False while the whole bucket is from before counting began: drawn as
    /// nothing at all, not as "nothing drawn".
    var counted = false
}

enum StatsBucketSize: Equatable, CaseIterable { case day, week, month }

/// The Hours page: drawing time in each hour of an average drawing day.
struct HourProfile: Equatable {
    /// Seconds, 24 values: the average over the days drawn that have hours.
    var average: [Double] = Array(repeating: 0, count: 24)
    /// Days drawn that have hours (days saved before hours were counted have none).
    var days = 0
    /// For each hour, on how many of those days anything was drawn in it.
    var daysWithHour: [Int] = Array(repeating: 0, count: 24)
}

/// The Weekdays page: one weekday's average.
struct WeekdayAverage: Equatable {
    /// 1 is Sunday, as Calendar counts.
    var weekday: Int
    /// Drawing time on an average such day, days off included.
    var average: Double
    var drew: Int
    var count: Int
}

extension StatsCore {

    static func startOfDay(_ d: Date, _ calendar: Calendar) -> Date { calendar.startOfDay(for: d) }

    /// The first day anything was counted, or nil before that.
    static func firstCountedKey(_ days: [String: DayStats]) -> String? { days.keys.min() }

    /// The range a period covers, ending today. Week, Month and Year are the
    /// last 7, 30 and 365 days, so a period never starts out half empty on the
    /// 1st of a month. All time starts at the first counted day.
    static func range(_ p: StatsPeriod, today: Date, days: [String: DayStats],
                      calendar: Calendar = .current) -> DayRange {
        let t = calendar.startOfDay(for: today)
        func back(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: t) ?? t }
        switch p {
        case .week: return DayRange(from: back(6), to: t)
        case .month: return DayRange(from: back(29), to: t)
        case .year: return DayRange(from: back(364), to: t)
        case .all:
            let first = firstCountedKey(days).flatMap { date(ofKey: $0, calendar: calendar) } ?? t
            return DayRange(from: min(first, t), to: t)
        }
    }

    /// One calendar year, cut off at today.
    static func yearRange(_ year: Int, today: Date, calendar: Calendar = .current) -> DayRange {
        let t = calendar.startOfDay(for: today)
        let from = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? t
        let end = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? t
        return DayRange(from: from, to: min(end, t))
    }

    /// Every day of the range, oldest first, zeros included.
    ///
    /// Stepped with the calendar, never by adding 86400 seconds: a day with a
    /// daylight saving change is 23 or 25 hours long, and seconds would land a
    /// day twice or skip one.
    static func daysIn(_ r: DayRange, _ days: [String: DayStats],
                       calendar: Calendar = .current) -> [(key: String, date: Date, stats: DayStats)] {
        var out: [(key: String, date: Date, stats: DayStats)] = []
        let from = calendar.startOfDay(for: r.from), to = calendar.startOfDay(for: r.to)
        var i = 0
        while i < 100_000, let d = calendar.date(byAdding: .day, value: i, to: from), d <= to {
            let k = dayKey(d, calendar: calendar)
            out.append((k, d, days[k] ?? DayStats()))
            i += 1
        }
        return out
    }

    static func summary(_ days: [String: DayStats], range r: DayRange,
                        calendar: Calendar = .current) -> PeriodSummary {
        var s = PeriodSummary()
        let first = firstCountedKey(days)
        for x in daysIn(r, days, calendar: calendar) {
            s.daysInRange += 1
            if let f = first, x.key >= f { s.daysCounted += 1 }
            guard x.stats.strokes > 0 else { continue }
            s.daysDrawn += 1
            s.total.strokes += x.stats.strokes
            s.total.penSeconds += x.stats.penSeconds
            s.total.activeSeconds += x.stats.activeSeconds
        }
        return s
    }

    /// The longest run of days in a row with at least one stroke, ever.
    /// The earliest such run when two are as long.
    static func longestStreak(_ days: [String: DayStats],
                              calendar: Calendar = .current) -> (length: Int, from: String, to: String)? {
        let keys = days.filter { $0.value.strokes > 0 }.keys.sorted()
        guard let firstKey = keys.first else { return nil }
        var best = (length: 1, from: firstKey, to: firstKey)
        var run = (length: 1, from: firstKey)
        for (prev, cur) in zip(keys, keys.dropFirst()) {
            let next = date(ofKey: prev, calendar: calendar)
                .flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
                .map { dayKey($0, calendar: calendar) }
            run = next == cur ? (run.length + 1, run.from) : (1, cur)
            if run.length > best.length { best = (run.length, run.from, cur) }
        }
        return best
    }

    // MARK: Days page

    /// Up to a month is one bar per day, up to a year one per week, longer one
    /// per month: past about 60 bars they are too thin to point at.
    static func bucketSize(_ r: DayRange, calendar: Calendar = .current) -> StatsBucketSize {
        let n = (calendar.dateComponents([.day], from: calendar.startOfDay(for: r.from),
                                         to: calendar.startOfDay(for: r.to)).day ?? 0) + 1
        return n <= 31 ? .day : n <= 366 ? .week : .month
    }

    /// Where a day's bar starts: the day, its week (from the calendar's first
    /// weekday) or its month.
    static func bucketStart(_ d: Date, _ size: StatsBucketSize, calendar: Calendar = .current) -> Date {
        switch size {
        case .day: return calendar.startOfDay(for: d)
        case .week: return calendar.dateInterval(of: .weekOfYear, for: d)?.start ?? calendar.startOfDay(for: d)
        case .month: return calendar.dateInterval(of: .month, for: d)?.start ?? calendar.startOfDay(for: d)
        }
    }

    /// The bars, oldest first. The first and last bar may cover only part of a
    /// week or month: the range decides which days count, not the bar.
    static func buckets(_ days: [String: DayStats], range r: DayRange, size: StatsBucketSize,
                        calendar: Calendar = .current) -> [StatsBucket] {
        let first = firstCountedKey(days)
        var out: [StatsBucket] = []
        for x in daysIn(r, days, calendar: calendar) {
            let start = bucketStart(x.date, size, calendar: calendar)
            if out.last?.start != start { out.append(StatsBucket(start: start)) }
            if let f = first, x.key >= f { out[out.count - 1].counted = true }
            guard x.stats.strokes > 0 else { continue }
            out[out.count - 1].seconds += x.stats.activeSeconds
            out[out.count - 1].strokes += x.stats.strokes
            out[out.count - 1].daysDrawn += 1
        }
        return out
    }

    /// The average bar, over bars with something drawn: for days, the same
    /// number as the Average day tile.
    static func averageBar(_ b: [StatsBucket]) -> Double? {
        let drawn = b.filter { $0.seconds > 0 }
        return drawn.isEmpty ? nil : drawn.reduce(0) { $0 + $1.seconds } / Double(drawn.count)
    }

    // MARK: the value axis

    /// The top of a time axis and the step between its lines: round minutes or
    /// hours, at most `lines` steps, the top at or above the tallest bar.
    ///
    /// THE TRAP this replaces: the old chart scaled every bar to the tallest
    /// one and drew no axis, so the tallest bar always filled the chart. One
    /// minute and five hours looked the same, and nothing said which it was.
    static func timeAxis(max top: Double, lines: Int = 6) -> (top: Double, step: Double) {
        let steps: [Double] = [60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 18000, 36000,
                               72000, 180_000, 360_000, 720_000, 1_800_000, 3_600_000]
        guard top > 0, top.isFinite else { return (3600, 1800) }   // nothing yet: 0 to 1 h
        for s in steps where (top / s).rounded(.up) <= Double(lines) {
            return ((top / s).rounded(.up) * s, s)
        }
        let s = steps.last!
        return ((top / s).rounded(.up) * s, s)
    }

    /// An axis line's label: "0", "45 min", "2 h", "1 h 30".
    static func axisLabel(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        if m <= 0 { return "0" }
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h " + String(format: "%02d", m % 60)
    }

    // MARK: Hours page

    /// Drawing time in each hour on an average day you drew. The axis for this
    /// is fixed at 0 to 60 min: an hour holds no more than that, so a bar's
    /// height means the same on every period.
    static func hourProfile(_ days: [String: DayStats], range r: DayRange,
                            calendar: Calendar = .current) -> HourProfile {
        var p = HourProfile()
        var sum = Array(repeating: 0.0, count: 24)
        for x in daysIn(r, days, calendar: calendar) {
            guard x.stats.strokes > 0, let h = x.stats.hourly, h.count == 24 else { continue }
            p.days += 1
            for i in 0..<24 {
                sum[i] += h[i]
                if h[i] > 0 { p.daysWithHour[i] += 1 }
            }
        }
        if p.days > 0 { p.average = sum.map { $0 / Double(p.days) } }
        return p
    }

    // MARK: Weekdays page

    /// Each weekday's average, starting at the calendar's first weekday.
    /// Days off are included (a Saturday with nothing drawn pulls Saturdays
    /// down), and days from before counting began are not.
    static func weekdayAverages(_ days: [String: DayStats], range r: DayRange,
                                calendar: Calendar = .current) -> [WeekdayAverage] {
        let first = firstCountedKey(days)
        var total = Array(repeating: 0.0, count: 8), count = Array(repeating: 0, count: 8),
            drew = Array(repeating: 0, count: 8)
        for x in daysIn(r, days, calendar: calendar) {
            guard let f = first, x.key >= f else { continue }
            let w = calendar.component(.weekday, from: x.date)
            count[w] += 1
            if x.stats.strokes > 0 { drew[w] += 1; total[w] += x.stats.activeSeconds }
        }
        return (0..<7).map { i in
            let w = (calendar.firstWeekday - 1 + i) % 7 + 1
            return WeekdayAverage(weekday: w, average: count[w] > 0 ? total[w] / Double(count[w]) : 0,
                                  drew: drew[w], count: count[w])
        }
    }

    // MARK: Calendar page

    /// The colour step of a day: 0 nothing, then under 30 min, 30 min to 1 h,
    /// 1 to 2 h, 2 h or more. Fixed steps, so a colour means the same in
    /// every year and the legend can say it in minutes.
    static func calendarLevel(_ seconds: Double) -> Int {
        if seconds <= 0 { return 0 }
        if seconds < 1800 { return 1 }
        if seconds < 3600 { return 2 }
        if seconds < 7200 { return 3 }
        return 4
    }
    static let calendarLegend = ["None", "Under 30 min", "30 min to 1 h", "1 to 2 h", "2 h or more"]

    /// The years the arrows can reach: from the first year anything was
    /// counted to this year. Just this year before anything is counted.
    static func calendarYears(_ days: [String: DayStats], today: Date,
                              calendar: Calendar = .current) -> ClosedRange<Int> {
        let now = calendar.component(.year, from: today)
        let first = firstCountedKey(days).flatMap { Int($0.prefix(4)) } ?? now
        return min(first, now)...now
    }

    /// The year one arrow press away, kept within the years there are: back to
    /// the first counted year, forward again up to this year.
    static func stepYear(_ year: Int, _ by: Int, _ years: ClosedRange<Int>) -> Int {
        min(max(year + by, years.lowerBound), years.upperBound)
    }

    /// Drawing time in one month of one year.
    static func monthTotal(_ days: [String: DayStats], year: Int, month: Int) -> Double {
        let prefix = String(format: "%04d-%02d-", year, month)
        return days.reduce(0) { $0 + ($1.key.hasPrefix(prefix) ? $1.value.activeSeconds : 0) }
    }

    /// Where a day sits in its month's grid: the week row (0 to 5) and the
    /// column, counted from the calendar's first weekday.
    static func gridPosition(year: Int, month: Int, day: Int, calendar: Calendar = .current) -> (row: Int, col: Int) {
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return (0, 0) }
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let i = lead + day - 1
        return (i / 7, i % 7)
    }

    /// A month total for the calendar's month headings: "22 h", "35 min", or
    /// nothing for a month with nothing drawn.
    static func monthTotalText(_ s: Double) -> String {
        if s < 60 { return "" }
        if s < 3600 { return "\(Int(s / 60)) min" }
        return "\(Int((s / 3600).rounded())) h"
    }

    /// The facts about one day under the calendar, without its date.
    /// Parts not counted on that day (older days have no sessions or times)
    /// are left out, never shown as 0.
    static func dayFacts(_ d: DayStats?) -> [String] {
        guard let d, d.strokes > 0 else { return ["Nothing drawn"] }
        var out = [duration(d.activeSeconds), strokes(d.strokes)]
        if d.sessions > 0 { out.append(d.sessions == 1 ? "1 session" : "\(d.sessions) sessions") }
        if let a = d.firstAt, let b = d.lastAt { out.append("\(clock(a)) to \(clock(b))") }
        return out
    }

    /// A time of day from seconds after midnight: "21:05".
    static func clock(_ s: Double) -> String {
        let m = max(0, Int(s / 60))
        return String(format: "%02d:%02d", min(m / 60, 23), m % 60)
    }

    // MARK: tiles

    /// A tile's big number split into number and unit runs, so the digits can
    /// be large and the units small: "2 h 11 min" is 2, " h ", 11, " min".
    /// From 20 hours on the minutes are left out: a tile is 117 pt wide.
    static func cardTimeParts(_ s: Double) -> [(text: String, unit: Bool)] {
        if s <= 0 { return [("0", false), (" min", true)] }
        if s < 60 { return [("<1", false), (" min", true)] }
        let m = Int(s / 60)
        if m < 60 { return [("\(m)", false), (" min", true)] }
        let h = m / 60
        if h >= 20 || m % 60 == 0 { return [("\(h)", false), (" h", true)] }
        return [("\(h)", false), (" h ", true), ("\(m % 60)", false), (" min", true)]
    }

    /// The Days drawn tile: "20 of 30", only the days since counting began.
    static func daysDrawnParts(_ s: PeriodSummary) -> [(text: String, unit: Bool)] {
        s.daysCounted > 0 ? [("\(s.daysDrawn)", false), (" of \(s.daysCounted)", true)] : [("0", false)]
    }

    /// The lines under the tiles' numbers fit in 16 characters: a tile is
    /// 117 pt wide, and a longer line ends in "…".
    static let tileDetailMax = 16

    static func daysDrawnDetail(_ s: PeriodSummary) -> String {
        guard s.daysCounted > 0 else { return "Nothing yet" }
        return "\(Int((Double(s.daysDrawn) * 100 / Double(s.daysCounted)).rounded()))% of days"
    }

    /// Under the Average day tile. "0 min when you drew" would say you drew.
    static func averageDetail(_ s: PeriodSummary) -> String {
        s.daysDrawn > 0 ? "when you drew" : "No days drawn"
    }

    static func streakParts(_ n: Int) -> [(text: String, unit: Bool)] {
        [("\(n)", false), (n == 1 ? " day" : " days", true)]
    }

    /// The line under the streak: the best run so far, unless this is it.
    static func streakDetail(streak: Int, best: Int?) -> String {
        guard let best, best > 0 else { return "None yet" }
        if streak > 0 && streak >= best { return "Your longest yet" }
        return best == 1 ? "Best: 1 day" : "Best: \(best) days"
    }

    // MARK: words on the charts

    /// English names, indexed by Calendar's weekday minus one (0 is Sunday).
    /// Fixed rather than taken from the Mac's language: they sit inside
    /// English sentences ("on an average Saturday").
    static let weekdayShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let weekdayOne = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let weekdayMany = weekdayOne.map { $0 + "s" }

    static let notCountedText = "Not counted"
    static let nothingInPeriod = "Nothing drawn in this period"

    /// The Days page heading and the grey note after it.
    static func daysHeading(_ size: StatsBucketSize) -> (title: String, note: String) {
        switch size {
        case .day: return ("Drawing time per day", "One bar is one day")
        case .week: return ("Drawing time per week", "One bar is one week")
        case .month: return ("Drawing time per month", "One bar is one month")
        }
    }

    /// The label on the average line: "average day 2 h 11".
    ///
    /// THE TRAP: this used axisLabel as it is, which rounds to the nearest
    /// minute, while the Average day tile cuts the seconds off. The same
    /// 6 min 40 s read "6 min" on the tile and "average day 7 min" on the line
    /// right under it. Whole minutes here, cut off as the tile does, and
    /// "<1 min" under a minute, as the tile says.
    static func averageLabel(_ size: StatsBucketSize, _ s: Double) -> String {
        let what = size == .day ? "day" : size == .week ? "week" : "month"
        let time = s > 0 && s < 60 ? "<1 min" : axisLabel((s / 60).rounded(.down) * 60)
        return "average \(what) \(time)"
    }

    /// A time that starts a sentence: "45 min", "Under a minute".
    static func averageText(_ s: Double) -> String { s < 60 ? "Under a minute" : duration(s) }

    /// A day bar's tooltip, under its date.
    /// Two lines under the date: time and strokes, then sessions and when.
    static func dayTip(_ d: DayStats?, counted: Bool, heading: String) -> String {
        guard counted else { return heading + "\nBefore counting began" }
        let f = dayFacts(d)
        let rest = f.dropFirst(2).joined(separator: ", ")
        return heading + "\n" + f.prefix(2).joined(separator: ", ") + (rest.isEmpty ? "" : "\n" + rest)
    }

    /// A week or month bar's tooltip, under its dates.
    static func bucketTip(_ b: StatsBucket, heading: String) -> String {
        guard b.counted else { return heading + "\nBefore counting began" }
        guard b.daysDrawn > 0 else { return heading + "\nNothing drawn" }
        return heading + "\n\(duration(b.seconds)), \(strokes(b.strokes))\nDrawn on \(b.daysDrawn) "
            + (b.daysDrawn == 1 ? "day" : "days")
    }

    /// An hour bar's tooltip: "21:00 to 22:00", the average, on how many days.
    static func hourTip(_ p: HourProfile, hour i: Int) -> String {
        let h = max(0, min(23, i))
        let span = String(format: "%02d:00 to %02d:00", h, (h + 1) % 24)
        guard p.days > 0 else { return span + "\nNo hours counted in this period" }
        guard p.average[h] > 0 else { return span + "\nNothing drawn in this hour" }
        return span + "\n\(averageText(p.average[h])) on an average day\n"
            + "You drew in this hour on \(p.daysWithHour[h]) of \(p.days) " + (p.days == 1 ? "day" : "days")
    }

    /// Under the Hours chart: what the bars are an average of.
    static func hoursNote(_ p: HourProfile) -> String? {
        guard p.days > 0 else { return nil }
        return (p.days == 1 ? "The one day you drew." : "Average of the \(p.days) days you drew.")
            + " An hour holds 60 min at most."
    }

    /// Said across an empty Hours chart. Days saved before hours were counted
    /// are drawn days with no hours: that is not "nothing drawn".
    static func hoursEmpty(_ p: HourProfile, daysDrawn: Int) -> String? {
        p.days > 0 ? nil : daysDrawn > 0 ? "Hours were not counted yet on these days" : nothingInPeriod
    }

    /// A weekday bar's tooltip: "Saturdays", the average, on how many of them.
    static func weekdayTip(_ w: WeekdayAverage) -> String {
        let i = max(0, min(6, w.weekday - 1))
        let one = weekdayOne[i], many = weekdayMany[i]
        guard w.count > 0 else { return many + "\nNone counted in this period" }
        let line = w.drew == 0 ? "Nothing drawn" : "\(averageText(w.average)) on an average \(one)"
        return "\(many)\n\(line)\nYou drew on \(w.drew) of \(w.count) " + (w.count == 1 ? one : many)
    }
}
