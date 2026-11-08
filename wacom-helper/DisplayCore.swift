// DisplayCore.swift — sharp text on Retina screens (issue #39) and SAI's UI
// language, as pure data.
//
// A switch in Advanced, OFF BY DEFAULT: it makes SAI a few times slower
// (seen in testing on an M3 Pro), because SAI then draws four times the
// pixels. What is known and what is not:
//
//   Known: Wine's Mac driver draws Windows apps at 1x unless RetinaMode is on,
//   and macOS then stretches the window 2x. Latin text survives that; CJK text,
//   with many thin strokes in one small box, smears (the #39 screenshots).
//   Known: sai2.exe declares itself per-monitor DPI aware (its manifest), and
//   picks its UI language from [Locale] lang in sai2.ini.
//   NOT known yet: that SAI's "Auto" UI zoom follows Wine's DPI, and that the
//   pen lands right with RetinaMode on. The DLL maps by fraction of the screen,
//   which unit tests cover for a 2x pixel desktop, but nobody has drawn with it.
//
// Two settings, both read once when SAI (and for RetinaMode, Wine) starts:
//
//   HKCU\Software\Wine\Mac Driver  RetinaMode = y | n
//       y: Windows sees the screen in real pixels (2x), so text is drawn sharp.
//       Everything in SAI also gets half as big, which is what the DPI is for:
//   HKCU\Control Panel\Desktop     LogPixels  (dword)
//   HKCC\Software\Fonts            LogPixels  (dword)
//       96 is Windows' 100%, 192 is 200%. winecfg writes both places, so this
//       does too; Wine reads the user one first.
//
// THE TRAP this file guards: turning Retina off must give back the DPI the
// person had BEFORE, not 96 and not 192. Remembering "the DPI right now" when
// the switch goes on is not enough, because if it was already on (a crash, a
// second click, the #39 workaround done by hand) "right now" is 192 and off
// would leave everything at 200%.
//
// No AppKit here: the tests compile this file on its own.

import Foundation

enum DisplayCore {

    static let retinaDPI = 192
    static let windowsDefaultDPI = 96
    /// Windows accepts 96 to 480 (100% to 500%). Anything else in a file we
    /// wrote is damage, not a choice.
    static let validDPI = 96...480

    static let macDriverKey = "HKCU\\Software\\Wine\\Mac Driver"
    static let userDPIKey   = "HKCU\\Control Panel\\Desktop"
    static let configDPIKey = "HKEY_CURRENT_CONFIG\\Software\\Fonts"

    // MARK: - reading Wine's registry files

    /// One value from a Wine .reg file, raw (e.g. `"y"` -> y, `dword:000000c0`
    /// stays as it is). `key` is written with single backslashes, relative to
    /// the file's root (user.reg: HKCU, system.reg: HKLM).
    static func regValue(_ reg: String, key: String, name: String) -> String? {
        // The files double every backslash in a key name.
        let header = "[" + key.lowercased().replacingOccurrences(of: "\\", with: "\\\\") + "]"
        let want = "\"" + name.lowercased() + "\"="
        var inSection = false
        for raw in reg.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                // "[Key] 1793896951": the number after the bracket is a timestamp.
                inSection = line.lowercased().hasPrefix(header)
                continue
            }
            guard inSection, line.lowercased().hasPrefix(want) else { continue }
            let v = line.dropFirst(want.count)
            return v.hasPrefix("\"") ? String(v.dropFirst().dropLast(v.hasSuffix("\"") ? 1 : 0)) : String(v)
        }
        return nil
    }

    /// Wine's own test for a yes (IS_OPTION_TRUE in winemac.drv): the first
    /// letter is y, t or 1. "yes", "True" and "1" all count.
    static func isWineTrue(_ v: String?) -> Bool {
        guard let c = v?.first else { return false }
        return "yYtT1".contains(c)
    }

    static func retinaModeOn(userReg: String) -> Bool {
        isWineTrue(regValue(userReg, key: "Software\\Wine\\Mac Driver", name: "RetinaMode"))
    }

    /// `dword:000000c0` -> 192.
    static func dword(_ v: String?) -> Int? {
        guard let v = v, v.lowercased().hasPrefix("dword:") else { return nil }
        return Int(v.dropFirst(6), radix: 16)
    }

    /// The DPI Wine uses: the user's value if there is one, else the machine's.
    static func currentDPI(userReg: String, systemReg: String) -> Int? {
        dword(regValue(userReg, key: "Control Panel\\Desktop", name: "LogPixels"))
            ?? dword(regValue(systemReg, key: "System\\CurrentControlSet\\Hardware Profiles\\Current\\Software\\Fonts",
                              name: "LogPixels"))
            ?? dword(regValue(systemReg, key: "System\\ControlSet001\\Hardware Profiles\\Current\\Software\\Fonts",
                              name: "LogPixels"))
    }

    // MARK: - what to remember, what to write

    /// The DPI to keep for later, at the moment Retina goes on.
    ///
    /// `alreadySaved` wins: once we hold the "before" value, a second "on" must
    /// not overwrite it with our own 192. And a current 192 is never taken as
    /// the person's choice, since it is what this switch sets.
    static func dpiToRemember(alreadySaved: Int?, current: Int?) -> Int {
        if let s = alreadySaved, validDPI.contains(s) { return s }
        if let c = current, validDPI.contains(c), c != retinaDPI { return c }
        return windowsDefaultDPI
    }

    /// The DPI to put back when Retina goes off.
    static func dpiToRestore(saved: Int?) -> Int {
        if let s = saved, validDPI.contains(s) { return s }
        return windowsDefaultDPI
    }

    /// ON BY DEFAULT ONLY WHERE IT DOES NOT LAG (0.3.9). Nothing stored and a
    /// Wine with the fix for the Retina lag (our patched driver, or Wine 11.22+)
    /// means on. Nothing stored and no fix means hands off, as in 0.3.8: off
    /// for most, and someone who turned RetinaMode on by hand keeps it. An
    /// explicit choice in Advanced always wins.
    ///
    /// THE TRAP: never default to on without the fix. That was the 0.3.8 that
    /// was pulled: sharp text, but SAI's main thread 68% busy while drawing.
    static func wanted(stored: Bool?, wineHasFix: Bool = false) -> Bool? {
        if let s = stored { return s }
        return wineHasFix ? true : nil
    }

    /// What to do before SAI starts, given what is wanted and what Wine has.
    struct Plan: Equatable {
        /// Write the on (true) or off (false) values; nil writes nothing.
        var write: Bool?
        /// Keep the current DPI as "before" (only when nothing is kept yet).
        var rememberDPI: Bool
        /// RetinaMode changes, so Wine must start fresh before SAI.
        var restartWine: Bool
    }

    /// THE TRAP: an "off" must not write anything while
    /// Wine is already off. Writing the remembered DPI on every launch would
    /// undo a text size changed later in winecfg, every time SAI opens. Only
    /// the switch from on to off puts the old size back.
    static func plan(wantOn: Bool?, wineOn: Bool) -> Plan {
        guard let wantOn = wantOn else {           // never set here: hands off
            return Plan(write: nil, rememberDPI: false, restartWine: false)
        }
        switch (wantOn, wineOn) {
        case (true, false):  return Plan(write: true, rememberDPI: true, restartWine: true)
        // Already on: write again (cheap, and it puts 200% back if something
        // reset it), keep "before" if this is a prefix set to y by hand.
        case (true, true):   return Plan(write: true, rememberDPI: true, restartWine: false)
        case (false, true):  return Plan(write: false, rememberDPI: false, restartWine: true)
        case (false, false): return Plan(write: nil, rememberDPI: false, restartWine: false)
        }
    }

    /// The `wine reg add` arguments for one state. All three values every
    /// time, "off" included: switching off has to be written, not left out.
    static func regCommands(retinaOn: Bool, dpiWhenOff: Int) -> [[String]] {
        let dpi = retinaOn ? retinaDPI : dpiToRestore(saved: dpiWhenOff)
        return [
            ["reg", "add", macDriverKey, "/v", "RetinaMode", "/t", "REG_SZ", "/d", retinaOn ? "y" : "n", "/f"],
            ["reg", "add", userDPIKey,   "/v", "LogPixels",  "/t", "REG_DWORD", "/d", "\(dpi)", "/f"],
            ["reg", "add", configDPIKey, "/v", "LogPixels",  "/t", "REG_DWORD", "/d", "\(dpi)", "/f"],
        ]
    }
}

// MARK: - SAI's UI language

/// The codes sai2.exe knows ([Locale] lang). Found in the executable itself;
/// whether each one has a full translation in a given SAI build is SAI's
/// business, not ours.
enum SAILanguage: String, CaseIterable {
    case en, ja, zh, tw, ko, de, fr, es, it, pt, ru

    var label: String {
        switch self {
        case .en: return "English"
        case .ja: return "日本語"
        case .zh: return "简体中文"
        case .tw: return "繁體中文"
        case .ko: return "한국어"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .es: return "Español"
        case .it: return "Italiano"
        case .pt: return "Português"
        case .ru: return "Русский"
        }
    }
}

/// The language menu's "Default": the app leaves sai2.ini alone.
///
/// The menu remembers one choice: nothing (Default, never changed), a code, or
/// "default" (switched back to Default, and the old value still has to go
/// back into sai2.ini). SAI only reads the file at start, so that last state
/// can wait for a launch.
///
/// THE TRAP, same shape as the DPI one: "back to Default" means the value
/// SAI had BEFORE this app first changed it. Remembering sai2.ini as it is at
/// the moment of a change would, on the second change, remember our own
/// earlier choice, and Default would then leave SAI in, say, Japanese.
enum SAILanguageChoice {
    static let defaultChoice = "default"
    /// Written when sai2.ini had no lang line at all.
    static let noValue = "-"

    /// What to keep as "before", at the moment a language is picked.
    static func originalToRemember(alreadySaved: String?, iniNow: String?) -> String {
        if let s = alreadySaved, !s.isEmpty { return s }
        return iniNow ?? noValue
    }

    /// The lang to put into sai2.ini for the stored choice, or nil to leave
    /// the file alone. `original` is the remembered "before" value.
    static func iniTarget(stored: String?, original: String?) -> String? {
        guard let s = stored, !s.isEmpty else { return nil }        // never changed
        if s == defaultChoice {
            guard let o = original, o != noValue, !o.isEmpty else { return nil }
            return o
        }
        return s
    }
}

/// sai2.ini as SAI ships it: UTF-16 little-endian with a byte-order mark and
/// CRLF lines. Read and written back in the SAME encoding and line endings,
/// so the only bytes that change are the language code.
struct SAIIni {
    var text: String
    var utf16: Bool

    static func decode(_ d: Data) -> SAIIni? {
        if d.count >= 2, d[d.startIndex] == 0xFF, d[d.startIndex + 1] == 0xFE {
            guard let s = String(data: d.dropFirst(2), encoding: .utf16LittleEndian) else { return nil }
            return SAIIni(text: s, utf16: true)
        }
        guard let s = String(data: d, encoding: .utf8) else { return nil }
        return SAIIni(text: s, utf16: false)
    }

    func encoded() -> Data {
        guard utf16 else { return Data(text.utf8) }
        return Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data())
    }

    private var newline: String { text.contains("\r\n") ? "\r\n" : "\n" }

    private func lines() -> [String] { text.components(separatedBy: newline) }

    private static func isSection(_ l: String) -> Bool {
        l.trimmingCharacters(in: .whitespaces).hasPrefix("[")
    }
    private static func isLocale(_ l: String) -> Bool {
        l.trimmingCharacters(in: .whitespaces).lowercased() == "[locale]"
    }
    /// `lang = en` (any spacing), but not a comment and not `language = …`.
    private static func langValue(_ l: String) -> String? {
        let t = l.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix(";") else { return nil }
        let parts = t.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts[0].lowercased() == "lang" else { return nil }
        return parts[1]
    }

    var language: String? {
        var inLocale = false
        for l in lines() {
            if Self.isSection(l) { inLocale = Self.isLocale(l); continue }
            if inLocale, let v = Self.langValue(l) { return v }
        }
        return nil
    }

    /// The same file with `lang` set to `code`. Only that line changes; the
    /// indentation before it is kept. A missing line or section is added.
    func settingLanguage(_ code: String) -> SAIIni {
        var ls = lines()
        var inLocale = false
        var localeAt: Int?
        for (i, l) in ls.enumerated() {
            if Self.isSection(l) {
                inLocale = Self.isLocale(l)
                if inLocale { localeAt = i }
                continue
            }
            if inLocale, Self.langValue(l) != nil {
                let indent = String(l.prefix(while: { $0 == " " || $0 == "\t" }))
                ls[i] = indent + "lang = " + code
                return SAIIni(text: ls.joined(separator: newline), utf16: utf16)
            }
        }
        if let at = localeAt {
            ls.insert("lang = " + code, at: at + 1)
        } else {
            ls.insert(contentsOf: ["[Locale]", "lang = " + code, ""], at: 0)
        }
        return SAIIni(text: ls.joined(separator: newline), utf16: utf16)
    }
}
