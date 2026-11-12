// FontLinkTests.swift — unit tests for FontLinkCore (Chinese, Japanese and
// Korean text in SAI with the Mac's own fonts, issue #39).
//
// The last group opens the REAL font files on this Mac and checks that every
// entry names a file that exists and the family Wine will match in it. That is
// the check that would have caught "Hiragino Sans" (Wine knows it as
// "Hiragino Sans W3"), the mistake that made an earlier hand test do nothing.

import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String,
            file: StaticString = #file, line: UInt = #line) {
    if cond { print("  ok   \(name)") }
    else { print("  FAIL \(name)  (\(file):\(line))"); failures += 1 }
}

typealias FL = FontLinkCore

/// A system.reg section as Wine writes it: doubled backslashes in the key, a
/// timestamp, a #time line, NUL separators as \0, non-ASCII as \xNNNN, and a
/// look-alike section next to it.
let wineTahoma = ["MSGOTHIC.TTC,MS UI Gothic", "MINGLIU.TTC,PMingLiU", "SIMSUN.TTC,SimSun"]
let wineMeiryoUI = ["SEGOEUI.TTF,Segoe UI", "MSYH.TTC,Microsoft YaHei UI"]
func systemReg(tahoma: String = wineTahoma.joined(separator: "\\0") + "\\0",
               extra: String = "") -> String {
    """
    WINE REGISTRY Version 2

    [Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\FontLink\\\\SystemLink] 1789057661
    #time=1dd41414d4b731a
    "Lucida Sans Unicode"=str(7):"MSGOTHIC.TTC,MS UI Gothic\\0"
    "Meiryo UI"=str(7):"\(wineMeiryoUI.joined(separator: "\\0"))\\0"
    "MS PGothic"=str(7):"MINGLIU.TTC,PMingLiU\\0"
    "MS UI Gothic"=str(7):"MICROSS.TTF,Microsoft Sans Serif\\0"
    "Tahoma"=str(7):"\(tahoma)"
    \(extra)
    [Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\FontLink\\\\SystemLinkOther] 1789057661
    "Tahoma"=str(7):"NOT.TTF,Not This\\0"

    [Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Fonts] 1794436919
    "Tahoma (TrueType)"="tahoma.ttf"
    """
}

func list(_ v: FL.Value?) -> [String]? { if case .list(let l)? = v { return l }; return nil }

/// Apply a change to a parsed state, the way reg.exe would.
func applied(_ state: [String: FL.Value], _ cs: [FL.Change]) -> [String: FL.Value] {
    var s = state
    for c in cs {
        let key = s.keys.first { $0.caseInsensitiveCompare(c.name) == .orderedSame } ?? c.name
        if let l = c.list { s[key] = .list(l) } else { s.removeValue(forKey: key) }
    }
    return s
}

// MARK: - real font files on this Mac (read only, through the app's own code)

let wineFontsDir = "/Applications/Wine Staging.app/Contents/Resources/wine/share/wine/fonts"
let realDirs = FL.fontDirs(home: NSHomeDirectory(), wineFontsDir: wineFontsDir) {
    (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []
}
/// Where macOS (and Wine Staging) keep a font file with this name.
func findFontFile(_ name: String) -> String? {
    realDirs.map { "\($0)/\(name)" }.first { FileManager.default.fileExists(atPath: $0) }
}
func wineFamilies(_ path: String) -> Set<String> {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return [] }
    return Set(FL.gdiFamilies(fontData: d))
}

@main
struct FontLinkTests {
    static func main() {
        print("FontLinkCore tests:")

        // --- reading system.reg ----------------------------------------------
        let reg = systemReg()
        let links = FL.systemLinks(systemReg: reg)
        expect(links != nil, "read: the SystemLink section is found")
        expect(list(links?["Tahoma"]) == wineTahoma, "read: Tahoma's list, split at \\0, in order")
        expect(list(links?["Meiryo UI"]) == wineMeiryoUI, "read: another value in the same section")
        expect(links?.count == 5, "read: only this section, not SystemLinkOther or Fonts")
        expect(FL.systemLinks(systemReg: "WINE REGISTRY Version 2\n\n[Software\\\\Wine] 1\n") == nil,
               "read: no SystemLink section at all means nil, so nothing is touched")
        // The Japanese spelling of MS PGothic, as Wine escapes it in the file.
        let escaped = systemReg(extra: "\"\\xff2d\\xff33 \\xff30\\x30b4\\x30b7\\x30c3\\x30af\"=str(7):\"A.TTC,A\\0\"")
        expect(list(FL.systemLinks(systemReg: escaped)?["ＭＳ Ｐゴシック"]) == ["A.TTC,A"],
               "read: a \\xNNNN-escaped value name is read as ＭＳ Ｐゴシック")
        expect(FL.unescape("\\x30d2\\x30e9W3") == "ヒラW3" && FL.unescape("\\xc7z") == "\u{c7}z",
               "read: \\x takes up to 4 hex digits (Wine writes 4 when a hex digit follows)")
        expect(FL.unescape("a\\\\b\\\"c") == "a\\b\"c", "read: \\\\ and \\\" are undone")
        let hex = systemReg(extra: "\"MS UI Gothic\"=hex(7):41,00,00,00,00,00")
        expect(FL.systemLinks(systemReg: hex)?["MS UI Gothic"] == .unreadable,
               "read: a hex(7) value is marked unreadable, not read as empty")
        let empties = systemReg(tahoma: "A.TTC,A\\0\\0B.TTC,B\\0")
        expect(list(FL.systemLinks(systemReg: empties)?["Tahoma"]) == ["A.TTC,A", "B.TTC,B"],
               "read: empty entries are dropped (reg.exe would reject them on the way back)")

        // --- which font first ------------------------------------------------
        expect(FL.font(forLanguage: "ja-JP") == FL.hiraginoSans, "lang: ja-JP is Hiragino")
        expect(FL.font(forLanguage: "ko") == FL.appleSDGothic, "lang: ko is Apple SD Gothic Neo")
        expect(FL.font(forLanguage: "zh-Hans-CN") == FL.pingFangSC, "lang: zh-Hans-CN is PingFang SC")
        expect(FL.font(forLanguage: "zh") == FL.pingFangSC, "lang: plain zh is PingFang SC")
        expect(FL.font(forLanguage: "zh-Hant-TW") == FL.pingFangTC, "lang: zh-Hant-TW is PingFang TC")
        expect(FL.font(forLanguage: "zh_TW") == FL.pingFangTC, "lang: zh_TW (underscore) is PingFang TC")
        expect(FL.font(forLanguage: "zh-Hant-HK") == FL.pingFangHK, "lang: zh-Hant-HK is PingFang HK")
        expect(FL.font(forLanguage: "zh-HK") == FL.pingFangHK, "lang: zh-HK is PingFang HK")
        expect(FL.font(forLanguage: "en-GB") == nil && FL.font(forLanguage: "") == nil,
               "lang: other languages pick nothing")
        // Anastasia's Mac: Japanese is the first CJK language, after three others.
        let mine = FL.order(preferredLanguages: ["en-GB", "ru-DE", "de-DE", "ja-DE"])
        expect(mine == [FL.hiraginoSans, FL.pingFangSC, FL.pingFangTC, FL.appleSDGothic, FL.wineYahei],
               "order: Japanese first on a Mac that prefers Japanese among CJK")
        let zh = FL.order(preferredLanguages: ["zh-Hans-CN", "en"])
        expect(zh.first == FL.pingFangSC && zh.count == 5 && zh.last == FL.wineYahei,
               "order: Simplified Chinese first, every font once, Wine's Yahei last")
        let tw = FL.order(preferredLanguages: ["zh-Hant-TW", "ja"])
        expect(Array(tw.prefix(2)) == [FL.pingFangTC, FL.hiraginoSans], "order: two CJK languages keep their order")
        expect(FL.order(preferredLanguages: ["ko-KR", "ko"]).filter { $0 == FL.appleSDGothic }.count == 1,
               "order: the same language twice gives the font once")
        expect(FL.order(preferredLanguages: ["en"]) == FL.defaultOrder + [FL.wineYahei],
               "order: no CJK language means the default order")
        expect(FL.order(preferredLanguages: ["zh-HK"]).contains(FL.pingFangHK)
               && !FL.order(preferredLanguages: ["en"]).contains(FL.pingFangHK),
               "order: PingFang HK only when Hong Kong is a preferred language")

        // --- what to write ---------------------------------------------------
        guard let start = links else { return report() }
        let fonts = FL.order(preferredLanguages: ["ja"])
        let ours = fonts.map(\.entry)
        let on = FL.changes(current: start, on: true, fonts: fonts)
        expect(on.count == 5, "on: all five SAI font names get a change")
        let afterOn = applied(start, on)
        expect(list(afterOn["Tahoma"]) == ours + wineTahoma, "on: ours first, then Wine's own list in order")
        expect(list(afterOn["ＭＳ Ｐゴシック"]) == [FL.wineArial.entry] + ours,
               "on: a name Wine has no list for gets ours alone, Arial first")
        // THE TRAP 5: a name with no font of its own is drawn ENTIRELY in its
        // first entry. Arial first keeps Latin and Cyrillic as they were
        // (Hiragino first made "Слой" full-width); Tahoma exists, so no lead.
        expect(list(afterOn["MS UI Gothic"]) == [FL.wineArial.entry] + ours + ["MICROSS.TTF,Microsoft Sans Serif"],
               "on: MS UI Gothic starts with Wine's Arial, then ours, then Wine's own")
        expect(["Meiryo UI", "MS PGothic"].allSatisfy { list(afterOn[$0])?.first == FL.wineArial.entry },
               "on: every Japanese font name starts with Arial")
        expect(!(list(afterOn["Tahoma"]) ?? []).contains(FL.wineArial.entry), "on: Tahoma's list has no Arial")
        expect(FL.changes(current: afterOn, on: true, fonts: fonts).isEmpty,
               "on: a second launch writes nothing (no reg.exe on a normal launch)")
        // The Mac's language changed: the order changes, nothing is doubled.
        let zhFonts = FL.order(preferredLanguages: ["zh-Hans"])
        let reordered = applied(afterOn, FL.changes(current: afterOn, on: true, fonts: zhFonts))
        expect(list(reordered["Tahoma"]) == zhFonts.map(\.entry) + wineTahoma,
               "on: a new language order replaces ours, no entry twice, Wine's kept")
        // Wine rewrote a list on its own: ours are gone, the next launch adds them.
        var rewritten = afterOn; rewritten["Tahoma"] = .list(wineTahoma)
        expect(FL.changes(current: rewritten, on: true, fonts: fonts) == [FL.Change(name: "Tahoma", list: ours + wineTahoma)],
               "on: a list Wine rewrote gets ours back, and only that one is written")

        // THE TRAP 2: off gives back exactly what Wine had.
        let afterOff = applied(afterOn, FL.changes(current: afterOn, on: false, fonts: fonts))
        expect(afterOff == start, "off: every list is back exactly as before, and ＭＳ Ｐゴシック is gone again")
        expect(FL.changes(current: start, on: false, fonts: fonts).isEmpty,
               "off: nothing of ours there means nothing written")
        let offCmds = FL.changes(current: afterOn, on: false, fonts: fonts)
        expect(offCmds.contains(FL.Change(name: "ＭＳ Ｐゴシック", list: nil)),
               "off: the value Wine never had is deleted, not left empty")
        // Entries from the hand test (cjk-font-test/1-apply) count as ours.
        var handTest = start
        handTest["Tahoma"] = .list(["ヒラギノ角ゴシック W3.ttc,Hiragino Sans W3", "msyh.ttf,Microsoft Yahei"] + wineTahoma)
        expect(list(applied(handTest, FL.changes(current: handTest, on: false, fonts: fonts))["Tahoma"]) == wineTahoma,
               "off: the hand test's entries are taken out too")
        // Case does not make an entry Wine's.
        var shouted = start; shouted["Tahoma"] = .list(["PINGFANG.TTC,PINGFANG SC"] + wineTahoma)
        expect(list(applied(shouted, FL.changes(current: shouted, on: false, fonts: fonts))["Tahoma"]) == wineTahoma,
               "off: our entry in other letter case is still ours")
        // Wine's own Yahei entry is MSYH.TTC with another face: never taken for ours.
        expect(!FL.isOurs("MSYH.TTC,Microsoft YaHei UI") && FL.isOurs("msyh.ttf,Microsoft Yahei"),
               "ours: Wine's MSYH.TTC entry is Wine's, Staging's msyh.ttf one is ours")

        // THE TRAP 3: a value that cannot be read is never overwritten.
        var odd = start; odd["MS UI Gothic"] = .unreadable
        expect(!FL.changes(current: odd, on: true, fonts: fonts).contains { $0.name == "MS UI Gothic" }
               && !FL.changes(current: odd, on: false, fonts: fonts, force: true).contains { $0.name == "MS UI Gothic" },
               "unreadable: left alone on, off and forced")
        expect(FL.changes(current: nil, on: true, fonts: fonts, force: true).isEmpty,
               "no section: nothing is written, not even forced")

        // force: after a click, system.reg may still show the state from before.
        let forcedOff = FL.changes(current: start, on: false, fonts: fonts, force: true)
        expect(forcedOff.count == 5 && applied(afterOn, forcedOff) == start,
               "force: off from a file that lags (still shows Wine's) still undoes what is in Wine")
        expect(FL.changes(current: afterOn, on: true, fonts: fonts, force: true).count == 5,
               "force: on writes all five even when the file looks done")
        let keyCase = FL.changes(current: ["tahoma": .list(wineTahoma)], on: true, fonts: fonts)
        expect(keyCase.contains { $0.name == "tahoma" } && !keyCase.contains { $0.name == "Tahoma" },
               "names: matched without case, written back under the existing name")

        // --- Wine's real lists (Wine Staging 11.16, a fresh prefix) ------------
        // THE TRAP 2 rests on Wine never listing a file of ours. Checked here on
        // the real section, which also shows on + off is exact on real data.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("fixtures/wine-11.16-SystemLink.reg")
        if let text = try? String(contentsOf: fixture, encoding: .utf8),
           let real = FL.systemLinks(systemReg: text) {
            let entries = real.values.flatMap { list($0) ?? [] }
            expect(real.count >= 20 && entries.count > 100, "wine 11.16: the real section is read (\(real.count) names)")
            expect(!entries.contains { FL.isOurs($0) }, "wine 11.16: none of Wine's own entries counts as ours")
            let realOn = applied(real, FL.changes(current: real, on: true, fonts: fonts))
            expect(applied(realOn, FL.changes(current: realOn, on: false, fonts: fonts)) == real,
                   "wine 11.16: on, then off, gives Wine's lists back exactly")
            expect(real.filter { !FL.saiFontNames.contains($0.key) } == realOn.filter { !FL.saiFontNames.contains($0.key) },
                   "wine 11.16: no other font name's list is touched")
        } else {
            expect(false, "wine 11.16: fixture \(fixture.path) is readable")
        }

        // --- the reg.exe arguments -------------------------------------------
        let add = FL.regCommand(FL.Change(name: "Tahoma", list: ["A.TTC,A", "B.TTC,B"]))
        expect(add == ["reg", "add", FL.systemLinkKey, "/v", "Tahoma", "/t", "REG_MULTI_SZ",
                       "/d", "A.TTC,A\\0B.TTC,B", "/f"],
               "reg: a list is one REG_MULTI_SZ, entries split by a literal \\0")
        expect(FL.regCommand(FL.Change(name: "ＭＳ Ｐゴシック", list: nil))
               == ["reg", "delete", FL.systemLinkKey, "/v", "ＭＳ Ｐゴシック", "/f"],
               "reg: no list deletes the value")
        expect(FL.systemLinkKey.hasPrefix("HKLM\\") && FL.systemLinkKey.hasSuffix("\\FontLink\\SystemLink"),
               "reg: the machine-wide SystemLink key")
        // --- the dropdown's choice ---------------------------------------------
        typealias C = FL.Choice
        for s in [nil, "", "auto", "on", "garbage", "font\tA.ttf\tA", "font\tA,B.ttf\tA\t/x", "font\t\tA\t/x"] as [String?] {
            expect(C(stored: s) == .automatic, "choice: \(s.map { "\"\($0)\"" } ?? "nothing stored") is Automatic")
        }
        expect(C(stored: "off") == .off && C(stored: " off\n") == .off, "choice: off is Off")
        let foo = FL.LinkFont(file: "Foo Sans.otf", family: "Foo Sans")
        let fooChoice = C.font(foo, path: "/Users/x/Library/Fonts/Foo Sans.otf")
        expect(C(stored: fooChoice.stored) == fooChoice, "choice: a chosen font is stored and read back")
        expect(C(stored: C.off.stored) == .off && C(stored: C.automatic.stored) == .automatic,
               "choice: Off and Automatic are stored and read back")
        let ja = FL.order(preferredLanguages: ["ja"])
        expect(FL.fonts(for: .automatic, preferredLanguages: ["ja"]) == ja, "choice: Automatic is the language order")
        expect(FL.fonts(for: .off, preferredLanguages: ["ja"]).isEmpty, "choice: Off puts nothing in front")
        expect(FL.fonts(for: fooChoice, preferredLanguages: ["ja"]) == [foo] + ja,
               "choice: a chosen font first, the automatic ones behind it for what it lacks")
        let tcFirst = FL.fonts(for: .font(FL.pingFangTC, path: "/p"), preferredLanguages: ["ja"])
        expect(tcFirst.first == FL.pingFangTC && tcFirst.filter { $0 == FL.pingFangTC }.count == 1,
               "choice: a built-in font chosen moves to the front, not doubled")

        // --- the Language dropdown ----------------------------------------------
        let opts = FL.languageOptions
        // THE TRAP (FontLinkCore, LanguageOption): only the languages SAI has. A
        // 简体中文 or 한국어 line read as if SAI could switch to Chinese or Korean.
        expect(opts.map(\.title) == ["English", "日本語"],
               "language: only English and 日本語, the two languages SAI has")
        expect(opts.map(\.saiLanguage) == ["en", "ja"],
               "language: every line is a different SAI menu language, none is only a font")
        expect(opts.map(\.font) == [nil, FL.hiraginoSans],
               "language: English is Automatic, 日本語 puts Hiragino first")
        // SAI has English and Japanese menus only: no line may ask sai2.ini for another.
        expect(opts.allSatisfy { ["en", "ja"].contains($0.saiLanguage) } && opts.filter { $0.saiLanguage == "ja" }.count == 1,
               "language: only en and ja go into sai2.ini, Japanese on one line")
        expect(!opts.contains { $0.title.contains("\u{2014}") }, "language: no em dash in the menu")
        expect(FL.choice(for: opts[0], path: "/x") == .automatic, "language: English means Automatic fonts")
        expect(FL.choice(for: opts[1], path: "/p/W3.ttc") == .font(FL.hiraginoSans, path: "/p/W3.ttc"),
               "language: 日本語 puts Hiragino first")
        // English still covers every script: Automatic has all four Mac fonts and Yahei.
        let autoAll = FL.fonts(for: FL.choice(for: opts[0], path: nil), preferredLanguages: ["en-GB", "ru"])
        expect(Set(autoAll.map(\.entry)) == Set([FL.hiraginoSans, FL.pingFangSC, FL.pingFangTC, FL.appleSDGothic, FL.wineYahei].map(\.entry)),
               "language: English still gets Chinese, Japanese and Korean fonts")
        // The test build stored PingFang SC for its 简体中文 line: now Automatic,
        // so Wine gets what the menu shows (English). Own fonts and Hiragino stay.
        expect(FL.effective(.font(FL.pingFangSC, path: "/p")) == .automatic, "effective: old 简体中文 choice is Automatic")
        expect(FL.effective(.font(FL.pingFangTC, path: "/p")) == .automatic, "effective: old 繁體中文 choice is Automatic")
        expect(FL.effective(.font(FL.appleSDGothic, path: "/p")) == .automatic, "effective: old 한국어 choice is Automatic")
        expect(FL.effective(.font(FL.hiraginoSans, path: "/p")) == .font(FL.hiraginoSans, path: "/p"), "effective: 日本語's Hiragino stays")
        expect(FL.effective(.font(foo, path: "/f")) == .font(foo, path: "/f"), "effective: a font of the person's own stays")
        expect(FL.effective(.off) == .off && FL.effective(.automatic) == .automatic, "effective: Off and Automatic stay")
        typealias Sel = FL.Selection
        expect(FL.selection(saiLanguage: nil, font: .automatic) == .language(0), "shown: nothing stored is English")
        expect(FL.selection(saiLanguage: "en", font: .automatic) == .language(0), "shown: en + Automatic is English")
        expect(FL.selection(saiLanguage: "ja", font: .font(FL.hiraginoSans, path: "")) == .language(1), "shown: ja is 日本語")
        expect(FL.selection(saiLanguage: "ja", font: .automatic) == .language(1),
               "shown: Japanese menus show 日本語 whatever the font (SAI set to ja by hand)")
        expect(FL.selection(saiLanguage: "en", font: FL.effective(.font(FL.pingFangTC, path: ""))) == .language(0),
               "shown: the old 繁體中文 choice shows as English")
        expect(FL.selection(saiLanguage: "en", font: .font(FL.hiraginoSans, path: "")) == .language(0),
               "shown: Hiragino with English menus has no line of its own, shown as English")
        expect(FL.selection(saiLanguage: "ja", font: .font(foo, path: "/f")) == .font(foo), "shown: a font of the person's own shows itself")
        expect(FL.selection(saiLanguage: "ja", font: .off) == .off, "shown: Off shows Off")

        // Fonts chosen from the Mac's folders: remembered so Off takes them out.
        expect(FL.remembering(FL.pingFangSC, in: []) == [], "remember: a built-in font needs no remembering")
        let rem = FL.remembering(foo, in: [])
        expect(rem == [foo.entry] && FL.remembering(FL.LinkFont(file: "FOO SANS.OTF", family: "foo sans"), in: rem) == rem,
               "remember: a chosen font once, whatever the letter case")
        let withFoo = applied(start, FL.changes(current: start, on: true, fonts: FL.fonts(for: fooChoice, preferredLanguages: ["ja"]), remembered: rem))
        expect(list(withFoo["Tahoma"])?.first == foo.entry, "remember: the chosen font is first in Tahoma's list")
        let fooOff = applied(withFoo, FL.changes(current: withFoo, on: false, fonts: [], remembered: rem))
        expect(fooOff == start, "remember: Off takes a chosen font out too, Wine's lists exact")
        let bar = FL.LinkFont(file: "Bar.ttf", family: "Bar")
        let rem2 = FL.remembering(bar, in: rem)
        let toBar = applied(withFoo, FL.changes(current: withFoo, on: true, fonts: FL.fonts(for: .font(bar, path: "/b"), preferredLanguages: ["ja"]), remembered: rem2))
        expect(list(toBar["Tahoma"]) == [bar.entry] + ja.map(\.entry) + wineTahoma,
               "remember: choosing another font replaces the first one, nothing left behind")
        // A font Wine's own lists already name is never offered (Off would take it from Wine).
        let wineOwn = FL.wineEntries(start)
        expect(wineOwn.contains("SIMSUN.TTC,SimSun") && !FL.canOffer(FL.LinkFont(file: "simsun.ttc", family: "SIMSUN"), wineEntries: wineOwn),
               "offer: a font in Wine's own lists (any case) is not offered")
        expect(FL.canOffer(foo, wineEntries: wineOwn) && FL.canOffer(FL.hiraginoSans, wineEntries: wineOwn),
               "offer: other fonts are")
        expect(!FL.wineEntries(withFoo, remembered: rem).contains(foo.entry) && !FL.wineEntries(withFoo, remembered: rem).contains(FL.pingFangSC.entry),
               "offer: Wine's own entries leave ours and chosen ones out")

        // --- where fonts are looked for ----------------------------------------
        let fake: [String: [String]] = [
            "/System/Library/AssetsV2": ["com_apple_MobileAsset_Font8", "com_apple_MobileAsset_Other"],
            "/System/Library/AssetsV2/com_apple_MobileAsset_Font8": ["abc.asset"],
            "/System/Library/AssetsV2/com_apple_MobileAsset_Other": ["zzz.asset"],
        ]
        let dirs = FL.fontDirs(home: "/Users/x", wineFontsDir: "/W/fonts") { fake[$0] ?? [] }
        expect(dirs.first == "/System/Library/Fonts" && dirs.contains("/Users/x/Library/Fonts") && dirs.last == "/W/fonts",
               "dirs: system fonts first, the user's fonts, Wine's fonts last")
        expect(dirs.contains("/System/Library/AssetsV2/com_apple_MobileAsset_Font8/abc.asset/AssetData")
               && !dirs.contains { $0.contains("MobileAsset_Other") },
               "dirs: PingFang's font asset folder is found, other assets are not")

        // --- THE TRAP 1: real files, real family names -------------------------
        // Every entry must name a file that exists and a family Wine matches in
        // it. Hiragino and Apple SD Gothic Neo are in every macOS this app
        // supports, so missing them fails. PingFang (a macOS asset) and Wine
        // Staging's font may be absent on a build machine: then skipped, said so.
        let required = [FL.hiraginoSans.file, FL.appleSDGothic.file]
        for f in FL.allOurs {
            guard let path = findFontFile(f.file) else {
                if required.contains(f.file) { expect(false, "real font: \(f.file) exists on this Mac") }
                else { print("  skip real font: \(f.file) is not on this machine") }
                continue
            }
            let fams = wineFamilies(path)
            expect(fams.contains(f.family), "real font: \(f.file) has the family Wine matches, \"\(f.family)\""
                   + (fams.contains(f.family) ? "" : " (found: \(fams.sorted()))"))
        }
        if let h = findFontFile(FL.hiraginoSans.file) {
            expect(!wineFamilies(h).contains("Hiragino Sans"),
                   "real font: plain \"Hiragino Sans\" is NOT a family Wine matches (the old mistake)")
        }

        // --- a broken or hostile font file never crashes the app ---------------
        // The dropdown reads names from files the person picks, so any bytes at all.
        expect(FL.gdiFamilies(fontData: Data()).isEmpty && FL.gdiFamilies(fontData: Data("ttcf".utf8)).isEmpty,
               "names: empty and cut-off data give no names")
        let hostile = Data("ttcf".utf8) + Data([0, 1, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF]) + Data(repeating: 0xFF, count: 64)
        expect(FL.gdiFamilies(fontData: hostile).isEmpty,
               "names: a collection claiming 4 billion faces at wild offsets gives no names")
        if let h = findFontFile(FL.hiraginoSans.file),
           let d = try? Data(contentsOf: URL(fileURLWithPath: h), options: .alwaysMapped) {
            for cut in stride(from: 0, to: min(d.count, 400_000), by: 997) { _ = FL.gdiFamilies(fontData: d.prefix(cut)) }
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<400 {
                var m = Data(d.prefix(8192))
                for _ in 0..<24 { m[Int.random(in: 0..<m.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
                _ = FL.gdiFamilies(fontData: m)
            }
            expect(true, "names: 400 cut-off and 400 scrambled copies of a real font, no crash")
            // Data whose first index is not 0 (a slice): same names.
            let shifted = (Data([1, 2, 3]) + d)[3...]
            expect(FL.gdiFamilies(fontData: shifted) == FL.gdiFamilies(fontData: d) && !FL.gdiFamilies(fontData: d).isEmpty,
                   "names: a Data slice that does not start at 0 reads the same")
        }

        report()
    }

    static func report() {
        print(failures == 0 ? "All FontLinkCore tests passed." : "\(failures) FontLinkCore test(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }
}
