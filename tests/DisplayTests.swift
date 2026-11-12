// DisplayTests.swift — unit tests for DisplayCore (Retina mode, DPI, SAI language).

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String,
            file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

@main
struct DisplayTests {
    static func main() {
        print("DisplayCore tests:")

        // --- reading Wine's registry files ------------------------------------
        // Shaped like the real files: doubled backslashes, a timestamp after the
        // key, a #time line, and look-alike values in other sections.
        let userReg = """
        WINE REGISTRY Version 2

        [Control Panel\\\\Desktop] 1789057676
        #time=1dd4141578c3378
        "DragFullWindows"="0"
        "LogPixels"=dword:00000078

        [Software\\\\Wine\\\\Mac Driver] 1793896951
        #time=1dd6d44a6ab531a
        "LeftCommandIsCtrl"="Y"
        "RetinaMode"="y"

        [Software\\\\Wine\\\\Mac Driver\\\\Cursors] 1793896951
        "RetinaMode"="n"
        """
        expect(DisplayCore.retinaModeOn(userReg: userReg), "user.reg: RetinaMode=y is read as on")
        expect(DisplayCore.regValue(userReg, key: "Software\\Wine\\Mac Driver", name: "RetinaMode") == "y",
               "user.reg: the Mac Driver section is read, not its Cursors subkey")
        expect(!DisplayCore.retinaModeOn(userReg: userReg.replacingOccurrences(of: "\"RetinaMode\"=\"y\"", with: "")),
               "user.reg: no RetinaMode means off (Wine's default)")
        for v in ["Y", "yes", "true", "1"] {
            expect(DisplayCore.retinaModeOn(userReg: userReg.replacingOccurrences(of: "=\"y\"", with: "=\"\(v)\"")),
                   "user.reg: \"\(v)\" is on, as Wine reads it")
        }
        expect(!DisplayCore.retinaModeOn(userReg: userReg.replacingOccurrences(of: "=\"y\"", with: "=\"n\"")),
               "user.reg: \"n\" is off")

        expect(DisplayCore.dword("dword:000000c0") == 192, "dword: hex is read (c0 = 192)")
        expect(DisplayCore.dword("\"96\"") == nil, "dword: a string value is not a dword")

        // The real system.reg stores HKCC under ControlSet001 (seen in a prefix).
        let systemReg = """
        [System\\\\ControlSet001\\\\Hardware Profiles\\\\Current\\\\Software\\\\Fonts] 1789057675
        "FONTS.FON"="vgasys.fon"
        "LogPixels"=dword:00000060
        """
        expect(DisplayCore.currentDPI(userReg: userReg, systemReg: systemReg) == 120,
               "DPI: the user's value wins over the machine's (what Wine reads first)")
        expect(DisplayCore.currentDPI(userReg: "", systemReg: systemReg) == 96,
               "DPI: falls back to the machine value in ControlSet001")
        expect(DisplayCore.currentDPI(userReg: "", systemReg: "") == nil, "DPI: nothing set gives nil")

        // --- THE TRAP: off must give back the DPI from before -----------------
        expect(DisplayCore.dpiToRemember(alreadySaved: nil, current: 120) == 120,
               "remember: a custom 125% is kept for later")
        expect(DisplayCore.dpiToRemember(alreadySaved: nil, current: nil) == 96,
               "remember: nothing set means Windows' 96")
        expect(DisplayCore.dpiToRemember(alreadySaved: nil, current: 192) == 96,
               "remember: a current 192 is ours (already on), never taken as the person's choice")
        expect(DisplayCore.dpiToRemember(alreadySaved: 120, current: 192) == 120,
               "remember: on twice keeps the FIRST before-value, not our own 192")
        expect(DisplayCore.dpiToRemember(alreadySaved: 9999, current: 144) == 144,
               "remember: a damaged saved value is ignored")
        expect(DisplayCore.dpiToRestore(saved: 120) == 120, "restore: puts the remembered DPI back")
        expect(DisplayCore.dpiToRestore(saved: nil) == 96 && DisplayCore.dpiToRestore(saved: 0) == 96,
               "restore: no or bad value means 96, never left at 200%")

        // --- the registry writes ----------------------------------------------
        let on = DisplayCore.regCommands(retinaOn: true, dpiWhenOff: 120)
        let off = DisplayCore.regCommands(retinaOn: false, dpiWhenOff: 120)
        func value(_ cmds: [[String]], _ key: String, _ name: String) -> String? {
            cmds.first { $0.count > 8 && $0[2] == key && $0[4] == name }?[8]
        }
        expect(on.count == 3 && off.count == 3, "reg: all three values are written in both states")
        expect(value(on, "HKCU\\Software\\Wine\\Mac Driver", "RetinaMode") == "y", "reg on: RetinaMode y")
        expect(value(on, "HKCU\\Control Panel\\Desktop", "LogPixels") == "192"
               && value(on, "HKEY_CURRENT_CONFIG\\Software\\Fonts", "LogPixels") == "192",
               "reg on: 200% in both places winecfg writes")
        expect(value(off, "HKCU\\Software\\Wine\\Mac Driver", "RetinaMode") == "n",
               "reg off: RetinaMode n is written, not left out")
        expect(value(off, "HKCU\\Control Panel\\Desktop", "LogPixels") == "120"
               && value(off, "HKEY_CURRENT_CONFIG\\Software\\Fonts", "LogPixels") == "120",
               "reg off: the remembered DPI goes back in both places")
        expect(on.allSatisfy { $0.first == "reg" && $0[1] == "add" && $0.last == "/f" },
               "reg: every command is a forced reg add (no prompt waiting for an answer)")

        // --- off by default, and what happens before SAI starts ----------------
        // It makes SAI a few times slower, so nobody gets it without asking.
        expect(DisplayCore.wanted(stored: nil) == nil, "default: nothing stored and no fix means hands off")
        expect(DisplayCore.wanted(stored: nil, wineHasFix: true) == true,
               "default: nothing stored and Wine has the fix means on (0.3.9)")
        // THE TRAP: the pulled 0.3.8 turned it on without the fix.
        expect(DisplayCore.wanted(stored: nil, wineHasFix: false) != true,
               "default: never on by default without the fix")
        expect(DisplayCore.wanted(stored: false, wineHasFix: true) == false,
               "default: an explicit off wins even with the fix")
        expect(DisplayCore.wanted(stored: false) == false && DisplayCore.wanted(stored: true) == true,
               "default: an explicit off or on is kept")
        // THE TRAP: never set here must not switch off a RetinaMode someone
        // turned on by hand, nor turn it on for someone who never asked.
        expect(DisplayCore.plan(wantOn: nil, wineOn: true)
               == DisplayCore.Plan(write: nil, rememberDPI: false, restartWine: false)
               && DisplayCore.plan(wantOn: nil, wineOn: false).write == nil,
               "plan: never set here leaves Wine alone, on or off")
        let first = DisplayCore.plan(wantOn: true, wineOn: false)
        expect(first.write == true && first.rememberDPI && first.restartWine,
               "plan: switching on keeps the old DPI and restarts Wine")
        let stay = DisplayCore.plan(wantOn: true, wineOn: true)
        expect(stay.write == true && !stay.restartWine, "plan: already on is written again, no restart")
        let toOff = DisplayCore.plan(wantOn: false, wineOn: true)
        expect(toOff.write == false && toOff.restartWine && !toOff.rememberDPI,
               "plan: switching off writes off once and restarts Wine")
        // THE TRAP: off and already off must write NOTHING, or every launch
        // would put the old DPI back over one changed later in winecfg.
        expect(DisplayCore.plan(wantOn: false, wineOn: false)
               == DisplayCore.Plan(write: nil, rememberDPI: false, restartWine: false),
               "plan: off while Wine is off leaves the registry alone")

        // --- sai2.ini -----------------------------------------------------------
        // As SAI ships it: BOM, UTF-16LE, CRLF, a comment that mentions lang.
        let shipped = "[Locale]\r\nlang = en\r\n\r\n\r\n[PenTablet]\r\n\t; lang = ja is not a setting\r\n\tAvoidWacomBug = no\r\n"
        let bytes = Data([0xFF, 0xFE]) + shipped.data(using: .utf16LittleEndian)!
        guard let ini = SAIIni.decode(bytes) else { expect(false, "ini: decodes"); return report() }
        expect(ini.utf16 && ini.language == "en", "ini: UTF-16 file decoded, lang is en")
        expect(ini.encoded() == bytes, "ini: unchanged file encodes back to the same bytes")

        let zh = ini.settingLanguage("zh")
        expect(zh.language == "zh", "ini: lang set to zh")
        expect(zh.text == shipped.replacingOccurrences(of: "lang = en", with: "lang = zh"),
               "ini: only the lang line changed; the comment and other sections are untouched")
        let zhBytes = zh.encoded()
        expect(zhBytes.prefix(2) == Data([0xFF, 0xFE]) && SAIIni.decode(zhBytes)?.language == "zh",
               "ini: written back as UTF-16LE with the BOM SAI expects")
        expect(zh.settingLanguage("en").encoded() == bytes, "ini: switching back gives the original bytes")

        let indented = SAIIni(text: "[Locale]\n\tlang=ja\n", utf16: false)
        expect(indented.settingLanguage("ko").text == "[Locale]\n\tlang = ko\n",
               "ini: indentation kept, LF file stays LF")
        expect(SAIIni(text: "[Other]\nlang = ja\n", utf16: false).language == nil,
               "ini: lang outside [Locale] is not SAI's language")
        let noLine = SAIIni(text: "[Locale]\r\n[PenTablet]\r\n", utf16: true).settingLanguage("ja")
        expect(noLine.language == "ja" && noLine.text.hasPrefix("[Locale]\r\nlang = ja\r\n"),
               "ini: a missing lang line is added under [Locale]")
        let noSection = SAIIni(text: "[PenTablet]\r\nx = 1\r\n", utf16: true).settingLanguage("tw")
        expect(noSection.language == "tw" && noSection.text.hasSuffix("[PenTablet]\r\nx = 1\r\n"),
               "ini: a missing [Locale] section is added, the rest kept")
        // --- language menu: Default ---------------------------------------------
        typealias LC = SAILanguageChoice
        expect(LC.iniTarget(stored: nil, original: "en") == nil,
               "default: never changed means sai2.ini is left alone")
        expect(LC.iniTarget(stored: "ja", original: "en") == "ja", "default: a picked language is written")
        expect(LC.iniTarget(stored: "default", original: "en") == "en",
               "default: switching back puts the old value in")
        expect(LC.iniTarget(stored: "default", original: nil) == nil
               && LC.iniTarget(stored: "default", original: "-") == nil,
               "default: no old value known (or there was no lang line) leaves the file alone")
        // THE TRAP: ja, then en, then Default. The second pick must not
        // remember "ja" (our own earlier choice) as SAI's original.
        var original: String? = nil
        original = LC.originalToRemember(alreadySaved: original, iniNow: "en")   // pick ja
        original = LC.originalToRemember(alreadySaved: original, iniNow: "ja")   // pick en
        expect(original == "en" && LC.iniTarget(stored: "default", original: original) == "en",
               "default: ja, then en, then Default gives back SAI's own en, not ja")
        expect(LC.originalToRemember(alreadySaved: nil, iniNow: nil) == "-",
               "default: a missing lang line is remembered as missing")

        // sai2.exe (2026-07-27) holds English and Japanese menu text only. The old
        // list of 11 codes made Russian and Chinese "do nothing" in testing.
        expect(SAILanguage.allCases.map(\.rawValue) == ["en", "ja"] && SAILanguage(rawValue: "ja")?.label == "日本語",
               "languages: only the two SAI has, English and Japanese")
        // A code left over from an older test build (ru, zh...) is never written.
        for code in ["ru", "zh", "tw", "ko", "de", "xx"] {
            expect(LC.iniTarget(stored: code, original: "en") == nil,
                   "languages: a stored \"\(code)\" leaves sai2.ini alone")
        }

        report()
    }

    static func report() {
        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("All DisplayCore tests passed.")
    }
}
