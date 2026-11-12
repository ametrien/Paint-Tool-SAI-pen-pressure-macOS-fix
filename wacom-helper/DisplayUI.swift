// DisplayUI.swift — the Display part of Advanced: sharp text on Retina
// screens (issue #39), and the Language dropdown: SAI's menu language
// (sai2.ini, English or Japanese, the only two SAI has) together with the font
// for Chinese, Japanese and Korean text (FontLinkCore.swift).
//
// History: a language menu was built earlier and hidden, because Japanese drew
// every character as a box and other codes did nothing. The boxes were Wine's
// fallback lists naming only Windows fonts (FontLinkCore.swift); "other codes"
// do not exist in sai2.exe (DisplayCore.swift, SAILanguage).
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
import CoreText
import UniformTypeIdentifiers

// MARK: - settings files (Application Support, like every other setting)

/// "on" or "off". Missing means never set here: Wine is left alone.
func retinaSettingFile() -> String { appSupport() + "/retina-mode.txt" }
/// The DPI from before Retina went on, to put back when it goes off.
func retinaPrevDPIFile() -> String { appSupport() + "/retina-prev-dpi.txt" }
/// The language menu's choice: a code, or "default". Missing means Default,
/// never changed: sai2.ini is left alone. See SAILanguageChoice.
func saiLanguageFile() -> String { appSupport() + "/sai-lang.txt" }
/// sai2.ini's lang from before this app first changed it, for Default.
func saiLanguageOriginalFile() -> String { appSupport() + "/sai-lang-original.txt" }
/// The font choice for Chinese, Japanese and Korean text, one line
/// (FontLinkCore.Choice.stored). Missing means Automatic.
func cjkFontsSettingFile() -> String { appSupport() + "/cjk-fonts.txt" }
/// Every font of the person's own ever put into Wine's lists, one entry per
/// line, so Off and later choices can take them out (FontLinkCore.remembering).
func cjkFontsChosenFile() -> String { appSupport() + "/cjk-fonts-chosen.txt" }
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

func storedCJKChoice() -> FontLinkCore.Choice { FontLinkCore.Choice(stored: readTrimmed(cjkFontsSettingFile())) }

func rememberedCJKEntries() -> [String] {
    (readTrimmed(cjkFontsChosenFile()) ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
}

/// Wine's own fonts folder, next to the wine binary (bin/wine -> share/wine/fonts).
func wineFontsDir() -> String? {
    let w = g_wine.isEmpty ? (wineBin() ?? "") : g_wine
    guard !w.isEmpty else { return nil }
    return URL(fileURLWithPath: w).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("share/wine/fonts").path
}

func fontSearchDirs() -> [String] {
    FontLinkCore.fontDirs(home: NSHomeDirectory(), wineFontsDir: wineFontsDir()) {
        (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []
    }
}

/// Where a font is on this Mac, for showing and Copy path. Only looked up,
/// never opened here.
func pathOfFont(_ f: FontLinkCore.LinkFont, in dirs: [String]) -> String? {
    dirs.map { $0 + "/" + f.file }.first { FileManager.default.fileExists(atPath: $0) }
}

/// The person's own installed fonts that have Chinese, Japanese or Korean, each
/// under the family name Wine matches (read from the file, FontLinkCore
/// THE TRAP 1). A font Wine's own lists already name is left out (canOffer).
func installedCJKFonts(wineEntries: [String]) -> [(font: FontLinkCore.LinkFont, path: String)] {
    var out: [(font: FontLinkCore.LinkFont, path: String)] = []
    for dir in FontLinkCore.installedFontDirs(home: NSHomeDirectory()) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
        for name in names where FontLinkCore.fontFileExtensions.contains((name as NSString).pathExtension.lowercased()) {
            let url = URL(fileURLWithPath: dir + "/" + name)
            let descs = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []
            let langs = descs.flatMap { (CTFontDescriptorCopyAttribute($0, kCTFontLanguagesAttribute) as? [String]) ?? [] }
            guard langs.contains(where: { $0.hasPrefix("ja") || $0.hasPrefix("zh") || $0.hasPrefix("ko") }),
                  !name.contains(","), !name.contains("\\"),
                  let data = try? Data(contentsOf: url, options: .alwaysMapped) else { continue }
            for family in FontLinkCore.gdiFamilies(fontData: data) {
                let f = FontLinkCore.LinkFont(file: name, family: family)
                if FontLinkCore.canOffer(f, wineEntries: wineEntries), !out.contains(where: { $0.font == f }) {
                    out.append((f, url.path))
                }
            }
        }
    }
    return out
}

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

/// What has to happen in Wine for the switch's current state.
func retinaPlan() -> DisplayCore.Plan {
    DisplayCore.plan(wantOn: DisplayCore.wanted(stored: storedRetinaSetting(), wineHasFix: wineHasRetinaFix()),
                     wineOn: retinaModeInWine())
}

/// Write RetinaMode and the DPI into the prefix, as retinaPlan() says. The
/// DPI from before is remembered here, the first time Retina goes on, which
/// for most people is the first launch after updating, not a click.
///
/// The "before" DPI is kept after switching off too: user.reg can lag a
/// moment behind a write, so the same switch can be applied twice, and the
/// second time must still find the right value to put back.
func applyRetinaToWine(_ wine: String) {
    guard !wine.isEmpty, FileManager.default.fileExists(atPath: "\(appPrefix)/user.reg") else { return }
    let plan = retinaPlan()
    guard let on = plan.write else { return }
    let saved = readTrimmed(retinaPrevDPIFile()).flatMap { Int($0) }
    if plan.rememberDPI {
        let keep = DisplayCore.dpiToRemember(
            alreadySaved: saved,
            current: DisplayCore.currentDPI(userReg: prefixUserReg(), systemReg: prefixSystemReg()))
        try? "\(keep)".write(toFile: retinaPrevDPIFile(), atomically: true, encoding: .utf8)
    }
    let env = ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"]
    for args in DisplayCore.regCommands(retinaOn: on, dpiWhenOff: DisplayCore.dpiToRestore(saved: saved)) {
        runProc(wine, args, env: env)
    }
}

/// Put the Mac's own fonts at the front of Wine's fallback lists for the fonts
/// SAI asks for, or take them out again (FontLinkCore.swift). Registry only:
/// no font file is copied, bundled or downloaded, ever.
///
/// SAI reads the lists when it starts, so a change reaches an open SAI only
/// after a restart. Writing while SAI runs is harmless. `force` is for a click:
/// system.reg can lag a few seconds behind Wine, so after a click every list is
/// written, not only the ones the file shows as different (see
/// FontLinkCore.changes). At launch only real differences are written, so a
/// normal launch starts no reg.exe.
func applyCJKFontsToWine(_ wine: String, force: Bool = false) {
    guard !wine.isEmpty else { return }
    let choice = storedCJKChoice()
    let changes = FontLinkCore.changes(current: FontLinkCore.systemLinks(systemReg: prefixSystemReg()),
                                       on: choice != .off,
                                       fonts: FontLinkCore.fonts(for: choice, preferredLanguages: Locale.preferredLanguages),
                                       remembered: rememberedCJKEntries(),
                                       force: force)
    let env = ["WINEPREFIX": appPrefix, "WINEDEBUG": "-all"]
    for c in changes { runProc(wine, FontLinkCore.regCommand(c), env: env) }
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
    // Our IOSurface Mac driver (removes the CPU re-draw that made drawing lag,
    // issue #39, WinePatch*.swift) unless the user removed it in Advanced ›
    // Wine. Only while no SAI runs, and Wine restarts after a swap so every
    // Wine process uses the same driver.
    if !saiProcessRunning(),
       syncWineMacDriver(wine, wantPatched: winePatchWanted()) {
        stopWineForPrefix(wine)
    }
    // A switch clicked earlier, or one Wine has not caught up with yet.
    let modeChanges = retinaPlan().restartWine
    if FileManager.default.fileExists(atPath: wineRestartPendingFile()) || modeChanges, !saiProcessRunning() {
        // RetinaMode is read when Wine's processes start, and the desktop
        // process can outlive SAI by a few seconds. A fresh Wine is the only
        // way to be sure the new mode is the one SAI gets.
        stopWineForPrefix(wine)
        try? FileManager.default.removeItem(atPath: wineRestartPendingFile())
    }
    applyRetinaToWine(wine)
    // Every launch: puts our fonts back if Wine rewrote a list, follows a new
    // language order on the Mac, and writes nothing when all is as it should be.
    applyCJKFontsToWine(wine)
    // The Language dropdown's menu language. Only en and ja are ever written
    // (SAILanguageChoice.iniTarget ignores any other stored code).
    applySAILanguage()
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
        // The warning about slower strokes is only true for a Wine WITHOUT the
        // fix (issue #39): with our patch or Wine 11.22+, sharp text draws
        // smoothly and is on by default. Reading the Wine's state costs a
        // version call, so it happens off the main thread and the hint catches
        // up a moment after the tab opens.
        displayHint = lbl("Sharper SAI on a Retina screen. "
                       + "In SAI, set Window › Scaling of User Interface to 200% with sharp text and 100% without, then restart SAI. "
                       + "Some small panel icons stay small at 200%. That is SAI's own icon art.",
                       10, color: .tertiaryLabelColor)
        displayHint.preferredMaxLayoutWidth = rowWidth
        displayHint.lineBreakMode = .byWordWrapping
        displayHint.usesSingleLineMode = false
        box.addArrangedSubview(displayHint)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let hasFix = wineHasRetinaFix()
            DispatchQueue.main.async {
                guard let self = self, self.displayHint != nil else { return }
                self.displayHint.stringValue = (hasFix
                    ? "Sharper SAI on a Retina screen, with no slowdown: your Wine has the fix for it. On by default. "
                    : "Better quality, but strokes will most likely show up slower with this Wine. "
                      + "Advanced › Wine can fix that. Off by default. ")
                    + "In SAI, set Window › Scaling of User Interface to 200% with sharp text and 100% without, then restart SAI. "
                       + "Some small panel icons stay small at 200%. That is SAI's own icon art."
                self.applyLayout()
            }
        }

        // Language: SAI's menus (English or Japanese) and the font for Chinese,
        // Japanese and Korean text, in one dropdown. Items are filled in by
        // refreshLanguageMenu(), which also finds the person's own fonts.
        let langRow = NSStackView()
        langRow.orientation = .horizontal
        langRow.alignment = .centerY
        langRow.spacing = 8
        langRow.addArrangedSubview(lbl("Language", 11))
        langPopup = NSPopUpButton()
        langPopup.controlSize = .small
        langPopup.autoenablesItems = false        // a font missing on this Mac is greyed out
        langPopup.target = self
        langPopup.action = #selector(languagePicked)
        langRow.addArrangedSubview(langPopup)
        box.addArrangedSubview(langRow)

        let pathRow = NSStackView()
        pathRow.orientation = .horizontal
        pathRow.alignment = .centerY
        pathRow.spacing = 6
        fontPathLabel = lbl("", 10, color: .secondaryLabelColor)
        fontPathLabel.isSelectable = true
        fontPathLabel.lineBreakMode = .byTruncatingMiddle
        fontPathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: rowWidth - 90).isActive = true
        fontPathLabel.toolTip = "The font file used for Chinese, Japanese and Korean text"
        fontCopyButton = NSButton(title: "Copy path", target: self, action: #selector(copyFontPath))
        fontCopyButton.controlSize = .small
        fontCopyButton.bezelStyle = .rounded
        pathRow.addArrangedSubview(fontPathLabel)
        pathRow.addArrangedSubview(fontCopyButton)
        box.addArrangedSubview(pathRow)

        let langHint = lbl("SAI's menus come in English and Japanese. For Chinese and Korean the menus stay "
                           + "in English and the font changes, so text like layer names shows instead of boxes. "
                           + "Uses fonts on your Mac, nothing is copied. A font you downloaded: Add a font. "
                           + "SAI's Text tool is not affected.",
                           10, color: .tertiaryLabelColor)
        langHint.preferredMaxLayoutWidth = rowWidth
        langHint.lineBreakMode = .byWordWrapping
        langHint.usesSingleLineMode = false
        box.addArrangedSubview(langHint)

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
        retinaCheck.state = (DisplayCore.wanted(stored: storedRetinaSetting(), wineHasFix: wineHasRetinaFix())
                             ?? retinaModeInWine()) ? .on : .off
        refreshLanguageMenu()
        refreshDisplayRestartNote()
    }

    /// The menu language shown: the stored choice, else what sai2.ini says.
    private func shownSAILanguage() -> String {
        let s = storedSAILanguageChoice()
        if let s = s, SAILanguage(rawValue: s) != nil { return s }
        return saiLanguageInIni() ?? "en"
    }

    /// Rebuilt every time: a font installed with Font Book meanwhile shows up.
    /// Each item's representedObject says what it does: "lang:N", a stored
    /// font Choice, "add" or "off".
    func refreshLanguageMenu() {
        guard let popup = langPopup, let menu = popup.menu else { return }
        let dirs = fontSearchDirs()
        let choice = storedCJKChoice()
        let remembered = rememberedCJKEntries()
        let wineOwn = FontLinkCore.wineEntries(FontLinkCore.systemLinks(systemReg: prefixSystemReg()), remembered: remembered)
        // NSMenu, not popup.addItem(withTitle:): that one drops an item with the
        // same title as an earlier one, and two fonts can share a family name.
        func add(_ title: String, _ key: String, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = key
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.removeAllItems()
        for (i, o) in FontLinkCore.languageOptions.enumerated() {
            add(o.title, "lang:\(i)", enabled: o.font.map { pathOfFont($0, in: dirs) != nil } ?? true)
        }
        var own = installedCJKFonts(wineEntries: wineOwn)
        // A chosen font that is gone still shows, so the menu says what is set.
        if case .font(let f, let path) = choice, !FontLinkCore.languageOptions.contains(where: { $0.font == f }),
           !own.contains(where: { $0.font == f }) {
            own.append((f, path))
        }
        if !own.isEmpty {
            menu.addItem(.separator())
            add("Your fonts", "", enabled: false)
            for o in own {
                let missing = !FileManager.default.fileExists(atPath: o.path)
                add(o.font.family + (missing ? " (not found)" : ""),
                    FontLinkCore.Choice.font(o.font, path: o.path).stored, enabled: !missing)
            }
        }
        menu.addItem(.separator())
        add("Add a font…", "add")
        add("Off", "off")

        let key: String
        switch FontLinkCore.selection(saiLanguage: shownSAILanguage(), font: choice) {
        case .language(let i): key = "lang:\(i)"
        case .font: key = choice.stored
        case .off: key = "off"
        }
        if let i = menu.items.firstIndex(where: { ($0.representedObject as? String) == key }) { popup.selectItem(at: i) }

        // The file in front, for the path line: built-in fonts are looked up
        // fresh (a macOS update can move PingFang), the person's own as chosen.
        let front = FontLinkCore.fonts(for: choice, preferredLanguages: Locale.preferredLanguages).first
        var path = ""
        if case .font(let f, let p) = choice, !FontLinkCore.isOurs(f.entry) { path = p }
        else if let f = front { path = pathOfFont(f, in: dirs) ?? "" }
        fontPathLabel.stringValue = path
        fontPathLabel.isHidden = path.isEmpty
        fontCopyButton.isHidden = path.isEmpty
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
            // The DPI from before is remembered in applyRetinaToWine().
            try? (on ? "on" : "off").write(toFile: retinaSettingFile(), atomically: true, encoding: .utf8)
            try? "".write(toFile: wineRestartPendingFile(), atomically: true, encoding: .utf8)
            // Into Wine straight away, like the Keys tab, so SAI started any
            // other way gets it too. Launch writes it again either way.
            let wine = g_wine.isEmpty ? (wineBin() ?? "") : g_wine
            DispatchQueue.global(qos: .userInitiated).async { applyRetinaToWine(wine) }
        }
    }

    @objc func languagePicked() {
        guard let key = langPopup.selectedItem?.representedObject as? String, !key.isEmpty else {
            refreshLanguageMenu(); return
        }
        if key == "add" { addFontPicked(); return }
        if key.hasPrefix("lang:"), let i = Int(key.dropFirst(5)), FontLinkCore.languageOptions.indices.contains(i) {
            let o = FontLinkCore.languageOptions[i]
            let path = o.font.flatMap { pathOfFont($0, in: fontSearchDirs()) }
            applyLanguageChoice(saiLanguage: o.saiLanguage, font: FontLinkCore.choice(for: o, path: path))
        } else {
            // "off", or one of the person's own fonts: SAI's menus stay as they are.
            applyLanguageChoice(saiLanguage: nil, font: FontLinkCore.Choice(stored: key))
        }
    }

    /// "Add a font…": a font file the person has. Wine only sees INSTALLED
    /// fonts, and this app never copies one, so a file that is not installed
    /// opens in Font Book for the person to install there.
    private func addFontPicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.font]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a font with Chinese, Japanese or Korean characters"
        guard panel.runModal() == .OK, let url = panel.url else { refreshLanguageMenu(); return }
        let folder = url.deletingLastPathComponent().path
        let installed = (FontLinkCore.installedFontDirs(home: NSHomeDirectory()) + ["/System/Library/Fonts"]).contains(folder)
        guard installed else {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Font Book.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
            note("Install the font first",
                 "Wine can only use fonts that are installed on your Mac. Font Book is opening with this font. "
                 + "Click Install there, then choose the font from the Language menu.")
            refreshLanguageMenu(); return
        }
        let wineOwn = FontLinkCore.wineEntries(FontLinkCore.systemLinks(systemReg: prefixSystemReg()),
                                               remembered: rememberedCJKEntries())
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let family = FontLinkCore.gdiFamilies(fontData: data).first,
              !url.lastPathComponent.contains(","), !url.lastPathComponent.contains("\\") else {
            note("This font cannot be used", "Its name could not be read from the file.")
            refreshLanguageMenu(); return
        }
        let f = FontLinkCore.LinkFont(file: url.lastPathComponent, family: family)
        guard FontLinkCore.canOffer(f, wineEntries: wineOwn) else {
            note("Wine already uses this font", "It is in Wine's own list for missing characters, so there is nothing to add.")
            refreshLanguageMenu(); return
        }
        applyLanguageChoice(saiLanguage: nil, font: .font(f, path: url.path))
    }

    private func note(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    @objc func copyFontPath() {
        let path = fontPathLabel.stringValue
        guard !path.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// Store and apply a Language choice. `saiLanguage` nil leaves SAI's menus
    /// as they are. Both are read when SAI starts, so an open SAI is asked
    /// about first (confirmDisplayChange).
    private func applyLanguageChoice(saiLanguage: String?, font: FontLinkCore.Choice) {
        let langChanges = saiLanguage != nil && saiLanguage != shownSAILanguage()
        if font == storedCJKChoice() && !langChanges { refreshLanguageMenu(); return }
        confirmDisplayChange(revert: { [weak self] in self?.refreshDisplaySection() }) {
            try? font.stored.write(toFile: cjkFontsSettingFile(), atomically: true, encoding: .utf8)
            if case .font(let f, _) = font {
                let r = FontLinkCore.remembering(f, in: rememberedCJKEntries())
                try? r.joined(separator: "\n").write(toFile: cjkFontsChosenFile(), atomically: true, encoding: .utf8)
            }
            if let lang = saiLanguage, langChanges {
                let keep = SAILanguageChoice.originalToRemember(
                    alreadySaved: readTrimmed(saiLanguageOriginalFile()), iniNow: saiLanguageInIni())
                try? keep.write(toFile: saiLanguageOriginalFile(), atomically: true, encoding: .utf8)
                try? lang.write(toFile: saiLanguageFile(), atomically: true, encoding: .utf8)
                applySAILanguage()      // now if SAI is closed, otherwise at the next launch
            }
            // Into Wine straight away, like the Retina switch; launch checks again.
            let wine = g_wine.isEmpty ? (wineBin() ?? "") : g_wine
            DispatchQueue.global(qos: .userInitiated).async { applyCJKFontsToWine(wine, force: true) }
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
