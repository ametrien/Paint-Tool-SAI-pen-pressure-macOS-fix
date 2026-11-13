// PenUI.swift — what the Pen tab does: pressure levels, pen feel and its
// profiles, and the two-bar pen test.
//
// Moved out of main.swift unchanged. The controls themselves are created in
// buildWindow() (SetupWindow.swift); this is what happens when they are used.
// The rules behind the feel menu are in PenFeelCore.swift and PopupMenuSync.swift,
// where they are unit-tested.

import AppKit
import Foundation

extension SetupController {

    /// Reflect the current setting and what the tablet says it can do.
    func refreshPressureUI() {
        guard pressurePopup != nil else { return }
        syncFeelControls()
        if let ov = storedMaxPressureOverride(),
           let idx = PressureCore.pressureChoices.firstIndex(of: ov) {
            pressurePopup.selectItem(at: idx + 1)
        } else {
            pressurePopup.selectItem(at: 0)                       // Auto
        }
        // Say WHY this number, and name the device it came from — otherwise
        // "4096" is just an unexplained figure, and with two tablets plugged in
        // there's no way to tell which one it came from.
        let all = tabletsForDisplay()
        let inUse = PressureCore.maxPressure + 1
        let auto = storedMaxPressureOverride() == nil
        switch all.count {
        case 0:
            // With nothing plugged in, `inUse` is usually the value REMEMBERED
            // from the last tablet, not a default. Calling it "the safe default"
            // hid the fact that the app was running on stale information — and
            // hid the more useful message, which is that no tablet is connected.
            if !auto {
                pressureInfo.stringValue = "set by you: \(inUse) · no tablet connected to check against"
            } else if let cached = cachedDetectedFullScale(), cached + 1 == inUse {
                pressureInfo.stringValue =
                    "⚠️ no tablet connected. Using \(inUse), remembered from the last one"
            } else {
                pressureInfo.stringValue =
                    "⚠️ no tablet connected. Using the safe default \(inUse)"
            }
        case 1:
            let t = all[0]
            guard let scale = t.fullScale else {
                // Connected, working, and silent about its range — a Wacom over
                // Bluetooth. No warning triangle: nothing is wrong, we simply
                // cannot ask, and the number in use is very likely right.
                pressureInfo.stringValue = auto
                    ? "\(t.name) connected. No range reported over Bluetooth, using \(inUse)"
                    : "set by you: \(inUse) · \(t.name) connected, no range reported over Bluetooth"
                break
            }
            pressureInfo.stringValue = auto
                ? "\(t.name) reports \(scale + 1) levels. Using that"
                : "set by you: \(inUse) · \(t.name) reports \(scale + 1)"
        default:
            let t = all[0]
            func describe(_ i: TabletInfo) -> String {
                i.fullScale.map { "\(i.name) \($0 + 1)" } ?? "\(i.name) (range unknown)"
            }
            let others = all.dropFirst().map(describe).joined(separator: ", ")
            guard let scale = t.fullScale else {
                pressureInfo.stringValue = auto
                    ? "\(all.count) tablets connected. None reports its range, using \(inUse). Connected: \(describe(t)), \(others)"
                    : "set by you: \(inUse) · connected: \(describe(t)), \(others)"
                break
            }
            pressureInfo.stringValue = auto
                ? "\(all.count) tablets connected. Following the highest, \(t.name) (\(scale + 1)). Also: \(others)"
                : "set by you: \(inUse) · connected: \(t.name) \(scale + 1), \(others)"
        }
    }

    @objc func pressureChoiceChanged() {
        let detected = detectTabletFullScale()
        let idx = pressurePopup.indexOfSelectedItem
        if idx == 0 {
            try? FileManager.default.removeItem(atPath: appSupport() + "/pmax.txt")   // back to Auto
        } else {
            let v = PressureCore.pressureChoices[idx - 1]
            // More levels than the hardware has is not more detail — it is the
            // same steps spread wider, so noise stops being quantised away.
            // That is exactly what produced wobbly stroke widths in testing.
            if let d = detected, v > d {
                let c = osa("button returned of (display dialog \"Your tablet reports \(d + 1) pressure levels.\n\nSetting \(v + 1) doesn't give finer control. The same hardware steps spread over a wider range, so noise shows up as wobbly stroke width.\n\nUse it anyway?\" buttons {\"Cancel\", \"Use anyway\"} default button \"Cancel\" with icon caution)")
                guard c == "Use anyway" else { refreshPressureUI(); return }
            }
            saveMaxPressure(v)
        }
        PressureCore.maxPressure = savedMaxPressure()
        writeMaxPressureForDLL()
        refreshPressureUI()
        alertUser("Pressure set to \(PressureCore.maxPressure + 1) levels.\n\nSAI reads this once when it starts, so quit SAI completely and relaunch it to apply.")
    }

    func currentFeel() -> PenFeel {
        PenFeel(gamma: PressureCore.pressureGamma,
                floor: PressureCore.feelFloor,
                fullAt: PressureCore.feelFullAt)
    }

    @objc func gammaSliderMoved() { feelSliderMoved() }

    @objc func feelSliderMoved() {
        func dp2(_ v: Double) -> Double { (v * 100).rounded() / 100 }   // 2dp, no jitter
        var f = PenFeel(gamma: dp2(gammaSlider.doubleValue),
                        floor: dp2(floorSlider.doubleValue),
                        fullAt: dp2(fullAtSlider.doubleValue))
        // The two ends must not meet: hold a gap open rather than flip to
        // Normal (which is what clamped() does to a corrupt FILE, but a slider
        // mid-drag deserves resistance, not a reset).
        if f.floor > f.fullAt - 0.2 { f.floor = dp2(f.fullAt - 0.2) }
        saveFeel(f)
        syncFeelControls()
    }

    private typealias FeelTag = PenFeelCore.Tag

    /// One source of truth for the popup, the three sliders and the plot.
    /// Called every second by refresh(), INCLUDING while the dropdown is open:
    /// see syncPopupMenu (PopupMenuSync.swift) for why the menu is not simply
    /// rebuilt here.
    func syncFeelControls() {
        let f = currentFeel()
        if gammaSlider != nil { gammaSlider.doubleValue = f.gamma }
        if gammaLabel != nil {
            let name = f.gamma < 0.005 ? "no pressure"
                : abs(f.gamma - 1.0) < 0.03 ? "linear" : (f.gamma < 1 ? "softer" : "firmer")
            gammaLabel.stringValue = String(format: "%.2f (%@)", f.gamma, name)
        }
        if floorSlider != nil {
            floorSlider.doubleValue = f.floor
            floorLabel.stringValue = f.floor < 0.005 ? "off"
                : String(format: "below %.0f%% force", f.floor * 100)
        }
        if fullAtSlider != nil {
            fullAtSlider.doubleValue = f.fullAt
            fullAtLabel.stringValue = f.fullAt > 0.995 ? "full force"
                : String(format: "%.0f%% force", f.fullAt * 100)
        }
        if curveView != nil { curveView.feel = f }
        guard feelPopup != nil else { return }

        let match = PenFeelCore.matchName(f, profiles: penProfiles)
        if let m = match, penProfiles.contains(where: { $0.name == m }) { selectedProfile = m }

        let m = PenFeelCore.menu(for: f, profiles: penProfiles, selectedProfile: selectedProfile)
        syncPopupMenu(feelPopup, m.entries, selectTag: m.selected)
    }

    @objc func feelChanged() {
        // No SAI restart needed anywhere here: the feel is applied on our side
        // before the value is sent.
        let tag = feelPopup.selectedItem?.tag ?? FeelTag.custom
        switch tag {
        case FeelTag.preset..<(FeelTag.preset + PenFeelCore.presets.count):
            selectedProfile = nil
            saveFeel(PenFeelCore.presets[tag - FeelTag.preset].feel)
        case FeelTag.profile..<(FeelTag.profile + penProfiles.count):
            let p = penProfiles[tag - FeelTag.profile]
            selectedProfile = p.name
            saveFeel(p.feel)
        case FeelTag.save:   saveProfileTapped()
        case FeelTag.update:
            if let sel = selectedProfile,
               let out = PenFeelCore.updating(penProfiles, name: sel, feel: currentFeel()) {
                penProfiles = out; savePenProfiles(out)
            }
        case FeelTag.rename: renameProfileTapped()
        case FeelTag.delete: deleteProfileTapped()
        default: break                                   // "Custom": already live
        }
        syncFeelControls()
    }

    private func askProfileName(_ prompt: String, start: String, renaming: String? = nil) -> String? {
        // One dialog, re-shown with the reason when the name is not usable, so
        // a slip never silently drops the save.
        var seed = start
        while true {
            guard let raw = osa("text returned of (display dialog \(osaQuote(prompt)) default answer \(osaQuote(seed)))")
            else { return nil }                                  // Cancel
            let name = PenFeelCore.cleanName(raw)
            guard let why = PenFeelCore.nameProblem(name, existing: penProfiles, renaming: renaming) else { return name }
            seed = name
            guard osa("button returned of (display dialog \(osaQuote(why)) buttons {\"Cancel\", \"Try again\"} default button \"Try again\" with icon caution)") == "Try again" else { return nil }
        }
    }

    func saveProfileTapped() {
        guard let name = askProfileName("Name this pen feel:", start: ""),
              let out = PenFeelCore.adding(penProfiles, name: name, feel: currentFeel()) else { return }
        penProfiles = out
        selectedProfile = PenFeelCore.cleanName(name)
        savePenProfiles(out)
        wlog("pen feel: profile saved: \(name)")
    }

    func renameProfileTapped() {
        guard let sel = selectedProfile,
              let name = askProfileName("Rename \"\(sel)\" to:", start: sel, renaming: sel),
              let out = PenFeelCore.renaming(penProfiles, from: sel, to: name) else { return }
        penProfiles = out
        selectedProfile = PenFeelCore.cleanName(name)
        savePenProfiles(out)
    }

    func deleteProfileTapped() {
        guard let sel = selectedProfile else { return }
        // The feel it described stays live, so deleting is safe to confirm
        // lightly: nothing about the pen changes, only the saved name goes.
        guard osa("button returned of (display dialog \(osaQuote("Delete the profile \"\(sel)\"?\n\nYour current pen feel stays as it is; only the saved profile goes.")) buttons {\"Cancel\", \"Delete\"} default button \"Cancel\")") == "Delete" else { return }
        penProfiles = PenFeelCore.deleting(penProfiles, name: sel)
        selectedProfile = nil
        savePenProfiles(penProfiles)
        wlog("pen feel: profile deleted: \(sel)")
    }

    @objc func clearSettingsScratch() { settingsScratch?.clear() }

    // Start/stop the live pressure test. Doubles as a real Input-Monitoring check:
    // if the tap can't be created, the permission isn't granted to this build yet.
    @objc func testTapped() {
        if testing { stopTest(); return }
        guard startPressureEngineOnce() else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            alertUser("Couldn't read the tablet yet.\n\nIn System Settings → Privacy & Security → Input Monitoring, turn ON \"SAI Pen Pressure\", then reopen this app and try Test again.")
            return
        }
        testing = true
        testPeakSeen = 0
        g_rawSeen.removeAll()          // fresh census per test run
        testBtn.title = "Stop Test"
        testHint.isHidden = false; barRow.isHidden = false
        sentCaption.isHidden = false
        // The far side, running for as long as the test does. Best effort: no
        // Wine, or a prefix never set up, leaves the second bar empty with a
        // sentence saying why rather than blocking the pen test that works.
        recvRow.isHidden = false; recvCaption.isHidden = false
        recvBar.value = 0
        recvLabel.stringValue = "starting…"
        // No sentence unless something is WRONG. Working, or simply waiting for
        // the pen, is already what the two bars say; a line of prose that has
        // to be kept in step with them is one more thing that can be out of
        // date — and was, sitting under 1134 arrived packets insisting none
        // had arrived.
        probeHint.isHidden = true
        if let w = wineBin() {
            probeStream.onTick = { [weak self] t in
                guard let self = self else { return }
                let maxP = PressureCore.maxPressure
                self.recvBar.value = CGFloat(t.pressure) / CGFloat(maxP)
                self.recvLabel.stringValue = "\(t.fetched) pkt · peak \(t.pmax)"
            }
            probeStream.onVerdict = { [weak self] v, pr in
                guard let self = self else { return }
                switch v {
                case .working, .noPackets:
                    // The bars are the report. Nothing to add.
                    self.probeHint.isHidden = true
                default:
                    // A fault the bars CANNOT show — above all #29, where the
                    // receiving bar stays empty and only this line can say why.
                    self.probeHint.isHidden = false
                    self.probeHint.stringValue = BridgeCheck.explainProbe(v, pr)
                    // ...and stop the receiving side reading "starting…", which
                    // is what it said for as long as the fault lasted, implying
                    // the test had hung rather than answered.
                    self.recvBar.value = 0
                    self.recvLabel.stringValue = "nothing"
                }
            }
            probeStream.start(w)
        } else {
            probeHint.isHidden = false
            probeHint.stringValue = "Install Wine to see what SAI would receive."
        }
        settingsScratch?.clear()
        applyLayout()
        // fast (~60fps), .common-mode timer so the bar tracks the pen instantly and
        // keeps updating even while the window is being interacted with. The bar is
        // custom-drawn (no easing), so it jumps to the real value like the % does.
        let t = Timer(timeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let p = max(0, lastKeyP)                 // lastKeyP is -1 until a pen is first seen
            let maxP = PressureCore.maxPressure
            self.pressureBar.value = CGFloat(p) / CGFloat(maxP)
            // raw / full-scale, then percent — so the actual level count is visible
            self.pressureLabel.stringValue = "\(p) / \(maxP)   (\(Int((Double(p) / Double(maxP) * 100).rounded()))%)"
            if p > self.testPeakSeen { self.testPeakSeen = p }
            if self.curveView != nil { self.curveView.live = g_lastRawPressure }
            // RAW is what the tablet reported; distinct-raw is the empirical read
            // of its true resolution. If distinct stops climbing well below the
            // configured levels, the extra range is upsampling, not detail.
            // The instantaneous raw float used to be printed here too, and it
            // read 0.000000 nearly always: hover samples carry no pressure and
            // zero it between the ones that do, so it looked like the tablet
            // was reporting nothing while the bar beside it moved. The distinct
            // count is the number worth having anyway, being an empirical read
            // of the tablet's real resolution.
            self.testHint.stringValue = String(
                format: "sending %d levels · peak %d · %d distinct raw values seen",
                maxP + 1, self.testPeakSeen, g_rawSeen.count)
        }
        RunLoop.main.add(t, forMode: .common)
        testTimer = t
    }

    func stopTest() {
        testing = false
        testTimer?.invalidate(); testTimer = nil
        probeStream.stop()
        if testBtn != nil { testBtn.title = "Test pen" }
        if testHint != nil { testHint.isHidden = true }
        if barRow != nil { barRow.isHidden = true }
        if recvRow != nil { recvRow.isHidden = true }
        if recvCaption != nil { recvCaption.isHidden = true }
        if sentCaption != nil { sentCaption.isHidden = true }
        if probeHint != nil { probeHint.isHidden = true }
        applyLayout()
    }
}
