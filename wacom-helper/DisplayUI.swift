// DisplayUI.swift — the Display part of Advanced: sharp text on Retina
// screens (issue #39). Also SAI's UI language, which is built but HIDDEN.
//
// The language menu is switched off on purpose, not unfinished: in testing,
// Russian and Chinese did nothing in SAI Alpha 2026.07.27, and Japanese
// switched SAI over but drew every character as a box (no font Wine could
// give it; mapping Meiryo UI / MS UI Gothic to Hiragino did not help). The
// code is kept, and still unit-tested, for when that is solved. To bring it
// back: uncomment the langRow block in buildDisplaySection() and the
// applySAILanguage() call in prepareDisplaySettingsForLaunch().
//
// What the values mean and why off restores the old DPI is in DisplayCore.swift.
// This file is the settings files, getting them into Wine and sai2.ini, and the
// restart that both need.
//
// Restart, and not losing work: both settings are read when SAI starts, so a
// change while SAI is open asks first. "Close and reopen" sends SAI the same
// close message as its own close button (wine taskkill without /F), so SAI
// behaves exactly as if it were closed by hand. It is never killed.

import AppKit

// MARK: - settings files (Application Support, like every other setting)

/// "on" or "off". Missing means this app has never touched RetinaMode, so a
/// value someone set by hand (the #39 workaround) is left alone.
func retinaSettingFile() -> String { appSupport() + "/retina-mode.txt" }
/// The DPI from before Retina went on, to put back when it goes off.
func retinaPrevDPIFile() -> String { appSupport() + "/retina-prev-dpi.txt" }
/// The language menu's choice: a code, or "default". Missing means Default,
/// never changed: sai2.ini is left alone. See SAILanguageChoice.
func saiLanguageFile() -> String { appSupport() + "/sai-lang.txt" }
/// sai2.ini's lang from before this app first changed it, for Default.
func saiLanguageOriginalFile() -> String { appSupport() + "/sai-lang-original.txt" }
/// Present when Wine has to start fresh before the next SAI, because RetinaMode
/// changed. One-shot: removed once that has happened.
func wineRestartPendingFile() -> String { appSupport() + "/wine-restart-pending.txt" }
/// Present when the app was reopened to start SAI again (Close and reopen).
func relaunchSAIMarker() -> String { appSupport() + "/relaunch-sai.txt" }

private func readTrimmed(_ path: String) -> String? {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

/// nil = never set here.
func storedRetinaSetting() -> Bool? {
    switch readTrimmed(retinaSettingFile()) {
    case "on": return true
    case "off": return false
    default: return nil
    }
}

/// The raw stored choice: nil, "default", or a code.
func storedSAILanguageChoice() -> String? { readTrimmed(saiLanguageFile()) }

func prefixUserReg() -> String { (try? String(contentsOfFile: "\(appPrefix)/user.reg", encoding: .utf8)) ?? "" }
func prefixSystemReg() -> String { (try? String(contentsOfFile: "\(appPrefix)/system.reg", encoding: .utf8)) ?? "" }

/// What Wine has now, from the prefix's files. Wine writes them back a few
/// seconds after a change, so right after a click this can lag; the stored
/// setting is what the checkbox shows when there is one.
func retinaModeInWine() -> Bool { DisplayCore.retinaModeOn(userReg: prefixUserReg()) }

/// The language in the prefix's sai2.ini, if it can be read.
func saiLanguageInIni() -> String? {
    guard let d = FileManager.default.contents(atPath: "\(prefixSAIDir)/sai2.ini") else { return nil }
    return SAIIni.decode(d)?.language
}

// MARK: - getting the settings into Wine and SAI

/// Write RetinaMode and the DPI into the prefix. Only when this app owns the
/// setting (the file exists). "off" is written once and then forgotten, so a
/// DPI changed later in winecfg is not overwritten on every launch.
func applyRetinaToWine(_ wine: String) {
    guard let on = storedRetinaSetting(), !wine.isEmpty,
          FileManager.default.fileExists(atPath: appPrefix) else { return }
    let saved = readTrimmed(retinaPrevDPIFile()).flatMap { Int($0) }
    let env = ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"]
    for args in DisplayCore.regCommands(retinaOn: on, dpiWhenOff: DisplayCore.dpiToRestore(saved: saved)) {
        runProc(wine, args, env: env)
    }
    if !on {
        try? FileManager.default.removeItem(atPath: retinaSettingFile())
        try? FileManager.default.removeItem(atPath: retinaPrevDPIFile())
    }
}

/// Put the chosen language into sai2.ini. Only while SAI is closed: SAI reads
/// the file at start, and writing under a running SAI changes nothing.
func applySAILanguage() {
    let stored = storedSAILanguageChoice()
    guard stored != nil, !saiProcessRunning() else { return }
    let path = "\(prefixSAIDir)/sai2.ini"
    if let lang = SAILanguageChoice.iniTarget(stored: stored, original: readTrimmed(saiLanguageOriginalFile())),
       let d = FileManager.default.contents(atPath: path), let ini = SAIIni.decode(d),
       ini.language != lang {
        let out = ini.settingLanguage(lang).encoded()
        try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    // Back at Default and the old value is in: nothing left to manage, so the
    // app stops touching sai2.ini (an SAI update's own file is then left as is).
    if stored == SAILanguageChoice.defaultChoice {
        try? FileManager.default.removeItem(atPath: saiLanguageFile())
        try? FileManager.default.removeItem(atPath: saiLanguageOriginalFile())
    }
}

/// Called from launchSAIApp() before SAI starts.
///
/// THE TRAP: wineserver -k ends EVERY Windows program in the prefix. If SAI is
/// still running anywhere (minimised, on another Space, behind a save dialog),
/// that would close it without saving. So it only happens when no sai2.exe
/// process exists at all, not merely when no SAI window is on screen.
func prepareDisplaySettingsForLaunch(_ wine: String) {
    if FileManager.default.fileExists(atPath: wineRestartPendingFile()), !saiProcessRunning() {
        // RetinaMode is read when Wine's processes start, and the desktop
        // process can outlive SAI by a few seconds. A fresh Wine is the only
        // way to be sure the new mode is the one SAI gets.
        stopWineForPrefix(wine)
        try? FileManager.default.removeItem(atPath: wineRestartPendingFile())
    }
    applyRetinaToWine(wine)
    // Hidden with the language menu (see the top of this file). Off here too,
    // so a choice left over from a test build cannot change SAI's language.
    // applySAILanguage()
}

/// Set by Close and reopen: when SAI closes, reopen the app and start SAI again
/// instead of just quitting.
var g_reopenSAIAfterClose = false

/// Called on the way out once SAI has closed. True means: reopen the app and
/// start SAI. The marker is written HERE, at the moment SAI is gone, and not at
/// the click: if SAI's own save dialog was cancelled and it stayed open, a
/// marker from the click would make some later, unrelated app start launch SAI.
func takeReopenRequest() -> Bool {
    guard g_reopenSAIAfterClose else { return false }
    try? "".write(toFile: relaunchSAIMarker(), atomically: true, encoding: .utf8)
    return true
}

/// At app start: was this app reopened to start SAI again? Only a fresh marker
/// counts (a minute), so a crash between writing and reading it cannot start
/// SAI some day later. Removed either way.
func consumeRelaunchSAIMarker() -> Bool {
    let path = relaunchSAIMarker()
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
    try? FileManager.default.removeItem(atPath: path)
    let age = Date().timeIntervalSince((attrs[.modificationDate] as? Date) ?? .distantPast)
    return age >= 0 && age < 60
}

/// Ask SAI to close the way its own close button does. No /F: SAI gets
/// WM_CLOSE and handles unsaved work itself, exactly as when closed by hand.
func askSAIToClose(_ wine: String) {
    guard !wine.isEmpty else { return }
    DispatchQueue.global(qos: .userInitiated).async {
        runProc(wine, ["taskkill", "/im", "sai2.exe"],
                env: ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"])
    }
}

// MARK: - the controls

extension SetupController {

    func buildDisplaySection() -> NSStackView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6

        box.addArrangedSubview(lbl("Display", 11, bold: true))
        retinaCheck = NSButton(checkboxWithTitle: "Sharp text on Retina screens",
                               target: self, action: #selector(retinaToggled))
        box.addArrangedSubview(retinaCheck)
        let hint = lbl("SAI is drawn at full Retina resolution and Windows text size is set to 200%. "
                       + "If SAI looks too small or too big, set Window › Scaling of User Interface to Auto.",
                       10, color: .tertiaryLabelColor)
        hint.preferredMaxLayoutWidth = rowWidth
        hint.lineBreakMode = .byWordWrapping
        hint.usesSingleLineMode = false
        box.addArrangedSubview(hint)

        // Language menu, hidden (see the top of this file).
        // let langRow = NSStackView()
        // langRow.orientation = .horizontal
        // langRow.alignment = .centerY
        // langRow.spacing = 8
        // langRow.addArrangedSubview(lbl("SAI language", 11))
        // saiLangPopup = NSPopUpButton()
        // saiLangPopup.controlSize = .small
        // // Default first and selected on a fresh install: SAI's own setting.
        // saiLangPopup.addItem(withTitle: "Default")
        // saiLangPopup.lastItem?.representedObject = SAILanguageChoice.defaultChoice
        // for l in SAILanguage.allCases {
        //     saiLangPopup.addItem(withTitle: l.label)
        //     saiLangPopup.lastItem?.representedObject = l.rawValue
        // }
        // saiLangPopup.target = self
        // saiLangPopup.action = #selector(saiLanguageChanged)
        // langRow.addArrangedSubview(saiLangPopup)
        // box.addArrangedSubview(langRow)

        displayRestartNote = lbl("", 11, bold: true, color: .systemOrange)
        displayRestartNote.preferredMaxLayoutWidth = rowWidth
        displayRestartNote.lineBreakMode = .byWordWrapping
        displayRestartNote.usesSingleLineMode = false
        displayRestartNote.isHidden = true
        box.addArrangedSubview(displayRestartNote)

        refreshDisplaySection()
        return box
    }

    /// The controls show the stored choice if there is one, otherwise what the
    /// prefix has now.
    func refreshDisplaySection() {
        guard retinaCheck != nil else { return }
        retinaCheck.state = (storedRetinaSetting() ?? retinaModeInWine()) ? .on : .off
        if saiLangPopup != nil {      // nil while the language menu is hidden
            let choice = storedSAILanguageChoice() ?? SAILanguageChoice.defaultChoice
            let i = saiLangPopup.indexOfItem(withRepresentedObject: choice)
            saiLangPopup.selectItem(at: i >= 0 ? i : 0)
            saiLangPopup.isEnabled = saiInstalledInPrefix()
        }
        refreshDisplayRestartNote()
    }

    /// Shown only while it is true, and gone by itself once SAI has closed.
    /// Cheap (one pgrep), so the once-a-second refresh calls this and not the
    /// whole section, which reads Wine's registry files.
    func refreshDisplayRestartNote() {
        guard displayRestartNote != nil else { return }
        if displayNeedsSAIRestart && !saiProcessRunning() { displayNeedsSAIRestart = false }
        let show = displayNeedsSAIRestart
        displayRestartNote.stringValue = show
            ? "SAI is open with the old display settings. Save your work, quit SAI and launch it again."
            : ""
        if displayRestartNote.isHidden == show {
            displayRestartNote.isHidden = !show
            applyLayout()
        }
    }

    @objc func retinaToggled() {
        let on = retinaCheck.state == .on
        confirmDisplayChange(revert: { [weak self] in self?.refreshDisplaySection() }) {
            if on {
                // Remember the DPI from before, once (see DisplayCore's trap).
                let saved = (try? String(contentsOfFile: retinaPrevDPIFile(), encoding: .utf8))
                    .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                let keep = DisplayCore.dpiToRemember(
                    alreadySaved: saved,
                    current: DisplayCore.currentDPI(userReg: prefixUserReg(), systemReg: prefixSystemReg()))
                try? "\(keep)".write(toFile: retinaPrevDPIFile(), atomically: true, encoding: .utf8)
            }
            try? (on ? "on" : "off").write(toFile: retinaSettingFile(), atomically: true, encoding: .utf8)
            try? "".write(toFile: wineRestartPendingFile(), atomically: true, encoding: .utf8)
            // Into Wine straight away, like the Keys tab, so SAI started any
            // other way gets it too. Launch writes it again either way.
            let wine = g_wine.isEmpty ? (wineBin() ?? "") : g_wine
            DispatchQueue.global(qos: .userInitiated).async { applyRetinaToWine(wine) }
        }
    }

    @objc func saiLanguageChanged() {
        guard let code = saiLangPopup.selectedItem?.representedObject as? String else { return }
        // Same choice again, or Default when nothing was ever changed: no
        // change, so no restart to ask about.
        if code == (storedSAILanguageChoice() ?? SAILanguageChoice.defaultChoice) { return }
        confirmDisplayChange(revert: { [weak self] in self?.refreshDisplaySection() }) {
            if code != SAILanguageChoice.defaultChoice {
                let keep = SAILanguageChoice.originalToRemember(
                    alreadySaved: readTrimmed(saiLanguageOriginalFile()), iniNow: saiLanguageInIni())
                try? keep.write(toFile: saiLanguageOriginalFile(), atomically: true, encoding: .utf8)
            }
            try? code.write(toFile: saiLanguageFile(), atomically: true, encoding: .utf8)
            applySAILanguage()      // now if SAI is closed, otherwise at the next launch
        }
    }

    /// Both settings need SAI to start again. With SAI closed there is nothing
    /// to ask. With SAI open, say so BEFORE changing anything, so nobody loses
    /// a drawing to a setting.
    private func confirmDisplayChange(revert: @escaping () -> Void, apply: @escaping () -> Void) {
        guard saiProcessRunning() else {
            apply()
            refreshDisplaySection()
            return
        }
        let a = NSAlert()
        a.messageText = "SAI has to restart for this"
        a.informativeText = "Save your drawings in SAI first.\n\n"
            + "Close and reopen closes SAI like its own close button does, then opens it again. "
            + "Later keeps SAI open and applies the change the next time it starts."
        a.addButton(withTitle: "Close and reopen SAI")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            apply()
            displayNeedsSAIRestart = true
            g_reopenSAIAfterClose = true
            askSAIToClose(g_wine.isEmpty ? (wineBin() ?? "") : g_wine)
            // The app quits when SAI closes; with the flag set it reopens
            // instead. Watch here too, in case this app did not start SAI.
            pollUntilSAICloses()
        case .alertSecondButtonReturn:
            apply()
            displayNeedsSAIRestart = true
        default:
            revert()
            return
        }
        refreshDisplaySection()
    }
}
