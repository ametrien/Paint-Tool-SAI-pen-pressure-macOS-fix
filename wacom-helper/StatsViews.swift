// StatsViews.swift: the Statistics tab's views (tiles and the chart card).
// Apart from StatsUI.swift so tests/StatsViewTests.swift can draw the real
// chart offscreen and check that no text leaves the card.

import AppKit

// MARK: - views

/// A rounded tile: a small title, one big number, a line under it.
final class StatCardView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    var title: String {
        get { titleField.stringValue }
        set { titleField.stringValue = newValue.uppercased() }
    }
    var detail: String { get { detailField.stringValue } set { detailField.stringValue = newValue } }

    /// The big line with large numbers and small units: "2 h 11 min", "20 of 30".
    func setValue(_ parts: [(text: String, unit: Bool)]) {
        let s = NSMutableAttributedString()
        for p in parts {
            s.append(NSAttributedString(string: p.text, attributes: p.unit
                ? [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
                : [.font: NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold),
                   .foregroundColor: NSColor.labelColor]))
        }
        if !s.isEqual(to: valueField.attributedStringValue) { valueField.attributedStringValue = s }
    }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        titleField.font = .systemFont(ofSize: 10, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        valueField.lineBreakMode = .byTruncatingTail
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [titleField, valueField, detailField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.setCustomSpacing(4, after: titleField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        statsTileFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}

/// The tile colour, resolved at draw time so it follows light and dark mode.
var statsTileFill: NSColor { NSColor.labelColor.withAlphaComponent(0.06) }

/// The average line: yellow reads on dark, orange on light.
private let statsAverageColor = NSColor(name: nil) {
    $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemYellow : .systemOrange
}

/// The boxed numbers over the bar under the pointer.
private let statsCalloutFill = NSColor(name: nil) {
    $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.11, alpha: 0.96)
                                                        : NSColor(white: 1, alpha: 0.97)
}

/// The card under the tiles, one chart per page. The controller says what to
/// show; this draws it, and the exact numbers of whatever is under the
/// pointer: a box over a bar, or the day in the line under the calendar,
/// where a click keeps a day.
final class StatsChartView: NSView {
    enum Content: Equatable {
        case none
        /// The bars, what one bar stands for, the range they cover, and the
        /// counted days (a day bar's tooltip shows that day's facts).
        case days(buckets: [StatsBucket], size: StatsBucketSize, range: DayRange, days: [String: DayStats])
        /// The note under the chart names the period, so it changes on every
        /// period click even when the bars do not.
        case hours(HourProfile, daysDrawn: Int, note: String?)
        case weekdays([WeekdayAverage], note: String?)
        case calendar(year: Int, days: [String: DayStats], firstKey: String?, todayKey: String)
    }

    var content: Content = .none {
        didSet {
            // The tab refreshes every second: redraw only when something changed.
            guard content != oldValue else { return }
            if case .calendar(let year, _, _, _) = content,
               selectedKey?.hasPrefix(String(format: "%04d-", year)) != true {
                selectedKey = defaultDay(year)
            }
            if let h = hover, h >= barCount { hover = nil }
            needsDisplay = true
        }
    }

    /// The day shown under the calendar.
    private(set) var selectedKey: String?
    private var hover: Int?
    /// The calendar day under the pointer, shown in place of the chosen one.
    private var hoverKey: String?
    private var tracking: NSTrackingArea?
    private var formatters: [String: DateFormatter] = [:]
    private let cal = Calendar.current

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let pad: CGFloat = 14
    private let axisW: CGFloat = 44

    private static let titleA: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
    private static let noteA: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor]
    private static let labelA: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
    private static let boldA: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.labelColor]
    private static let smallA: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.tertiaryLabelColor]

    private func format(_ d: Date, _ template: String) -> String {
        if let f = formatters[template] { return f.string(from: d) }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        formatters[template] = f
        return f.string(from: d)
    }

    // MARK: geometry

    private var barCount: Int {
        switch content {
        case .days(let b, _, _, _): return b.count
        case .hours: return 24
        case .weekdays(let w, _): return w.count
        default: return 0
        }
    }

    /// Where the bars stand: under the heading, above the labels.
    private var plot: NSRect {
        var below: CGFloat = 26
        // Hours: the hour numbers, the parts of the day, then the note.
        // Weekdays: the day, its average, then the note.
        // The labels take 38; the note is as tall as it wraps to.
        if case .hours(_, _, let n) = content { below = 50 + (n.map { noteSize($0).height } ?? 14) }
        if case .weekdays(_, let n) = content { below = 50 + (n.map { noteSize($0).height } ?? 14) }
        let top: CGFloat = 44
        return NSRect(x: pad + axisW, y: top, width: bounds.width - 2 * pad - axisW,
                      height: bounds.height - top - below)
    }

    private func slot(_ i: Int) -> NSRect {
        let w = plot.width / CGFloat(max(1, barCount))
        return NSRect(x: plot.minX + CGFloat(i) * w, y: plot.minY, width: w, height: plot.height)
    }

    private func slotIndex(at p: NSPoint) -> Int? {
        let r = plot
        guard barCount > 0, p.x >= r.minX, p.x < r.maxX, p.y >= r.minY - 8 else { return nil }
        return min(barCount - 1, Int((p.x - r.minX) / (r.width / CGFloat(barCount))))
    }

    // MARK: the pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                                      .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if case .calendar = content {
            let k = dayKey(at: p)
            if k != hoverKey { hoverKey = k; needsDisplay = true }
            return
        }
        let i = slotIndex(at: p)
        if i != hover { hover = i; needsDisplay = true }
    }

    override func mouseExited(with e: NSEvent) {
        if hover != nil || hoverKey != nil { hover = nil; hoverKey = nil; needsDisplay = true }
    }

    /// For the PNG self-test, which has no pointer: draw bar i as if pointed at.
    func showHover(bar i: Int?) { hover = i; needsDisplay = true }

    /// What a bar's box says, line by line: what the bar is, then its numbers.
    private func tipText(_ i: Int) -> String {
        switch content {
        case .days(let bs, let size, let range, let days):
            let b = bs[i]
            switch size {
            case .day:
                return StatsCore.dayTip(days[StatsCore.dayKey(b.start)], counted: b.counted,
                                        heading: format(b.start, "EEEEMMMMd"))
            case .week:
                // The range decides where the first and last week begin and end.
                let from = max(b.start, range.from)
                let to = i + 1 < bs.count ? cal.date(byAdding: .day, value: -1, to: bs[i + 1].start) ?? range.to : range.to
                return StatsCore.bucketTip(b, heading: "\(format(from, "dMMM")) to \(format(to, "dMMM"))")
            case .month:
                return StatsCore.bucketTip(b, heading: format(b.start, "yMMMM"))
            }
        case .hours(let p, _, _): return StatsCore.hourTip(p, hour: i)
        case .weekdays(let w, _): return StatsCore.weekdayTip(w[i])
        default: return ""
        }
    }

    // MARK: drawing

    private struct Bars {
        var values: [Double]
        var counted: [Bool]
        /// Drawn in full colour: today's bar, the busiest hour or weekday.
        var strong: Int?
        var axis: (top: Double, step: Double)
        var axisText: (Double) -> String
        var average: Double?
        var averageText: String?
        /// Said across the chart when there is nothing to show.
        var empty: String?
    }

    private func bars() -> Bars? {
        switch content {
        case .days(let b, let size, _, _):
            let v = b.map { $0.seconds }
            let avg = StatsCore.averageBar(b)
            return Bars(values: v, counted: b.map { $0.counted }, strong: b.isEmpty ? nil : b.count - 1,
                        axis: StatsCore.timeAxis(max: v.max() ?? 0), axisText: StatsCore.axisLabel,
                        average: avg, averageText: avg.map { StatsCore.averageLabel(size, $0) },
                        empty: avg == nil ? StatsCore.nothingInPeriod : nil)
        case .hours(let p, let drawn, _):
            // From the tallest bar, never above 60 min: see StatsCore.hourAxis.
            let top = p.average.max() ?? 0
            return Bars(values: p.average, counted: Array(repeating: true, count: 24),
                        strong: top > 0 ? p.average.firstIndex(of: top) : nil,
                        axis: StatsCore.hourAxis(max: top), axisText: StatsCore.axisLabel,
                        average: nil, averageText: nil, empty: StatsCore.hoursEmpty(p, daysDrawn: drawn))
        case .weekdays(let w, _):
            let v = w.map { $0.average }
            let top = v.max() ?? 0
            return Bars(values: v, counted: w.map { $0.count > 0 }, strong: top > 0 ? v.firstIndex(of: top) : nil,
                        axis: StatsCore.timeAxis(max: top), axisText: StatsCore.axisLabel,
                        average: nil, averageText: nil, empty: top > 0 ? nil : StatsCore.nothingInPeriod)
        default:
            return nil
        }
    }

    private func heading() -> (title: String, note: String?) {
        switch content {
        case .none: return ("", nil)
        case .days(_, let size, _, _): return StatsCore.daysHeading(size)
        case .hours(let p, _, _): return ("By hour of day", StatsCore.whenText(p.average))
        case .weekdays: return ("By day of the week", "Average day, days off included")
        case .calendar(let y, _, _, _): return ("Every day of \(y)", "Point at a day to see it below")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawnText = []
        statsTileFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()

        let h = heading()
        let t = NSMutableAttributedString(string: h.title.uppercased(), attributes: Self.titleA)
        if let n = h.note { t.append(NSAttributedString(string: "    " + n, attributes: Self.noteA)) }
        put(t, at: NSPoint(x: pad, y: 13))

        if case .calendar = content { drawCalendar(); return }
        guard let b = bars(), !b.values.isEmpty else { return }
        drawAxis(b)
        drawBars(b)
        drawAverage(b)
        switch content {
        case .days: drawDayLabels()
        case .hours: drawHourLabels()
        case .weekdays: drawWeekdayLabels(strong: b.strong)
        default: break
        }
        if let e = b.empty {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
            let s = e as NSString
            let sz = s.size(withAttributes: a)
            put(s, at: NSPoint(x: plot.midX - sz.width / 2, y: plot.midY - sz.height / 2), a)
        }
        if let i = hover, i < b.values.count { drawCallout(i, b) }
    }

    /// The exact numbers of the bar under the pointer, in a box over it, at
    /// once. (The system tooltip this replaces waited a second or two, and
    /// moving along the bars it often never came.)
    private func drawCallout(_ i: Int, _ b: Bars) {
        let headA: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                    .foregroundColor: NSColor.labelColor]
        let bodyA: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        let lines = tipText(i).components(separatedBy: "\n").enumerated().map {
            NSAttributedString(string: $0.element, attributes: $0.offset == 0 ? headA : bodyA)
        }
        guard !lines.isEmpty else { return }
        let lineH: CGFloat = 15
        let w = (lines.map { $0.size().width }.max() ?? 0) + 20
        let h = CGFloat(lines.count) * lineH + 12
        let s = slot(i)
        let barTop = b.counted[i] && b.values[i] > 0 ? min(y(b.values[i], b.axis), plot.maxY - 2) : plot.maxY - 6
        var r = NSRect(x: s.midX - w / 2, y: barTop - 8 - h, width: w, height: h)
        if r.minY < 6 {
            // A tall bar has no room above it: beside it instead, at the top.
            r.origin.y = plot.minY
            r.origin.x = s.maxX + 6 + w <= bounds.width - 6 ? s.maxX + 6 : s.minX - 6 - w
        }
        r.origin.x = min(max(r.minX, 6), bounds.width - 6 - w)
        let box = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        statsCalloutFill.setFill()
        box.fill()
        NSColor.separatorColor.setStroke()
        box.lineWidth = 1
        box.stroke()
        for (n, t) in lines.enumerated() { put(t, at: NSPoint(x: r.minX + 10, y: r.minY + 6 + CGFloat(n) * lineH)) }
    }

    private func y(_ v: Double, _ axis: (top: Double, step: Double)) -> CGFloat {
        plot.maxY - CGFloat(min(max(0, v), axis.top) / axis.top) * plot.height
    }

    /// Round values up the left with a faint line across for each.
    private func drawAxis(_ b: Bars) {
        let n = Int((b.axis.top / b.axis.step).rounded())
        for k in 0...max(1, n) {
            let v = Double(k) * b.axis.step
            let yy = y(v, b.axis)
            (k == 0 ? NSColor.separatorColor : NSColor.separatorColor.withAlphaComponent(0.45)).setFill()
            NSRect(x: plot.minX, y: yy - 0.5, width: plot.width, height: 1).fill()
            let s = b.axisText(v) as NSString
            let sz = s.size(withAttributes: Self.labelA)
            put(s, at: NSPoint(x: plot.minX - 8 - sz.width, y: yy - sz.height / 2), Self.labelA)
        }
    }

    private func drawBars(_ b: Bars) {
        let accent = NSColor.controlAccentColor
        let widest: CGFloat = b.values.count <= 7 ? 34 : 18
        for i in b.values.indices {
            // A bar with nothing is left empty: no mark for a day off, for
            // today before the first stroke, for an empty hour or for a day
            // before counting began. The box under the pointer says which.
            //
            // THE TRAP: an empty bar used to get a small grey dot. It read as
            // a mark on that day, and today got one from midnight until the
            // first stroke. tests/run-tests.sh fails if drawBars draws an
            // oval again.
            let v = b.values[i]
            guard b.counted[i], v > 0 else { continue }
            let s = slot(i)
            let bw = max(2, min(widest, s.width * 0.62))
            let top = min(y(v, b.axis), plot.maxY - 2)
            let r = NSRect(x: s.midX - bw / 2, y: top, width: bw, height: plot.maxY - top)
            (i == b.strong || i == hover ? accent : accent.withAlphaComponent(0.55)).setFill()
            NSBezierPath(roundedRect: r, xRadius: min(3, bw / 2), yRadius: min(3, bw / 2)).fill()
        }
    }

    private func drawAverage(_ b: Bars) {
        guard let avg = b.average, let text = b.averageText else { return }
        let yy = y(avg, b.axis)
        statsAverageColor.setFill()
        NSRect(x: plot.minX, y: yy - 0.5, width: plot.width, height: 1).fill()
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: statsAverageColor]
        let s = text as NSString
        let sz = s.size(withAttributes: a)
        let at = NSPoint(x: plot.minX + 4, y: max(plot.minY, yy - sz.height - 1))
        // On the card's own colour, so a bar behind the label does not cross it.
        let back = NSBezierPath(roundedRect: NSRect(x: at.x - 3, y: at.y, width: sz.width + 6, height: sz.height),
                                xRadius: 3, yRadius: 3)
        NSColor.windowBackgroundColor.setFill(); back.fill()
        statsTileFill.setFill(); back.fill()
        put(s, at: at, a)
    }

    /// Labels under the bars, given by bar. The first ones listed win where
    /// two would overlap, so Today goes first.
    private func placeLabels(_ labels: [(i: Int, text: String, bold: Bool)], y: CGFloat) {
        var placed: [NSRect] = []
        for l in labels {
            let a = l.bold ? Self.boldA : Self.labelA
            let s = l.text as NSString
            let sz = s.size(withAttributes: a)
            let x = min(max(slot(l.i).midX - sz.width / 2, pad), bounds.width - pad - sz.width)
            let r = NSRect(x: x, y: y, width: sz.width, height: sz.height)
            if placed.contains(where: { $0.insetBy(dx: -5, dy: 0).intersects(r) }) { continue }
            placed.append(r)
            put(s, at: r.origin, a)
        }
    }

    /// Days: each day of a week, or each week's first day and Today. Weeks:
    /// where a month begins. Months: each month, with the year at January.
    private func drawDayLabels() {
        guard case .days(let bs, let size, _, _) = content, !bs.isEmpty else { return }
        var labels: [(i: Int, text: String, bold: Bool)] = []
        let last = bs.count - 1
        switch size {
        case .day:
            labels.append((last, "Today", true))
            for (i, b) in bs.enumerated() where i != last
                && (bs.count <= 7 || cal.component(.weekday, from: b.start) == cal.firstWeekday) {
                labels.append((i, format(b.start, bs.count <= 7 ? "EEEd" : "dMMM"), false))
            }
        case .week:
            for i in 1..<max(1, bs.count) where cal.component(.month, from: bs[i].start)
                != cal.component(.month, from: bs[i - 1].start) {
                let m = cal.component(.month, from: bs[i].start)
                labels.append((i, format(bs[i].start, m == 1 ? "y" : "MMM"), false))
            }
        case .month:
            for (i, b) in bs.enumerated() {
                let m = cal.component(.month, from: b.start)
                labels.append((i, format(b.start, i == 0 ? "yMMM" : m == 1 ? "y" : "MMM"), false))
            }
        }
        placeLabels(labels, y: plot.maxY + 6)
    }

    /// Every third hour is labelled: 24 numbers side by side do not fit.
    /// Under them, where the day turns; at the bottom, what the bars are.
    private func drawHourLabels() {
        guard case .hours(_, _, let note) = content else { return }
        placeLabels(stride(from: 0, to: 24, by: 3).map { ($0, String(format: "%02d", $0), false) }, y: plot.maxY + 6)
        for (from, to, name) in [(0, 5, "night"), (5, 12, "morning"), (12, 17, "afternoon"), (17, 22, "evening")] {
            let mid = (slot(from).minX + slot(to - 1).maxX) / 2
            let s = name as NSString
            let sz = s.size(withAttributes: Self.smallA)
            put(s, at: NSPoint(x: mid - sz.width / 2, y: plot.maxY + 20), Self.smallA)
        }
        drawNote(note)
    }

    /// The weekday, and its average under it.
    private func drawWeekdayLabels(strong: Int?) {
        guard case .weekdays(let w, let note) = content else { return }
        for (i, d) in w.enumerated() {
            let s = slot(i)
            let name = StatsCore.weekdayShort[max(0, min(6, d.weekday - 1))] as NSString
            let a = i == strong ? Self.boldA : Self.labelA
            let nsz = name.size(withAttributes: a)
            put(name, at: NSPoint(x: s.midX - nsz.width / 2, y: plot.maxY + 6), a)
            guard d.count > 0 else { continue }
            let v = StatsCore.axisLabel(d.average) as NSString
            let vsz = v.size(withAttributes: Self.noteA)
            put(v, at: NSPoint(x: s.midX - vsz.width / 2, y: plot.maxY + 6 + nsz.height), Self.noteA)
        }
        drawNote(note)
    }

    /// The grey line at the bottom of the card, under the labels.
    /// It wraps inside the card: a long note (a long date, a narrow window)
    /// takes a second line instead of running out of the card, and the plot
    /// above makes room for it (see `plot`).
    private func drawNote(_ note: String?) {
        guard let note = note else { return }
        let size = noteSize(note)
        let r = NSRect(x: pad, y: bounds.height - 12 - size.height, width: bounds.width - 2 * pad, height: size.height)
        (note as NSString).draw(with: r, options: [.usesLineFragmentOrigin], attributes: Self.noteA)
        drawnText.append((note, NSRect(origin: r.origin, size: size)))
    }

    private func noteSize(_ note: String) -> NSSize {
        let b = (note as NSString).boundingRect(with: NSSize(width: max(1, bounds.width - 2 * pad), height: 1000),
                                               options: [.usesLineFragmentOrigin], attributes: Self.noteA)
        return NSSize(width: ceil(b.width), height: ceil(b.height))
    }

    /// Every string drawn by the last draw(_:), and where. Not used to draw:
    /// tests/StatsViewTests.swift reads it to check no text leaves the card.
    private(set) var drawnText: [(text: String, rect: NSRect)] = []

    private func put(_ s: NSString, at p: NSPoint, _ a: [NSAttributedString.Key: Any]) {
        s.draw(at: p, withAttributes: a)
        drawnText.append((s as String, NSRect(origin: p, size: s.size(withAttributes: a))))
    }

    private func put(_ s: NSAttributedString, at p: NSPoint) {
        s.draw(at: p)
        drawnText.append((s.string, NSRect(origin: p, size: s.size())))
    }

    // MARK: Calendar page

    private let calGapX: CGFloat = 12, calGapY: CGFloat = 10, cellGap: CGFloat = 2, monthHead: CGFloat = 15
    private let calTop: CGFloat = 38
    private var monthW: CGFloat { (bounds.width - 2 * pad - 5 * calGapX) / 6 }
    private var cell: CGFloat { (monthW - 6 * cellGap) / 7 }
    private var monthH: CGFloat { monthHead + 6 * cell + 5 * cellGap }

    private func monthOrigin(_ m: Int) -> NSPoint {
        NSPoint(x: pad + CGFloat((m - 1) % 6) * (monthW + calGapX),
                y: calTop + CGFloat((m - 1) / 6) * (monthH + calGapY))
    }

    private func cellRect(_ year: Int, _ m: Int, _ d: Int) -> NSRect {
        let o = monthOrigin(m)
        let g = StatsCore.gridPosition(year: year, month: m, day: d, calendar: cal)
        return NSRect(x: o.x + CGFloat(g.col) * (cell + cellGap), y: o.y + monthHead + CGFloat(g.row) * (cell + cellGap),
                      width: cell, height: cell)
    }

    private func daysInMonth(_ year: Int, _ m: Int) -> Int {
        cal.date(from: DateComponents(year: year, month: m, day: 1))
            .flatMap { cal.range(of: .day, in: .month, for: $0)?.count } ?? 30
    }

    /// More drawing reads as more colour: brighter on dark, deeper on light.
    /// (Lightening the top step on light mode too made "2 h or more" look
    /// paler than "1 to 2 h".)
    private func levelColor(_ level: Int) -> NSColor {
        let a = NSColor.controlAccentColor
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch level {
        case 0: return NSColor.labelColor.withAlphaComponent(0.09)
        case 1: return a.withAlphaComponent(dark ? 0.35 : 0.28)
        case 2: return a.withAlphaComponent(dark ? 0.6 : 0.55)
        case 3: return a.withAlphaComponent(0.85)
        default: return a.blended(withFraction: 0.35, of: dark ? .white : .black) ?? a
        }
    }

    /// Not counted: an outline only. Before counting began or still to come.
    private static func drawNotCounted(_ r: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.16).setStroke()
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.5, yRadius: 1.5)
        p.lineWidth = 1
        p.stroke()
    }

    /// Today in this year, else the last day drawn in it.
    private func defaultDay(_ year: Int) -> String? {
        guard case .calendar(_, let days, _, let todayKey) = content else { return nil }
        let prefix = String(format: "%04d-", year)
        if todayKey.hasPrefix(prefix) { return todayKey }
        return days.filter { $0.key.hasPrefix(prefix) && $0.value.strokes > 0 }.keys.max()
    }

    private func drawCalendar() {
        guard case .calendar(let year, let days, let firstKey, let todayKey) = content else { return }
        let months = cal.shortStandaloneMonthSymbols
        for m in 1...12 {
            let o = monthOrigin(m)
            let current = todayKey.hasPrefix(String(format: "%04d-%02d-", year, m))
            let name = (m <= months.count ? months[m - 1] : String(m)) as NSString
            put(name, at: o, current ? Self.boldA : Self.labelA)
            let total = StatsCore.monthTotalText(StatsCore.monthTotal(days, year: year, month: m)) as NSString
            let tsz = total.size(withAttributes: Self.noteA)
            put(total, at: NSPoint(x: o.x + monthW - tsz.width, y: o.y), Self.noteA)
            for d in 1...daysInMonth(year, m) {
                let key = String(format: "%04d-%02d-%02d", year, m, d)
                let r = cellRect(year, m, d)
                if let f = firstKey, key >= f, key <= todayKey {
                    let st = days[key] ?? DayStats()
                    // Any stroke at all is at least the first step, never "None".
                    let level = st.strokes > 0 ? StatsCore.calendarLevel(max(1, st.activeSeconds)) : 0
                    levelColor(level).setFill()
                    NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
                } else {
                    Self.drawNotCounted(r)
                }
                if key == selectedKey || key == hoverKey {
                    (key == selectedKey ? NSColor.labelColor : NSColor.secondaryLabelColor).setStroke()
                    let ring = NSBezierPath(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), xRadius: 2.5, yRadius: 2.5)
                    ring.lineWidth = key == selectedKey ? 1.5 : 1
                    ring.stroke()
                }
            }
        }

        // The legend: the five steps, then the outline.
        let ly = calTop + 2 * monthH + calGapY + 10
        var x = pad
        for (i, text) in (StatsCore.calendarLegend + [StatsCore.notCountedText]).enumerated() {
            let sw = NSRect(x: x, y: ly + 2, width: 9, height: 9)
            if i < StatsCore.calendarLegend.count {
                levelColor(i).setFill()
                NSBezierPath(roundedRect: sw, xRadius: 1.5, yRadius: 1.5).fill()
            } else {
                Self.drawNotCounted(sw)
            }
            let s = text as NSString
            put(s, at: NSPoint(x: x + 13, y: ly), Self.labelA)
            x += 13 + s.size(withAttributes: Self.labelA).width + 14
        }

        // The day under the pointer, else the chosen one.
        let sepY = ly + 22
        NSColor.separatorColor.setFill()
        NSRect(x: pad, y: sepY, width: bounds.width - 2 * pad, height: 1).fill()
        let lineY = sepY + 9
        let dateA: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                    .foregroundColor: NSColor.labelColor]
        let factA: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        let shown = hoverKey.flatMap { $0.hasPrefix(String(format: "%04d-", year)) ? $0 : nil } ?? selectedKey
        guard let key = shown, let date = StatsCore.date(ofKey: key) else {
            put("Point at a day to see it here" as NSString, at: NSPoint(x: pad, y: lineY), factA)
            return
        }
        let counted = firstKey.map { key >= $0 } == true
        let line = NSMutableAttributedString(string: format(date, "EEEEMMMMd"), attributes: dateA)
        for f in counted ? StatsCore.dayFacts(days[key]) : [StatsCore.notCountedText] {
            line.append(NSAttributedString(string: "     " + f, attributes: factA))
        }
        line.draw(with: NSRect(x: pad, y: lineY, width: bounds.width - 2 * pad, height: 18),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// The calendar day under a point: nil between cells and on days still to come.
    private func dayKey(at p: NSPoint) -> String? {
        guard case .calendar(let year, _, _, let todayKey) = content else { return nil }
        for m in 1...12 {
            for d in 1...daysInMonth(year, m)
            where cellRect(year, m, d).insetBy(dx: -cellGap / 2, dy: -cellGap / 2).contains(p) {
                let key = String(format: "%04d-%02d-%02d", year, m, d)
                return key <= todayKey ? key : nil
            }
        }
        return nil
    }

    /// A click keeps a calendar day in the line below once the pointer leaves.
    override func mouseDown(with e: NSEvent) {
        guard case .calendar = content else { return super.mouseDown(with: e) }
        if let k = dayKey(at: convert(e.locationInWindow, from: nil)), k != selectedKey {
            selectedKey = k
            needsDisplay = true
        }
    }
}
