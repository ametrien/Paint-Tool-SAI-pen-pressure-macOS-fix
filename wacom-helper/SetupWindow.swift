// SetupWindow.swift — building the window and deciding what it shows.
//
// Moved out of main.swift unchanged. buildWindow() makes the Setup, Pen and
// Advanced tabs and collects the rest (Keys, Recording, Videos, each built in
// its own file); applyLayout() then hides what the current state does not need
// and sizes the window to the tab on screen.
//
// The controls it creates are stored properties of the class in main.swift.

import AppKit
import Foundation

extension SetupController {

    func buildWindow() {
        // NOTE: assigns the PROPERTY, not a local — applyLayout() needs it later
        // to measure fittingSize. A `let content = …` here shadows the property
        // and leaves self.content nil.
        content = NSStackView()
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(lbl("SAI Pen Pressure Setup", 18, bold: true))
        subtitle = lbl("Let's get everything ready.", 12, color: .secondaryLabelColor)
        content.addArrangedSubview(subtitle)

        for (i, r) in reqs.enumerated() {
            let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
            let status = lbl("…", 13, bold: true)
            status.widthAnchor.constraint(equalToConstant: 18).isActive = true
            statusFields.append(status)
            let col = NSStackView(); col.orientation = .vertical; col.alignment = .leading; col.spacing = 0
            col.addArrangedSubview(lbl(r.title, 12, bold: true))
            let detail = lbl(r.detail, 10, color: .secondaryLabelColor)
            detailFields.append(detail)
            col.addArrangedSubview(detail)
            let btn = NSButton(title: r.fixTitle, target: self, action: #selector(fixTapped(_:)))
            btn.tag = i; btn.bezelStyle = .rounded; btn.controlSize = .small
            btn.setContentHuggingPriority(.required, for: .horizontal)
            fixButtons.append(btn)
            let spacer = NSView()
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
            row.addArrangedSubview(status); row.addArrangedSubview(col); row.addArrangedSubview(spacer)
            // "Show ▸" sits before the main action so the primary button stays
            // in the same column down the whole checklist.
            if r.extraTitle != nil {
                let extra = NSButton(title: r.extraTitle!, target: self, action: #selector(extraTapped(_:)))
                extra.tag = i; extra.bezelStyle = .rounded; extra.controlSize = .small
                extra.setContentHuggingPriority(.required, for: .horizontal)
                extraButtons.append(extra)
                row.addArrangedSubview(extra)
            } else {
                extraButtons.append(nil)
            }
            row.addArrangedSubview(btn)
            row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
            rowViews.append(row)
            content.addArrangedSubview(row)
        }

        // --- "all set" summary -------------------------------------------------
        // Simple mode hides satisfied rows, so a finished setup left a blank gap
        // above Launch. Replace it with a compact green confirmation of exactly
        // what's ready, so the space reads as reassurance rather than absence.
        allSetLabel = lbl("", 11, color: .secondaryLabelColor)
        content.addArrangedSubview(allSetLabel)

        // --- automatic setup: the one button that does the whole checklist ----
        autoBtn = NSButton(title: "Set up everything automatically", target: self, action: #selector(autoSetup))
        autoBtn.bezelStyle = .rounded; autoBtn.controlSize = .large
        content.addArrangedSubview(autoBtn)

        // Live Wine download progress, piped from install-wine.sh's curl.
        wineRow = NSStackView(); wineRow.orientation = .horizontal
        wineRow.alignment = .centerY; wineRow.spacing = 10
        wineBar = PressureBar()
        wineBar.widthAnchor.constraint(equalToConstant: 200).isActive = true
        wineBar.heightAnchor.constraint(equalToConstant: 12).isActive = true
        wineLabel = lbl("", 11, color: .secondaryLabelColor)
        wineRow.addArrangedSubview(wineBar); wineRow.addArrangedSubview(wineLabel)
        wineRow.isHidden = true
        content.addArrangedSubview(wineRow)

        // --- primary action ---------------------------------------------------
        launchBtn = NSButton(title: "Launch SAI with Pressure", target: self, action: #selector(launchTapped))
        launchBtn.bezelStyle = .rounded; launchBtn.keyEquivalent = "\r"; launchBtn.controlSize = .large
        content.addArrangedSubview(launchBtn)

        // --- secondary actions, side by side instead of stacked ---------------
        let wakeBtn = NSButton(title: "Wake SAI (if stuck)", target: self, action: #selector(wakeSAI))
        wakeBtn.bezelStyle = .rounded; wakeBtn.controlSize = .small
        advancedBtn = NSButton(title: "Show all steps ⌄", target: self, action: #selector(toggleAdvanced))
        advancedBtn.bezelStyle = .rounded; advancedBtn.controlSize = .small
        secondaryRow = NSStackView(); secondaryRow.orientation = .horizontal
        secondaryRow.alignment = .centerY; secondaryRow.spacing = 8
        secondaryRow.addArrangedSubview(wakeBtn)
        autoWakeCheck = NSButton(checkboxWithTitle: "Auto-wake", target: self,
                                 action: #selector(autoWakeCheckToggled))
        autoWakeCheck.controlSize = .small
        secondaryRow.addArrangedSubview(autoWakeCheck)
        // advancedBtn goes in the tools row further down, with the other things
        // that are about the app rather than about SAI running right now.
        content.addArrangedSubview(secondaryRow)

        testHint = lbl("Press your pen on the tablet. Both bars should move.", 10, color: .secondaryLabelColor)
        testHint.preferredMaxLayoutWidth = rowWidth
        testHint.isHidden = true
        barRow = NSStackView(); barRow.orientation = .horizontal; barRow.alignment = .centerY; barRow.spacing = 10
        pressureBar = PressureBar()
        pressureBar.widthAnchor.constraint(equalToConstant: 240).isActive = true
        pressureBar.heightAnchor.constraint(equalToConstant: 12).isActive = true
        // Show the RAW value and the scale, not just a percent — the whole point
        // of issue #21 is how many distinct levels actually arrive, and a
        // percentage hides that completely.
        pressureLabel = lbl("0 / \(PressureCore.maxPressure)", 11, bold: true)
        pressureLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        barRow.addArrangedSubview(pressureBar); barRow.addArrangedSubview(pressureLabel)
        barRow.isHidden = true


        // --- pressure resolution, in Settings ---------------------------------
        // Auto follows the tablet's own HID report; the explicit choices are an
        // override for people who want to experiment. Above the tablet's real
        // count you get noise, not detail, so the UI says so.
        let pRow = NSStackView(); pRow.orientation = .horizontal; pRow.spacing = 8
        pRow.alignment = .centerY
        pRow.addArrangedSubview(lbl("Pressure levels", 12, bold: true))
        pressurePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        settingsTab = NSStackView()
        settingsTab.orientation = .vertical; settingsTab.alignment = .leading; settingsTab.spacing = 10
        settingsTab.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)
        settingsTab.addArrangedSubview(lbl("Pen settings", 18, bold: true))
        // Defended explicitly: a stack short of room compresses by this
        // priority, and the default let real controls collapse silently.
        defer {
            settingsTab.arrangedSubviews.forEach {
                if !($0 is PenScratchView) {
                    $0.setContentCompressionResistancePriority(.required, for: .vertical)
                }
            }
        }

        pressurePopup.controlSize = .small
        pressurePopup.target = self
        pressurePopup.action = #selector(pressureChoiceChanged)
        pressurePopup.addItem(withTitle: "Auto")
        for v in PressureCore.pressureChoices { pressurePopup.addItem(withTitle: "\(v + 1)") }
        pRow.addArrangedSubview(pressurePopup)
        pressureInfo = lbl("", 10, color: .tertiaryLabelColor)
        pRow.addArrangedSubview(pressureInfo)
        settingsTab.addArrangedSubview(pRow)

        // Pen feel: applied on our side before the value is sent, so it needs no
        // agreement with the DLL and no SAI restart. Stacks with the Wacom
        // driver's own curve and SAI's per-brush Min Size — hence Normal default.
        let fRow = NSStackView(); fRow.orientation = .horizontal; fRow.spacing = 8
        fRow.alignment = .centerY
        fRow.addArrangedSubview(lbl("Pen feel", 12, bold: true))
        feelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        feelPopup.controlSize = .small
        feelPopup.target = self; feelPopup.action = #selector(feelChanged)
        penProfiles = savedPenProfiles()
        selectedProfile = nil
        if let m = PenFeelCore.matchName(currentFeel(), profiles: penProfiles),
           penProfiles.contains(where: { $0.name == m }) { selectedProfile = m }
        fRow.addArrangedSubview(feelPopup)
        fRow.addArrangedSubview(lbl("how the pen responds · applies instantly", 10, color: .tertiaryLabelColor))
        settingsTab.addArrangedSubview(fRow)

        // --- one-button recovery, in Settings ---------------------------------
        // The whole point: a single obvious action that rebuilds everything, for
        // when the prefix is broken and you don't want to reason about which
        // half is at fault.
        // One quiet row for everything that is about the app rather than about
        // drawing: three rows of identical grey buttons made Uninstall look as
        // ordinary as Wake, and nothing said which buttons belonged together.
        // Recessed bezels only show on hover, so this row reads as secondary
        // next to Launch.
        scratchRow = NSStackView(); scratchRow.orientation = .horizontal
        scratchRow.alignment = .centerY; scratchRow.spacing = 4
        advancedBtn.bezelStyle = .recessed
        scratchRow.addArrangedSubview(advancedBtn)
        // Visible, not in the menu, and outside Developer mode on purpose: the
        // person who needs it is the one reporting a fault, and in #29
        // everything worth pasting was behind a switch they had no reason to find.
        let reportBtn = NSButton(title: "Copy problem report", target: self, action: #selector(copyProblemReport))
        reportBtn.bezelStyle = .recessed; reportBtn.controlSize = .small
        scratchRow.addArrangedSubview(reportBtn)
        setupReportBtn = reportBtn
        // Update is routine (SAI Ver.2 is a rolling preview); Reset and
        // Uninstall are not, and sit under a separator so they are never the
        // thing a stray click lands on.
        let more = NSPopUpButton(frame: .zero, pullsDown: true)
        more.bezelStyle = .recessed; more.controlSize = .small
        more.addItem(withTitle: "More")             // a pull-down's title is item 0
        func item(_ t: String, _ sel: Selector, _ tip: String) {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            i.target = self; i.toolTip = tip
            more.menu?.addItem(i)
        }
        item("Show app in Finder", #selector(revealThisApp),
             "Open the folder this app is in, with the app selected.")
        item("Show SAI folder", #selector(openSAIInWine),
             "Open the copy of SAI that runs, inside Wine.")
        item("Update SAI…", #selector(updateSAITapped),
             "Point at a newer SAI folder. Keeps your licence, brushes and preferences.")
        more.menu?.addItem(.separator())
        item("Reset everything & reinstall…", #selector(installFromScratch), "Keeps your SAI folder and licence.")
        item("Uninstall…", #selector(uninstallEverything), "Keeps your SAI folder and licence.")
        scratchRow.addArrangedSubview(more)
        // NOT appended to rowViews — that array is index-locked to `reqs` and an
        // extra entry would desync applyLayout()'s loop. It's Settings-only.
        // --- footers: explanation, only in Settings ---------------------------
        // Kept to ONE line each — these wrapped to two and made the window tall.
        for s in ["Wake: menu-bar pen icon, Dock right-click, or ⌃⌥⌘Space.",
                  "SAI runs from a copy in \(( appPrefix as NSString).abbreviatingWithTildeInPath); the source folder is only needed to (re)install.",
                  "PaintTool SAI © SYSTEMAX. Unaffiliated fix, bring your own license (systemax.jp)."] {
            let l = lbl(s, 10, color: .tertiaryLabelColor)
            l.preferredMaxLayoutWidth = rowWidth
            l.lineBreakMode = .byWordWrapping
            l.usesSingleLineMode = false
            footerLabels.append(l)
            content.addArrangedSubview(l)
        }

        // --- developer section (inside Settings) ------------------------------
        devSection = NSStackView(); devSection.orientation = .vertical
        devSection.alignment = .leading; devSection.spacing = 6
        devCheck = NSButton(checkboxWithTitle: "Developer mode", target: self, action: #selector(toggleDevCheck))
        devSection.addArrangedSubview(devCheck)
        // Updates live here rather than behind developer mode: this is a setting
        // people actually want, and the tab is called Advanced for that reason.
        autoUpdateCheck = NSButton(checkboxWithTitle: "Install updates automatically",
                                   target: self, action: #selector(autoUpdateToggled))
        autoUpdateCheck.state = autoUpdateEnabled() ? .on : .off
        devSection.addArrangedSubview(autoUpdateCheck)
        // Next to it because both are things a person chooses, not diagnostics.
        redactCheck = NSButton(checkboxWithTitle: "Hide my user name in copied reports",
                               target: self, action: #selector(redactToggled))
        redactCheck.state = reportRedactEnabled() ? .on : .off
        devSection.addArrangedSubview(redactCheck)
        devSection.addArrangedSubview(
            lbl("Paths become ~/… instead of /Users/you/… . Turn it off only if a full path is the problem.",
                10, color: .tertiaryLabelColor))
        devUpdateRows = [autoUpdateCheck]
        // Here and not on its own tab: a test for issue #39, not a release feature yet.
        // Shown without Developer mode too: the person with blurry text is not
        // the person digging through logs.
        let display = buildDisplaySection()
        devSection.addArrangedSubview(display)
        devUpdateRows.append(display)
        let wineBox = buildWineSection()
        devSection.addArrangedSubview(wineBox)
        devUpdateRows.append(wineBox)
        // Folders first — "where did my SAI actually go?" is the question the
        // whole copy-into-the-prefix model raises, so answer it with a button.
        let devFolders = NSStackView(); devFolders.orientation = .horizontal; devFolders.spacing = 6
        for (t, s) in [("SAI in Wine ▸", #selector(openSAIInWine)),
                       ("License ▸", #selector(revealLicense)),
                       ("Wine prefix ▸", #selector(openWinePrefix)),
                       ("App data ▸", #selector(openAppSupport))] {
            let b = NSButton(title: t, target: self, action: s)
            b.bezelStyle = .rounded; b.controlSize = .small
            devFolders.addArrangedSubview(b)
        }
        devSection.addArrangedSubview(devFolders)
        let devBtns = NSStackView(); devBtns.orientation = .horizontal; devBtns.spacing = 6
        for (t, s) in [("Diagnostics", #selector(copyDiagnostics)),
                       ("Helper log", #selector(openHelperLog)),
                       ("Wake log", #selector(openWakeLog)),
                       ("DLL log", #selector(openDLLLog))] {
            let b = NSButton(title: t, target: self, action: s)
            b.bezelStyle = .rounded; b.controlSize = .small
            devBtns.addArrangedSubview(b)
        }
        devSection.addArrangedSubview(devBtns)
        let devTools = NSStackView(); devTools.orientation = .horizontal; devTools.spacing = 6
        recBtn = NSButton(title: "● Record session", target: self, action: #selector(toggleRecord))
        recBtn.bezelStyle = .rounded; recBtn.controlSize = .small
        devTools.addArrangedSubview(recBtn)
        let hc = NSButton(title: "Health check", target: self, action: #selector(healthCheckTapped))
        hc.bezelStyle = .rounded; hc.controlSize = .small
        devTools.addArrangedSubview(hc)
        // The same button as on Setup. Duplicated deliberately: this is where
        // someone already digging through logs expects to find it.
        let devReportBtn = NSButton(title: "Copy problem report", target: self, action: #selector(copyProblemReport))
        devReportBtn.bezelStyle = .rounded; devReportBtn.controlSize = .small
        devTools.addArrangedSubview(devReportBtn)
        devSection.addArrangedSubview(devTools)

        // Pen feel, precisely: the dropdown picks five presets, this exposes the
        // gamma itself with a live plot. Press the pen while the test is running
        // and the dot tracks the mapping, which beats reasoning about a number.
        let gRow = NSStackView(); gRow.orientation = .horizontal; gRow.spacing = 8
        gRow.alignment = .centerY
        gRow.addArrangedSubview(lbl("Pen feel curve", 11, bold: true))
        gammaSlider = NSSlider(value: PressureCore.pressureGamma, minValue: 0.0, maxValue: 2.50,
                               target: self, action: #selector(gammaSliderMoved))
        gammaSlider.controlSize = .small
        gammaSlider.widthAnchor.constraint(equalToConstant: 172).isActive = true
        gRow.addArrangedSubview(gammaSlider)
        // Sized for the longest value, "0.00 (no pressure)" (105 pt in bold 11).
        // The slider gave up the extra 18 so the row keeps its width.
        gammaLabel = lbl("", 11, bold: true)
        gammaLabel.widthAnchor.constraint(equalToConstant: 110).isActive = true
        gRow.addArrangedSubview(gammaLabel)
        curveView = GammaCurveView()
        curveView.widthAnchor.constraint(equalToConstant: 84).isActive = true
        curveView.heightAnchor.constraint(equalToConstant: 46).isActive = true
        gRow.addArrangedSubview(curveView)
        settingsTab.addArrangedSubview(gRow)
        let gHint = lbl("1.00 = what the tablet reports · below = lighter touch goes further · above = press harder · 0 = no pressure", 9, color: .tertiaryLabelColor)
        gHint.preferredMaxLayoutWidth = rowWidth
        settingsTab.addArrangedSubview(gHint)
        // The other two knobs of the feel (PressureCore.feel). Same row shape
        // as the curve so the three read as one control.
        func feelRow(_ title: String, _ min: Double, _ max: Double, _ sel: Selector) -> (NSSlider, NSTextField) {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
            row.alignment = .centerY
            let t = lbl(title, 11, bold: true)
            t.widthAnchor.constraint(equalToConstant: 108).isActive = true
            row.addArrangedSubview(t)
            let s = NSSlider(value: min, minValue: min, maxValue: max, target: self, action: sel)
            s.controlSize = .small
            s.widthAnchor.constraint(equalToConstant: 150).isActive = true
            row.addArrangedSubview(s)
            let l = lbl("", 11, bold: true)
            l.widthAnchor.constraint(equalToConstant: 150).isActive = true
            row.addArrangedSubview(l)
            settingsTab.addArrangedSubview(row)
            return (s, l)
        }
        (floorSlider, floorLabel) = feelRow("Ignore light touch", 0.0, 0.30, #selector(feelSliderMoved))
        (fullAtSlider, fullAtLabel) = feelRow("Full width at", 0.50, 1.0, #selector(feelSliderMoved))
        let wHint = lbl("below the first = ignored, for clean line starts · at the second = full width, without pressing all the way", 9, color: .tertiaryLabelColor)
        wHint.preferredMaxLayoutWidth = rowWidth
        settingsTab.addArrangedSubview(wHint)
        testBtn = NSButton(title: "Test pen", target: self, action: #selector(testTapped))
        testBtn.bezelStyle = .rounded; testBtn.controlSize = .small
        settingsTab.addArrangedSubview(testBtn)
        // TWO bars, one button. The question is never "what is being sent" or
        // "what is being received" on its own — it is whether the second bar
        // follows the first, and only one stroke seen in both places answers
        // it. In #29 the top bar moved perfectly and the bottom one would have
        // sat at zero, which is the entire report in one glance.
        sentCaption = lbl("sending", 9, color: .tertiaryLabelColor)
        sentCaption.isHidden = true
        settingsTab.addArrangedSubview(sentCaption)
        settingsTab.addArrangedSubview(barRow)
        recvCaption = lbl("receiving", 9, color: .tertiaryLabelColor)
        recvCaption.isHidden = true
        settingsTab.addArrangedSubview(recvCaption)
        recvRow = NSStackView(); recvRow.orientation = .horizontal
        recvRow.alignment = .centerY; recvRow.spacing = 10
        recvBar = PressureBar()
        recvBar.widthAnchor.constraint(equalToConstant: 240).isActive = true
        recvBar.heightAnchor.constraint(equalToConstant: 12).isActive = true
        recvLabel = lbl("", 11, bold: true)
        recvLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        recvRow.addArrangedSubview(recvBar); recvRow.addArrangedSubview(recvLabel)
        recvRow.isHidden = true
        settingsTab.addArrangedSubview(recvRow)
        settingsTab.addArrangedSubview(testHint)
        probeHint = lbl("", 10, color: .secondaryLabelColor)
        probeHint.preferredMaxLayoutWidth = rowWidth
        probeHint.isHidden = true
        settingsTab.addArrangedSubview(probeHint)

        // The scratch pad is NOT here on purpose. It repeatedly cost the pen
        // settings their place on this tab — most recently by absorbing the
        // stack's layout in a way that pushed them out — and the settings
        // matter more than a nice-to-have preview of the pen feel. The
        // PenScratchView class is kept because it works and may find a better
        // home (its own tab, or a sheet), but nothing on this tab uses it.

        // No Clear button: strokes fade on their own, so the pad is always ready.
        // Live console: the tail of the wake log, so you can watch auto-wake and
        // setup decisions without leaving the window.
        consoleScroll = NSScrollView()
        consoleScroll.hasVerticalScroller = true
        consoleScroll.borderType = .bezelBorder
        consoleScroll.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        consoleScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        console = NSTextView()
        console.isEditable = false
        console.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        console.autoresizingMask = [.width]
        consoleScroll.documentView = console
        devSection.addArrangedSubview(consoleScroll)
        // Deliberately NOT added to `content` any more — it lives in its own tab.
        devSection.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)

        // --- version + update check ------------------------------------------
        let verRow = NSStackView(); verRow.orientation = .horizontal; verRow.alignment = .centerY; verRow.spacing = 8
        versionLabel = lbl("Version \(currentVersion())", 10, color: .tertiaryLabelColor)
        updateLabel = lbl("", 10, color: .secondaryLabelColor)
        // if the label ever gets long again, truncate it with "…" instead of
        // stretching the row / squeezing the button off the window
        updateLabel.lineBreakMode = .byTruncatingTail
        updateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Two buttons, because they answer different questions: "install it"
        // and "what is it". One button that did both meant the only way to
        // update was to go and read a web page first.
        notesBtn = NSButton(title: "What's new", target: self, action: #selector(openReleasePage))
        notesBtn.bezelStyle = .rounded; notesBtn.controlSize = .small; notesBtn.isHidden = true
        updateBtn = NSButton(title: "Update now", target: self, action: #selector(updateNowTapped))
        updateBtn.bezelStyle = .rounded
        updateBtn.controlSize = .small
        updateBtn.isHidden = true
        verRow.addArrangedSubview(versionLabel)
        verRow.addArrangedSubview(updateLabel)
        verRow.addArrangedSubview(notesBtn)
        verRow.addArrangedSubview(updateBtn)
        content.addArrangedSubview(verRow)

        // Reset and Uninstall are installation actions, so they live on Setup
        // with Launch and Wake — not on Pen, which is about how the pen behaves.
        // Inserted after the secondary action row rather than appended, which
        // would strand them below the footers and the version line.
        if let after = content.arrangedSubviews.firstIndex(of: secondaryRow) {
            content.insertArrangedSubview(scratchRow, at: after + 1)
        } else {
            content.addArrangedSubview(scratchRow)
        }
        content.setCustomSpacing(16, after: secondaryRow)

        buildRecordingTab()

        // Three tabs rather than one column. Setup, recording and developer
        // tools are unrelated concerns, and stacking them meant scrolling past
        // all of them to reach any one.
        tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        // Recording is about what is happening now; Timelapses is what has
        // accumulated. Keeping them apart matters because the recording status
        // line is the most important text in the window and should not have to
        // compete with a scrolling list.
        for (label, view) in [("Setup", content!),
                              ("Pen", settingsTab!),
                              // Its own tab, not a corner of Pen or Advanced:
                              // it is where people look when Alt does nothing.
                              ("Keys", buildKeysTab()),
                              ("Recording", recordingTab!),
                              ("Videos", buildLibraryTab()),
                              ("Advanced", devSection!)] {
            // NSTabViewItem positions its view with the autoresizing mask, not
            // constraints. Leaving translatesAutoresizingMaskIntoConstraints
            // false gave every tab a zero-sized stack: the controls were all
            // there and unhidden, but laid out at (0,0,0,0). The only thing
            // that showed was the scratch pad, which has explicit size
            // constraints — and with a zero-bounds parent, nothing clipped it,
            // so it drew over the whole window.
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = [.width, .height]
            let item = NSTabViewItem(identifier: label)
            item.label = label
            item.view = view
            tabView.addTabViewItem(item)
        }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: rowWidth + 48, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SAI Pen Pressure"
        window.contentView = tabView
        // Delegate assigned only now: addTabViewItem() above selects a tab
        // synchronously, and reacting to that before the window exists is what
        // crashed on launch.
        tabView.delegate = self
        window.isReleasedWhenClosed = false
        if let src = ProcessInfo.processInfo.environment["SAIPP_TEST_UPDATE"] {
            let r = updateSAIFromFolder(src)
            try? (r ?? "OK").write(toFile: "/tmp/updresult.txt", atomically: true, encoding: .utf8)
            exit(0)
        }
        applyLayout()               // sizes the window to whichever tier is showing
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc func toggleAdvanced() {
        advanced.toggle()
        if !advanced { stopTest() }
        applyLayout()
    }
    @objc func toggleDevCheck() {
        devMode = (devCheck.state == .on)      // persists + rebuilds the menus
        applyLayout()
    }

    /// Show only what the current tier needs, then shrink/grow the window to fit.
    /// Simple mode hides any requirement that's already satisfied — a finished
    /// setup collapses to a title, one status line and the Launch button.
    func applyLayout() {
        // addTabViewItem() selects the first tab immediately, which fires
        // tabView(_:didSelect:) -> applyLayout() while buildWindow() is still
        // running and `window` is nil. Force-unwrapping it there crashed the app
        // on launch. Cheap guard, and it also covers any future early caller.
        guard window != nil else { return }
        for (i, r) in reqs.enumerated() {
            let ok = r.ok()
            rowViews[i].isHidden = advanced ? false : ok
        }
        // In Simple mode a finished setup hides every row, which left a blank
        // gap. Fill it with an explicit green confirmation of what's ready.
        let done = reqs.filter { $0.ok() }.count
        // The automatic path is only worth offering while something is missing.
        let needsWork = reqs.contains { $0.required && !$0.ok() }
        autoBtn.isHidden = !needsWork || autoRunning
        launchBtn.isHidden = needsWork && !autoRunning
        if !advanced && done == reqs.count {
            allSetLabel.stringValue = "✅ Wine · SAI installed · License · Input Monitoring · all ready"
            allSetLabel.isHidden = false
        } else if !advanced && done > 0 {
            allSetLabel.stringValue = "✅ \(done) of \(reqs.count) ready"
            allSetLabel.isHidden = false
        } else {
            allSetLabel.isHidden = true
        }
        footerLabels.forEach { $0.isHidden = !advanced }
        // devSection lives in its own tab now; never hide it wholesale.
        devCheck.state = devMode ? .on : .off
        consoleScroll.isHidden = !devMode
        devSection.arrangedSubviews.forEach {
            if $0 !== devCheck && !devUpdateRows.contains($0) { $0.isHidden = !devMode }
        }
        autoWakeCheck?.state = autoWake ? .on : .off
        advancedBtn.title = advanced ? "Show all steps ⌃" : "Show all steps ⌄"
        if devMode && advanced { updateConsole() }
        window.layoutIfNeeded()
        // Measure the tab actually on screen: the tabs differ a lot in height,
        // and sizing to Setup while Developer is showing clips the console.
        let shown = (tabView?.selectedTabViewItem?.view as? NSStackView) ?? content
        let fit = shown!.fittingSize
        // The tab bar and its insets are NOT part of the tab's content area, so
        // sizing the window to the stack's fittingSize alone left the bottom of
        // every tab clipped by roughly the height of the tab strip.
        var chromeW: CGFloat = 0, chromeH: CGFloat = 0
        if let tv = tabView {
            chromeW = max(0, tv.frame.width - tv.contentRect.width)
            chromeH = max(0, tv.frame.height - tv.contentRect.height)
        }
        // A couple of points of slack. Measuring chrome from the current frame
        // is inherently one layout behind, and being even slightly short is not
        // a cosmetic problem — the stack compresses its contents to fit.
        let want = NSSize(width: max(rowWidth + 48, fit.width + chromeW),
                          height: fit.height + chromeH + 4)
        // Only resize on a real change — applyLayout() runs from the 1s refresh
        // timer, and setting the same size every tick makes the window shimmer.
        if abs(window.contentLayoutRect.height - want.height) > 0.5
            || abs(window.contentLayoutRect.width - want.width) > 0.5 {
            window.setContentSize(want)
        }
    }

    /// Tail of the wake log — the one that records setup, wake and auto-wake.
    func updateConsole() {
        guard let s = try? String(contentsOfFile: "/tmp/sai-wake.log", encoding: .utf8) else {
            console.string = "(no log yet. It appears once SAI is launched or a wake fires)"; return
        }
        let tail = s.split(separator: "\n").suffix(150).joined(separator: "\n")
        guard tail != console.string else { return }
        console.string = tail
        console.scrollToEndOfDocument(nil)
    }
}
