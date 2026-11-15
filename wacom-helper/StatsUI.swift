// StatsUI.swift: drawing stats, the app half. Counting hook for the pen path,
// saving, and the Stats tab. The arithmetic lives in StatsCore.swift.

import AppKit

// MARK: - counting (main thread, called from the pen path)

var g_stats = StatsCounter()
private var g_statsSavePending = false
private let g_statsQueue = DispatchQueue(label: "drawing-stats.save", qos: .utility)

func statsPath() -> String { appSupport() + "/drawing-stats.txt" }

/// Called from send() with every sample's pressure. Only a change between
/// "touching" and "not touching" does any work; everything else is one compare.
/// The rules (which strokes count) are StatsCounter's, in StatsCore.swift.
func statsNote(pressure p: Int) {
    let counted = g_stats.note(pressure: p, at: CFAbsoluteTimeGetCurrent()) {
        let now = Date()
        return (StatsCore.dayKey(now), StatsCore.secondsAfterMidnight(now))
    }
    if counted { scheduleStatsSave() }
}

/// Kept current by the app-activation observer, so the pen path never asks
/// which app is in front.
func statsSetSAIFront(_ front: Bool) { g_stats.setSAIFront(front) }

func loadStats() {
    let loaded = StatsFile.load(path: statsPath())
    g_stats = StatsCounter(days: loaded.days)
    if let aside = loaded.setAside { wlog("stats: the file had lines that did not read; a copy is at \(aside)") }
}

/// At most one write every 15 seconds while drawing, off the main thread.
/// The stroke path never waits for the disk.
func scheduleStatsSave() {
    if g_statsSavePending { return }
    g_statsSavePending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
        g_statsSavePending = false
        let days = g_stats.days
        let path = statsPath()
        g_statsQueue.async { StatsFile.save(days, path: path) }
    }
}

/// Quitting: write now and wait, so the last 15 seconds are not lost.
func saveStatsNow() {
    let days = g_stats.days
    let path = statsPath()
    g_statsQueue.sync { _ = StatsFile.save(days, path: path) }
}

// MARK: - the menu line

/// Tag of the "Today: …" item in the menu-bar and Dock menus.
let statsMenuTag = 4711

extension SetupController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { fillStatsMenuItem(menu) }

    /// Shown only on a day with something drawn, so a fresh install's menu
    /// does not open on a line of zeros.
    func fillStatsMenuItem(_ menu: NSMenu) {
        guard let it = menu.item(withTag: statsMenuTag) else { return }
        let line = StatsCore.menuLine(g_stats.days[StatsCore.dayKey(Date())] ?? DayStats())
        it.title = line ?? ""
        it.isHidden = line == nil
    }
}

// MARK: - the tab

extension SetupController {

    @objc func statsAppActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        statsSetSAIFront(StatsCore.isSAIFront(bundleId: app?.bundleIdentifier, name: app?.localizedName,
                                              path: app?.executableURL?.path,
                                              isSelf: app?.processIdentifier == getpid()))
    }

    func startStats() {
        loadStats()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(statsAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        let app = NSWorkspace.shared.frontmostApplication
        statsSetSAIFront(StatsCore.isSAIFront(bundleId: app?.bundleIdentifier, name: app?.localizedName,
                                              path: app?.executableURL?.path,
                                              isSelf: app?.processIdentifier == getpid()))
    }

    func buildStatsTab() -> NSStackView {
        let tab = NSStackView()
        tab.orientation = .vertical
        tab.alignment = .leading
        tab.spacing = 10
        tab.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)

        tab.addArrangedSubview(lbl("Statistics", 18, bold: true))
        let intro = lbl("Counted while SAI is in front, whether or not you record.", 11,
                        color: .secondaryLabelColor)
        tab.addArrangedSubview(intro)
        tab.setCustomSpacing(16, after: intro)

        // Three cards across: what you did today, this week, and the streak.
        let gap: CGFloat = 10
        let cardW = (rowWidth - 2 * gap) / 3
        statsCards = ["Today", "Last 7 days", "Streak"].map { StatCardView(title: $0) }
        let cards = NSStackView(views: statsCards)
        cards.orientation = .horizontal
        cards.spacing = gap
        for c in statsCards {
            c.translatesAutoresizingMaskIntoConstraints = false
            c.widthAnchor.constraint(equalToConstant: cardW).isActive = true
            c.heightAnchor.constraint(equalToConstant: 84).isActive = true
        }
        tab.addArrangedSubview(cards)
        tab.setCustomSpacing(gap, after: cards)

        statsBars = StatsBarsView()
        statsBars.translatesAutoresizingMaskIntoConstraints = false
        statsBars.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        statsBars.heightAnchor.constraint(equalToConstant: 170).isActive = true
        tab.addArrangedSubview(statsBars)
        tab.setCustomSpacing(14, after: statsBars)

        statsFooter = lbl("", 12)
        tab.addArrangedSubview(statsFooter)
        tab.addArrangedSubview(lbl("Short pauses count as drawing. A pause over a minute is a break.",
                                   11, color: .secondaryLabelColor))
        tab.setCustomSpacing(14, after: tab.arrangedSubviews.last!)
        statsExportButton = NSButton(title: "Export CSV…", target: self, action: #selector(exportStatsCSV))
        statsExportButton.bezelStyle = .rounded
        tab.addArrangedSubview(statsExportButton)
        refreshStatsTab()
        return tab
    }

    /// Every counted day, one row each, for a spreadsheet.
    @objc func exportStatsCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Drawing statistics.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try StatsCore.csv(g_stats.days).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let a = NSAlert()
            a.messageText = "Could not save the file"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    func refreshStatsTab() {
        guard statsCards.count == 3, statsBars != nil else { return }
        statsExportButton?.isEnabled = !g_stats.days.isEmpty
        let days = g_stats.days
        let now = Date()
        let today = days[StatsCore.dayKey(now)] ?? DayStats()
        let week = StatsCore.total(StatsCore.lastDays(days, count: 7, today: now).map { $0.stats })
        let all = StatsCore.total(Array(days.values))

        func set(_ card: StatCardView, _ d: DayStats) {
            card.value = StatsCore.cardTime(d.activeSeconds)
            card.detail = d.strokes == 0 ? "No strokes yet" : StatsCore.strokes(d.strokes)
        }
        set(statsCards[0], today)
        set(statsCards[1], week)
        let s = StatsCore.streak(days, today: now)
        statsCards[2].value = s == 1 ? "1 day" : "\(s) days"
        statsCards[2].detail = StatsCore.streakHint(streak: s, drewToday: today.strokes > 0)

        statsBars.days = StatsCore.lastDays(days, count: 14, today: now)
        statsBars.hours = StatsCore.hourTotals(days, count: StatsBarsView.hourDays, today: now)

        if all.strokes == 0 {
            statsFooter.stringValue = "Nothing counted yet. Draw in SAI and it shows up here."
        } else {
            var text = "All time: \(StatsCore.duration(all.activeSeconds)), \(StatsCore.strokes(all.strokes))"
            if let best = StatsCore.bestDay(days), let d = StatsCore.date(ofKey: best.key) {
                let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMd")
                text += "   ·   Best day: \(f.string(from: d)), \(StatsCore.duration(best.stats.activeSeconds))"
            }
            statsFooter.stringValue = text
        }
    }
}

// MARK: - views

/// A rounded tile: a small title, one big number, a line under it.
final class StatCardView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    var value: String { get { valueField.stringValue } set { valueField.stringValue = newValue } }
    var detail: String { get { detailField.stringValue } set { detailField.stringValue = newValue } }

    init(title: String) {
        super.init(frame: .zero)
        titleField.stringValue = title.uppercased()
        titleField.font = .systemFont(ofSize: 10, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        valueField.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        valueField.lineBreakMode = .byTruncatingTail
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [titleField, valueField, detailField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setCustomSpacing(6, after: titleField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
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

/// The chart card. Two views of the same drawing time, switched in its top
/// right corner: which days (the last two weeks, one bar each) and which
/// hours (the last 30 days added up, one bar per hour of the day). Hovering a
/// bar shows its numbers.
final class StatsBarsView: NSView, NSViewToolTipOwner {
    enum Mode: Int { case days = 0, hours = 1 }

    var days: [(key: String, stats: DayStats)] = [] {
        didSet { needsDisplay = true; rebuildToolTips() }
    }
    /// Drawing seconds per hour of the day, 24 values.
    var hours: [Double] = Array(repeating: 0, count: 24) {
        didSet { needsDisplay = true; rebuildToolTips() }
    }
    static let hourDays = 30

    private(set) var mode: Mode = .days
    private let modeSwitch = NSSegmentedControl(labels: ["Days", "Hours"], trackingMode: .selectOne,
                                                target: nil, action: nil)
    private static let modeKey = "statsChartMode"

    private let pad: CGFloat = 14
    private let titleH: CGFloat = 26
    private let labelH: CGFloat = 26

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Which view was last looked at is a convenience, so plain defaults.
        mode = Mode(rawValue: UserDefaults.standard.integer(forKey: StatsBarsView.modeKey)) ?? .days
        modeSwitch.controlSize = .small
        modeSwitch.font = .systemFont(ofSize: 10)
        modeSwitch.selectedSegment = mode.rawValue
        modeSwitch.target = self
        modeSwitch.action = #selector(modeChanged)
        modeSwitch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(modeSwitch)
        NSLayoutConstraint.activate([
            modeSwitch.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            modeSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad + 2),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func modeChanged() { setMode(Mode(rawValue: modeSwitch.selectedSegment) ?? .days) }

    func setMode(_ m: Mode) {
        mode = m
        modeSwitch.selectedSegment = m.rawValue
        UserDefaults.standard.set(m.rawValue, forKey: StatsBarsView.modeKey)
        needsDisplay = true
        rebuildToolTips()
    }

    private var count: Int { mode == .days ? days.count : 24 }
    private func value(_ i: Int) -> Double { mode == .days ? days[i].stats.activeSeconds : hours[i] }

    private var plot: NSRect {
        NSRect(x: pad, y: pad - 4 + labelH, width: bounds.width - 2 * pad,
               height: bounds.height - titleH - labelH - pad - 8)
    }
    private func slot(_ i: Int) -> NSRect {
        let w = plot.width / CGFloat(max(1, count))
        return NSRect(x: plot.minX + CGFloat(i) * w, y: plot.minY, width: w, height: plot.height)
    }

    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); rebuildToolTips() }

    private func rebuildToolTips() {
        removeAllToolTips()
        for i in 0..<count { addToolTip(slot(i), owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let i = (0..<count).first(where: { slot($0).contains(point) }) else { return "" }
        if mode == .hours {
            let span = String(format: "%02d:00 to %02d:00", i, (i + 1) % 24)
            return hours[i] < 60 ? "\(span): nothing drawn in the last \(StatsBarsView.hourDays) days"
                : "\(span): \(StatsCore.duration(hours[i])) in the last \(StatsBarsView.hourDays) days"
        }
        let d = days[i]
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        let when = StatsCore.date(ofKey: d.key).map { f.string(from: $0) } ?? d.key
        return d.stats.strokes == 0 ? "\(when): nothing drawn"
            : "\(when): \(StatsCore.duration(d.stats.activeSeconds)), \(StatsCore.strokes(d.stats.strokes))"
    }

    override func draw(_ dirtyRect: NSRect) {
        statsTileFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()

        let titleA: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                     .foregroundColor: NSColor.secondaryLabelColor]
        let noteA: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10),
                                                    .foregroundColor: NSColor.tertiaryLabelColor]
        let top = (0..<count).map(value).max() ?? 0
        let title = mode == .days ? "LAST TWO WEEKS" : "TIME OF DAY, LAST \(StatsBarsView.hourDays) DAYS"
        var note: String?
        if mode == .days, top > 0 { note = "Longest: \(StatsCore.duration(top))" }
        if mode == .hours { note = StatsCore.whenText(hours) }
        let t = NSMutableAttributedString(string: title, attributes: titleA)
        if let note { t.append(NSAttributedString(string: "   " + note, attributes: noteA)) }
        t.draw(at: NSPoint(x: pad, y: bounds.height - titleH + 4))
        guard count > 0 else { return }

        // Baseline.
        NSColor.separatorColor.setFill()
        NSRect(x: plot.minX, y: plot.minY - 1, width: plot.width, height: 1).fill()

        let accent = NSColor.controlAccentColor
        // Days: today in full colour. Hours: the busiest hour.
        let strong = mode == .days ? count - 1 : (top > 0 ? hours.firstIndex(of: top) ?? -1 : -1)
        for i in 0..<count {
            let s = slot(i)
            let barW = min(18, s.width * 0.58)
            let v = value(i)
            if v > 0, top > 0 {
                let h = max(4, CGFloat(v / top) * s.height)
                (i == strong ? accent : accent.withAlphaComponent(0.45)).setFill()
                NSBezierPath(roundedRect: NSRect(x: s.midX - barW / 2, y: s.minY, width: barW, height: h),
                             xRadius: min(4, barW / 2), yRadius: min(4, barW / 2)).fill()
            } else {
                // An empty slot still shows as a small dot, so the row reads as
                // a full row and not as a chart with holes.
                NSColor.tertiaryLabelColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: s.midX - 1.5, y: s.minY + 2, width: 3, height: 3)).fill()
            }
        }
        if mode == .days { drawDayLabels() } else { drawHourLabels(strong: strong) }
    }

    private func drawDayLabels() {
        let cal = Calendar.current
        let wd = DateFormatter(); wd.setLocalizedDateFormatFromTemplate("EEEEE")
        for (i, day) in days.enumerated() {
            let s = slot(i)
            let isToday = i == days.count - 1
            let date = StatsCore.date(ofKey: day.key)
            let num = date.map { String(cal.component(.day, from: $0)) } ?? ""
            let letter = date.map { wd.string(from: $0) } ?? ""
            let numA: [NSAttributedString.Key: Any] = [
                .font: isToday ? NSFont.systemFont(ofSize: 10, weight: .bold) : NSFont.systemFont(ofSize: 10),
                .foregroundColor: isToday ? NSColor.labelColor : NSColor.secondaryLabelColor]
            let letA: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9),
                                                       .foregroundColor: NSColor.tertiaryLabelColor]
            let n = num as NSString, l = letter as NSString
            let ns = n.size(withAttributes: numA), ls = l.size(withAttributes: letA)
            n.draw(at: NSPoint(x: s.midX - ns.width / 2, y: plot.minY - 4 - ns.height), withAttributes: numA)
            l.draw(at: NSPoint(x: s.midX - ls.width / 2, y: plot.minY - 4 - ns.height - ls.height), withAttributes: letA)
        }
    }

    /// Every third hour is labelled: 24 numbers side by side do not fit.
    /// Under them, where the day turns: night, morning, afternoon, evening.
    private func drawHourLabels(strong: Int) {
        for i in stride(from: 0, to: 24, by: 3) {
            let s = slot(i)
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
            let n = String(format: "%02d", i) as NSString
            let ns = n.size(withAttributes: a)
            n.draw(at: NSPoint(x: s.midX - ns.width / 2, y: plot.minY - 4 - ns.height), withAttributes: a)
        }
        let partA: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9),
                                                    .foregroundColor: NSColor.tertiaryLabelColor]
        for (from, to, name) in [(0, 5, "night"), (5, 12, "morning"), (12, 17, "afternoon"), (17, 22, "evening")] {
            let mid = (slot(from).minX + slot(to - 1).maxX) / 2
            let t = name as NSString
            let ts = t.size(withAttributes: partA)
            t.draw(at: NSPoint(x: mid - ts.width / 2, y: plot.minY - 4 - 13 - ts.height), withAttributes: partA)
        }
    }
}
