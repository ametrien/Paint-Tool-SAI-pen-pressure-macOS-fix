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

/// Which page and period were last looked at. A convenience, so plain defaults.
private let statsPageKey = "statsPage"
private let statsPeriodKey = "statsPeriod"

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

    /// The tab: a title with the period (or, on Calendar, the year) beside it,
    /// a page switch, four tiles, the chart card and the footer. Everything
    /// but the chart card is the same on every page, and the card keeps its
    /// size, so the window does not jump when the page changes.
    func buildStatsTab() -> NSStackView {
        let tab = NSStackView()
        tab.orientation = .vertical
        tab.alignment = .leading
        tab.spacing = 10
        tab.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)

        let title = lbl("Statistics", 18, bold: true)
        statsPeriodSwitch = NSSegmentedControl(labels: StatsPeriod.allCases.map { $0.title }, trackingMode: .selectOne,
                                               target: self, action: #selector(statsPeriodChanged))
        let savedPeriod = UserDefaults.standard.object(forKey: statsPeriodKey) as? Int
        statsPeriodSwitch.selectedSegment = (StatsPeriod(rawValue: savedPeriod ?? -1) ?? .month).rawValue
        statsYearBack = statsArrow("chevron.left", "Previous year", #selector(statsYearBackPressed))
        statsYearForward = statsArrow("chevron.right", "Next year", #selector(statsYearForwardPressed))
        statsYearLabel = lbl("", 13)
        statsYearLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        statsYearBox = NSStackView(views: [statsYearBack, statsYearLabel, statsYearForward])
        statsYearBox.orientation = .horizontal
        statsYearBox.spacing = 8
        let head = NSView()
        for v in [head, title, statsPeriodSwitch!, statsYearBox!] { v.translatesAutoresizingMaskIntoConstraints = false }
        [title, statsPeriodSwitch!, statsYearBox!].forEach(head.addSubview)
        NSLayoutConstraint.activate([
            head.widthAnchor.constraint(equalToConstant: rowWidth),
            head.heightAnchor.constraint(equalToConstant: 26),
            title.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            statsPeriodSwitch.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            statsPeriodSwitch.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            statsYearBox.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            statsYearBox.centerYAnchor.constraint(equalTo: head.centerYAnchor),
        ])
        tab.addArrangedSubview(head)
        tab.setCustomSpacing(4, after: head)
        let intro = lbl("Counted while SAI is in front, whether or not you record.", 11,
                        color: .secondaryLabelColor)
        tab.addArrangedSubview(intro)
        tab.setCustomSpacing(14, after: intro)

        statsPageSwitch = NSSegmentedControl(labels: StatsPage.allCases.map { $0.title }, trackingMode: .selectOne,
                                             target: self, action: #selector(statsPageChanged))
        statsPageSwitch.segmentDistribution = .fillEqually
        let savedPage = UserDefaults.standard.integer(forKey: statsPageKey)
        statsPageSwitch.selectedSegment = (StatsPage(rawValue: savedPage) ?? .days).rawValue
        statsPageSwitch.translatesAutoresizingMaskIntoConstraints = false
        statsPageSwitch.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        tab.addArrangedSubview(statsPageSwitch)
        tab.setCustomSpacing(12, after: statsPageSwitch)

        // Four tiles across: 117 pt each, which is what cardTimeParts is cut for.
        let gap: CGFloat = 10
        let tileW = (rowWidth - 3 * gap) / 4
        statsTiles = ["Total", "Days drawn", "Average day", "Streak"].map { StatCardView(title: $0) }
        let tiles = NSStackView(views: statsTiles)
        tiles.orientation = .horizontal
        tiles.spacing = gap
        for c in statsTiles {
            c.translatesAutoresizingMaskIntoConstraints = false
            c.widthAnchor.constraint(equalToConstant: tileW).isActive = true
            c.heightAnchor.constraint(equalToConstant: 78).isActive = true
        }
        tab.addArrangedSubview(tiles)
        tab.setCustomSpacing(gap, after: tiles)

        // Tall enough for the calendar's twelve months; the bar pages use the
        // same height so nothing moves when switching.
        statsChart = StatsChartView()
        statsChart.translatesAutoresizingMaskIntoConstraints = false
        statsChart.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        statsChart.heightAnchor.constraint(equalToConstant: 268).isActive = true
        tab.addArrangedSubview(statsChart)
        tab.setCustomSpacing(14, after: statsChart)

        // The All time line gets the whole width: with years in its dates it
        // is about 460 pt, and beside the button it ended in "…". The button
        // sits on the second line instead.
        statsFooter = lbl("", 12)
        statsFooter.lineBreakMode = .byTruncatingTail
        statsFooter.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let pauses = lbl("Short pauses count as drawing. A pause over a minute is a break.",
                         11, color: .secondaryLabelColor)
        statsExportButton = NSButton(title: "Export CSV…", target: self, action: #selector(exportStatsCSV))
        statsExportButton.bezelStyle = .rounded
        let foot = NSView()
        for v in [foot, statsFooter!, pauses, statsExportButton!] { v.translatesAutoresizingMaskIntoConstraints = false }
        [statsFooter!, pauses, statsExportButton!].forEach(foot.addSubview)
        NSLayoutConstraint.activate([
            foot.widthAnchor.constraint(equalToConstant: rowWidth),
            statsFooter.leadingAnchor.constraint(equalTo: foot.leadingAnchor),
            statsFooter.topAnchor.constraint(equalTo: foot.topAnchor),
            statsFooter.trailingAnchor.constraint(lessThanOrEqualTo: foot.trailingAnchor),
            pauses.leadingAnchor.constraint(equalTo: foot.leadingAnchor),
            pauses.topAnchor.constraint(equalTo: statsFooter.bottomAnchor, constant: 6),
            pauses.trailingAnchor.constraint(lessThanOrEqualTo: statsExportButton.leadingAnchor, constant: -12),
            statsExportButton.trailingAnchor.constraint(equalTo: foot.trailingAnchor),
            statsExportButton.centerYAnchor.constraint(equalTo: pauses.centerYAnchor),
            foot.bottomAnchor.constraint(equalTo: statsExportButton.bottomAnchor),
        ])
        tab.addArrangedSubview(foot)
        refreshStatsTab()
        return tab
    }

    private func statsArrow(_ symbol: String, _ name: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.toolTip = name
        return b
    }

    @objc func statsPageChanged() {
        UserDefaults.standard.set(statsPageSwitch.selectedSegment, forKey: statsPageKey)
        refreshStatsTab()
    }

    @objc func statsPeriodChanged() {
        UserDefaults.standard.set(statsPeriodSwitch.selectedSegment, forKey: statsPeriodKey)
        refreshStatsTab()
    }

    @objc func statsYearBackPressed() { stepStatsYear(-1) }
    @objc func statsYearForwardPressed() { stepStatsYear(1) }

    func stepStatsYear(_ by: Int) {
        statsYear = StatsCore.stepYear(statsYear, by, StatsCore.calendarYears(g_stats.days, today: Date()))
        refreshStatsTab()
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

    /// Runs every second while the tab is open. The chart only redraws when
    /// what it shows has changed.
    func refreshStatsTab() {
        guard statsTiles.count == 4, let chart = statsChart else { return }
        statsExportButton?.isEnabled = !g_stats.days.isEmpty
        let days = g_stats.days
        let now = Date()
        let page = StatsPage(rawValue: statsPageSwitch.selectedSegment) ?? .days
        let period = StatsPeriod(rawValue: statsPeriodSwitch.selectedSegment) ?? .month

        // The Calendar page has a year where the other pages have a period.
        let onCalendar = page == .calendar
        let years = StatsCore.calendarYears(days, today: now)
        statsYear = StatsCore.stepYear(statsYear, 0, years)
        statsPeriodSwitch.isHidden = onCalendar
        statsYearBox.isHidden = !onCalendar
        statsYearLabel.stringValue = String(statsYear)
        statsYearBack.isEnabled = statsYear > years.lowerBound
        statsYearForward.isEnabled = statsYear < years.upperBound
        let range = onCalendar ? StatsCore.yearRange(statsYear, today: now)
                               : StatsCore.range(period, today: now, days: days)

        let sum = StatsCore.summary(days, range: range)
        let t = statsTiles
        t[0].title = !onCalendar ? "Total" : statsYear == years.upperBound ? "This year" : String(statsYear)
        t[0].setValue(StatsCore.cardTimeParts(sum.total.activeSeconds))
        t[0].detail = sum.total.strokes == 0 ? "No strokes yet" : StatsCore.strokes(sum.total.strokes)
        t[1].setValue(StatsCore.daysDrawnParts(sum))
        t[1].detail = StatsCore.daysDrawnDetail(sum)
        t[2].setValue(StatsCore.cardTimeParts(sum.averageDay))
        t[2].detail = StatsCore.averageDetail(sum)
        let streak = StatsCore.streak(days, today: now)
        t[3].setValue(StatsCore.streakParts(streak))
        t[3].detail = StatsCore.streakDetail(streak: streak, best: StatsCore.longestStreak(days)?.length)

        // The first counted day as the footer writes it ("15 Nov"), for the
        // notes under the Hours and Weekdays charts.
        let thisYear = Calendar.current.component(.year, from: now)
        func short(_ key: String) -> String? {
            guard let d = StatsCore.date(ofKey: key) else { return nil }
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate(Calendar.current.component(.year, from: d) == thisYear ? "MMMd" : "yMMMd")
            return f.string(from: d)
        }
        let firstText = StatsCore.firstCountedKey(days).flatMap(short)
        let same = StatsCore.sameAsAllTime(period, range: range, days: days)

        switch page {
        case .days:
            let size = StatsCore.bucketSize(range)
            chart.content = .days(buckets: StatsCore.buckets(days, range: range, size: size),
                                  size: size, range: range, days: days)
        case .hours:
            let p = StatsCore.hourProfile(days, range: range)
            chart.content = .hours(p, daysDrawn: sum.daysDrawn,
                                   note: StatsCore.hoursNote(p, period: period, firstText: firstText, sameAsAll: same))
        case .weekdays:
            let w = StatsCore.weekdayAverages(days, range: range)
            chart.content = .weekdays(w, note: StatsCore.weekdaysNote(w, period: period, firstText: firstText, sameAsAll: same))
        case .calendar:
            chart.content = .calendar(year: statsYear, days: days, firstKey: StatsCore.firstCountedKey(days),
                                      todayKey: StatsCore.dayKey(now))
        }

        let all = StatsCore.total(Array(days.values))
        if all.strokes == 0 {
            statsFooter.stringValue = "Nothing counted yet. Draw in SAI and it shows up here."
        } else {
            var text = "All time: \(StatsCore.duration(all.activeSeconds))"
            if let first = StatsCore.firstCountedKey(days).flatMap(short) { text += " since \(first)" }
            if let best = StatsCore.bestDay(days), let d = short(best.key) {
                text += "   ·   Best day: \(d), \(StatsCore.duration(best.stats.activeSeconds))"
            }
            statsFooter.stringValue = text
        }
    }
}

