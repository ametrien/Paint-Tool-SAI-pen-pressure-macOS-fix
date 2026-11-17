// StatsViewTests.swift: the Statistics chart card, drawn for real (offscreen,
// no window), checked for text that leaves the card.
//
// The regression this guards (after the period notes were added): the note
// under the Hours chart, "Average of the 3 days you drew in the last 365 days.
// Counting began 15. Nov, so this is the same as All time.", was drawn on one
// line and ran past the card's right edge, cut off mid-word. Unit tests of the
// text could not see that: only drawing it at the card's real size can.
//
// How: StatsChartView records every string it draws and where
// (drawnText). Each page is drawn at the size the app gives the card, with
// the longest notes and dates it can get, and every string must sit inside
// the card with a little margin.

import AppKit

var failures = 0
func expect(_ cond: Bool, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

/// The card's size in the app (StatsUI.swift: rowWidth 500, height 268).
let cardSize = NSSize(width: 500, height: 268)
/// Text closer to the edge than this looks cut off even when it is not.
let margin: CGFloat = 4

let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
func day(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d))! }
func key(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%04d-%02d-%02d", y, m, d) }

/// Draws the card with this content and returns what went outside it.
func escapes(_ content: StatsChartView.Content, size: NSSize = cardSize) -> (drawn: Int, out: [String]) {
    let v = StatsChartView(frame: NSRect(origin: .zero, size: size))
    v.content = content
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return (0, ["no bitmap"]) }
    v.cacheDisplay(in: v.bounds, to: rep)
    let inside = v.bounds.insetBy(dx: margin, dy: margin)
    let out = v.drawnText.filter { !inside.contains($0.rect) }.map {
        "\"\($0.text)\" at x \(Int($0.rect.minX))...\(Int($0.rect.maxX)), y \(Int($0.rect.minY))...\(Int($0.rect.maxY))"
    }
    return (v.drawnText.count, out)
}

func check(_ name: String, _ content: StatsChartView.Content, size: NSSize = cardSize) {
    let r = escapes(content, size: size)
    expect(r.drawn > 0, "\(name): something was drawn (the check is not empty)")
    expect(r.out.isEmpty, "\(name): every text stays inside the card" + (r.out.isEmpty ? "" : "\n         " + r.out.joined(separator: "\n         ")))
}

@main
enum StatsViewTests {
    static func main() {
        _ = NSApplication.shared
        print("StatsChartView text tests (card \(Int(cardSize.width)) x \(Int(cardSize.height))):")

        // Three drawn days, counting began 15 Nov: the screenshot's case.
        var hourly = Array(repeating: 0.0, count: 24); hourly[12] = 77; hourly[13] = 17; hourly[15] = 486; hourly[22] = 33
        let days: [String: DayStats] = [
            key(2026, 11, 15): DayStats(strokes: 866, penSeconds: 258, activeSeconds: 695, hourly: hourly),
            key(2026, 11, 16): DayStats(strokes: 114, penSeconds: 30, activeSeconds: 87, hourly: hourly),
            key(2026, 11, 17): DayStats(strokes: 22, penSeconds: 16, activeSeconds: 33, hourly: hourly),
        ]
        let today = day(2026, 11, 17)

        // The dates as they may be written: short, German style, and with a year.
        for first in ["15 Nov", "15. Nov", "15. November 2025"] {
            for period in StatsPeriod.allCases {
                let range = StatsCore.range(period, today: today, days: days, calendar: utc)
                let same = period != .all
                let p = StatsCore.hourProfile(days, range: range, calendar: utc)
                let hn = StatsCore.hoursNote(p, period: period, firstText: first, sameAsAll: same)
                check("hours, \(period.title), first day \"\(first)\"", .hours(p, daysDrawn: 3, note: hn))
                let w = StatsCore.weekdayAverages(days, range: range, calendar: utc)
                let wn = StatsCore.weekdaysNote(w, period: period, firstText: first, sameAsAll: same)
                check("weekdays, \(period.title), first day \"\(first)\"", .weekdays(w, note: wn))
            }
        }

        // The other pages, for good measure: they draw labels, an average line and a
        // calendar, all of which could run out of the card the same way.
        for period in StatsPeriod.allCases {
            let range = StatsCore.range(period, today: today, days: days, calendar: utc)
            let size = StatsCore.bucketSize(range, calendar: utc)
            check("days, \(period.title)", .days(buckets: StatsCore.buckets(days, range: range, size: size, calendar: utc),
                                                 size: size, range: range, days: days))
        }
        check("calendar, 2026", .calendar(year: 2026, days: days, firstKey: StatsCore.firstCountedKey(days),
                                          todayKey: key(2026, 11, 17)))
        check("hours, nothing drawn", .hours(HourProfile(), daysDrawn: 0, note: nil))

        if failures > 0 { print("FAILED: \(failures)"); exit(1) }
        print("StatsChartView: no text leaves the card")
    }
}
