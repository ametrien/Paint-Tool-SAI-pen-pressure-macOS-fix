// FontLinkCore.swift — Chinese, Japanese and Korean text in SAI with the Mac's
// own fonts (issue #39), as pure data.
//
// What is known (tested 2026-11-12, Wine Staging 11.16, a GDI test program in a
// throwaway prefix, no window):
//
//   SAI draws its menus, panels and dialogs with GDI and asks for Tahoma,
//   MS UI Gothic, Meiryo UI and MS PGothic (in sai2.exe also spelled
//   ＭＳ Ｐゴシック). On a Mac none of them has a Chinese, Japanese or Korean
//   character: Wine's Tahoma is Latin only and the others do not exist.
//   Wine already loads the fonts that come with macOS, where they are
//   (/System/Library/Fonts, /System/Library/AssetsV2). When a character is
//   missing, Wine tries the list for that font name under
//   HKLM\...\FontLink\SystemLink. Wine's lists only name Windows files
//   (MSGOTHIC.TTC, SIMSUN.TTC, ...), so every such character was a box.
//   With the Mac's fonts at the front of those five lists, every script draws.
//
// SAI's own Text tool is NOT covered: it reads font files with its own engine,
// which does not support CFF fonts yet (SYSTEMAX's Development Room page), and
// all of these Mac fonts are CFF.
//
// THE TRAPS this file guards:
//
//   1. Wine matches a list entry by FILE name and FAMILY name, both exactly
//      (case aside). The family is the font's Windows English name if it has
//      one: for Hiragino that carries the weight, "Hiragino Sans W3". The plain
//      "Hiragino Sans" matches nothing and Wine falls back to Arial, which is
//      why mapping to Hiragino by hand did nothing in an earlier test. The
//      tests check every entry against the real font files.
//
//   2. Off must give Wine's own list back exactly, in order. Our entries name
//      Mac font files, and Wine's lists name Windows files (MSYH.TTC, never
//      msyh.ttf), so Wine's list is the list without ours. Nothing has to be
//      remembered, and it stays right if Wine rewrites a list itself: ours are
//      then gone, and the next launch puts them back.
//
//   3. A value that is there but cannot be read is LEFT ALONE. Writing our
//      fonts over it would throw away Wine's own fallbacks for that name.
//
//   4. This never copies, bundles or downloads a font. It only names fonts
//      that are already on the Mac (and Wine's own). Apple's macOS licence
//      (macOS 26, section 2.E) lets its fonts display content while running
//      macOS; copying them elsewhere is not covered (2.N).
//
//   5. For a font name that does not exist (MS UI Gothic and the other
//      Japanese ones), Wine draws EVERY character with the first font in its
//      list, Latin and Cyrillic too. With Hiragino first, "Слой" came out as
//      full-width "С л о й". So those lists start with Wine's Arial, which is
//      what Wine used for these names before: Latin and Cyrillic look exactly
//      as they did, and only the missing characters are added. (Asked for with
//      the Japanese character set, Wine skips Arial and takes Hiragino, which
//      suits SAI in Japanese.) Tahoma exists, so its list needs no lead.
//
// No AppKit here: the tests compile this file on its own.

import Foundation

enum FontLinkCore {

    static let systemLinkKey = "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink"
    /// The same key as system.reg names it (relative to HKLM, single backslashes).
    static let systemLinkRegSection = "Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink"

    /// The font names SAI asks for (strings in sai2.exe). Each gets our fonts
    /// at the front of its list. Tahoma alone would do for most text, but SAI
    /// asking for a Japanese font with the Japanese character set would then
    /// get whichever installed font Wine finds first (in testing, a handwriting
    /// font with no Latin letters).
    static let saiFontNames = ["Tahoma", "MS UI Gothic", "Meiryo UI", "MS PGothic", "ＭＳ Ｐゴシック"]

    /// A font as a SystemLink entry: "FILE,FAMILY". See THE TRAP 1.
    struct LinkFont: Equatable {
        let file: String
        let family: String
        var entry: String { file + "," + family }
    }

    static let hiraginoSans  = LinkFont(file: "ヒラギノ角ゴシック W3.ttc", family: "Hiragino Sans W3")
    static let pingFangSC    = LinkFont(file: "PingFang.ttc", family: "PingFang SC")
    static let pingFangTC    = LinkFont(file: "PingFang.ttc", family: "PingFang TC")
    static let pingFangHK    = LinkFont(file: "PingFang.ttc", family: "PingFang HK")
    static let appleSDGothic = LinkFont(file: "AppleSDGothicNeo.ttc", family: "Apple SD Gothic Neo")
    /// Wine Staging's own "Microsoft Yahei" (from WenQuanYi Micro Hei, Apache
    /// 2.0). Has Chinese, Japanese and Korean. Last, for a Mac missing a font.
    static let wineYahei     = LinkFont(file: "msyh.ttf", family: "Microsoft Yahei")
    /// Wine's own Arial, first for the names that have no font (THE TRAP 5).
    static let wineArial     = LinkFont(file: "arial.ttf", family: "Arial")

    /// Every entry this app ever writes. Anything else in a list is Wine's.
    static let allOurs = [wineArial, hiraginoSans, pingFangSC, pingFangTC, pingFangHK, appleSDGothic, wineYahei]

    /// Our entries for one of SAI's font names, in order.
    static func entries(for name: String, fonts: [LinkFont]) -> [String] {
        let lead = name.caseInsensitiveCompare("Tahoma") == .orderedSame ? [] : [wineArial]
        return (lead + fonts).map(\.entry)
    }

    /// With no Chinese, Japanese or Korean among the Mac's languages: Japanese
    /// first, since SAI's only other language is Japanese. Each font lacks
    /// something the next one has (Hiragino has no 设, PingFang no Korean).
    static let defaultOrder = [hiraginoSans, pingFangSC, pingFangTC, appleSDGothic]

    /// The font for one of the Mac's preferred languages ("zh-Hans-CN",
    /// "zh_TW", "ja-JP", "ko"), or nil for any other language.
    static func font(forLanguage tag: String) -> LinkFont? {
        let parts = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let lang = parts.first else { return nil }
        let rest = Set(parts.dropFirst())
        switch lang {
        case "ja": return hiraginoSans
        case "ko": return appleSDGothic
        case "yue": return rest.contains("hans") ? pingFangSC : pingFangHK
        case "zh":
            if rest.contains("hk") || rest.contains("mo") { return pingFangHK }
            if rest.contains("hant") || rest.contains("tw") { return pingFangTC }
            return pingFangSC                       // zh, zh-Hans, zh-CN, zh-SG
        default: return nil
        }
    }

    /// The Mac's preferred languages first, then the rest, then Wine's Yahei.
    /// Same character in two fonts (Han unification): the first one wins, so a
    /// Chinese Mac gets Chinese shapes and a Japanese Mac Japanese ones.
    static func order(preferredLanguages: [String]) -> [LinkFont] {
        var out: [LinkFont] = []
        for f in preferredLanguages.compactMap(font(forLanguage:)) + defaultOrder + [wineYahei]
        where !out.contains(f) {
            out.append(f)
        }
        return out
    }

    // MARK: - the choice in Advanced › Display

    /// One line of the Language dropdown: SAI's menu language (sai2.ini
    /// `[Locale] lang`) and the font in front. SAI only has English and Japanese
    /// menus (nothing else is in sai2.exe), so Chinese and Korean keep English
    /// menus and only choose the font. `font` nil means Automatic.
    struct LanguageOption: Equatable {
        let title: String
        let saiLanguage: String
        let font: LinkFont?
    }

    static let languageOptions = [
        LanguageOption(title: "English", saiLanguage: "en", font: nil),
        LanguageOption(title: "日本語", saiLanguage: "ja", font: hiraginoSans),
        LanguageOption(title: "简体中文", saiLanguage: "en", font: pingFangSC),
        LanguageOption(title: "繁體中文", saiLanguage: "en", font: pingFangTC),
        LanguageOption(title: "한국어", saiLanguage: "en", font: appleSDGothic),
    ]

    /// What the dropdown shows as selected.
    enum Selection: Equatable {
        case language(Int)          // index into languageOptions
        case font(LinkFont)         // one of the person's own fonts
        case off
    }

    /// The selection for what is stored. `saiLanguage` is the stored menu
    /// language, or sai2.ini's when none is stored. Japanese menus win (there
    /// is only one Japanese line); otherwise the font says which line it is.
    static func selection(saiLanguage: String?, font: Choice) -> Selection {
        switch font {
        case .off:
            return .off
        case .font(let f, _) where !languageOptions.contains(where: { $0.font == f }):
            return .font(f)
        default:
            break
        }
        if saiLanguage == "ja", let i = languageOptions.firstIndex(where: { $0.saiLanguage == "ja" }) {
            return .language(i)
        }
        if case .font(let f, _) = font,
           let i = languageOptions.firstIndex(where: { $0.font == f && $0.saiLanguage != "ja" }) {
            return .language(i)
        }
        return .language(0)                                   // English, Automatic
    }

    /// The font choice a language line stands for. `path` is where that font
    /// is on this Mac (shown under the dropdown).
    static func choice(for option: LanguageOption, path: String?) -> Choice {
        guard let f = option.font else { return .automatic }
        return .font(f, path: path ?? "")
    }

    /// What the dropdown says. Stored as one line in Application Support.
    enum Choice: Equatable {
        /// The Mac's preferred languages decide (order(preferredLanguages:)).
        case automatic
        /// None of ours in Wine's lists: SAI shows boxes, as before.
        case off
        /// This font first, the automatic ones behind it, so a script the
        /// chosen font lacks (Korean in a Japanese font) still shows. `path`
        /// is where the file was when chosen, for showing and Copy path.
        case font(LinkFont, path: String)

        /// Missing, empty, "on" (the first test build) or anything unreadable
        /// is Automatic. It only changes which font Wine uses where SAI's own
        /// font has no character, so there is nothing to lose by default.
        init(stored: String?) {
            let s = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if s == "off" { self = .off; return }
            let p = s.components(separatedBy: "\t")
            if p.count == 4, p[0] == "font", !p[1].isEmpty, !p[2].isEmpty,
               !p[1].contains(","), !p[1].contains("\\") {
                self = .font(LinkFont(file: p[1], family: p[2]), path: p[3])
            } else {
                self = .automatic
            }
        }

        /// Tabs between the parts: file and family names never hold one.
        var stored: String {
            switch self {
            case .automatic: return "auto"
            case .off: return "off"
            case .font(let f, let path): return ["font", f.file, f.family, path].joined(separator: "\t")
            }
        }
    }

    /// The fonts to put in front, in order, for a choice.
    static func fonts(for choice: Choice, preferredLanguages: [String]) -> [LinkFont] {
        let auto = order(preferredLanguages: preferredLanguages)
        switch choice {
        case .automatic: return auto
        case .off: return []
        case .font(let f, _): return [f] + auto.filter { $0 != f }
        }
    }

    /// A font chosen from the Mac's own folder is ours too, but only this app
    /// knows it wrote it. So every chosen entry that is not in allOurs is kept
    /// in a small list, and Off and every later choice take those out as well
    /// (THE TRAP 2 for chosen fonts). The list only grows; taking out an entry
    /// that is not there does nothing.
    static func remembering(_ chosen: LinkFont, in remembered: [String]) -> [String] {
        if isOurs(chosen.entry) || remembered.contains(where: { $0.caseInsensitiveCompare(chosen.entry) == .orderedSame }) {
            return remembered
        }
        return remembered + [chosen.entry]
    }

    /// THE TRAP 2 again: a font Wine's own lists already name (SimSun from an
    /// Office install, say) must never be offered. Off would take it out of
    /// Wine's list too. Wine falls back to such a font already anyway.
    static func canOffer(_ f: LinkFont, wineEntries: [String]) -> Bool {
        !wineEntries.contains { $0.caseInsensitiveCompare(f.entry) == .orderedSame }
    }

    /// Every entry in Wine's own part of the lists (ours taken out).
    static func wineEntries(_ links: [String: Value]?, remembered: [String] = []) -> [String] {
        (links ?? [:]).values.flatMap { v -> [String] in
            if case .list(let l) = v { return withoutOurs(l, remembered: remembered) }
            return []
        }
    }

    // MARK: - reading a font file's family the way Wine does

    /// The family names Wine can match in a font file (THE TRAP 1): per face,
    /// the Windows US-English family name if the face has one, otherwise the
    /// Mac or Unicode one. In face order, each once. Only reads the file's
    /// name table; never writes or copies it. Every offset is checked, so a
    /// broken or hostile file gives fewer names, never a crash.
    static func gdiFamilies(fontData d: Data) -> [String] {
        func u8(_ o: Int) -> Int? { o >= 0 && o < d.count ? Int(d[d.startIndex + o]) : nil }
        func u16(_ o: Int) -> Int? { guard let a = u8(o), let b = u8(o + 1) else { return nil }; return a << 8 | b }
        func u32(_ o: Int) -> Int? { guard let a = u16(o), let b = u16(o + 2) else { return nil }; return a << 16 | b }
        func bytes(_ o: Int, _ n: Int) -> Data? {
            guard o >= 0, n >= 0, o + n <= d.count else { return nil }
            return d.subdata(in: (d.startIndex + o)..<(d.startIndex + o + n))
        }
        var faces = [0]
        if bytes(0, 4) == Data("ttcf".utf8), let n = u32(8) {
            faces = (0..<min(n, 64)).compactMap { u32(12 + 4 * $0) }
        }
        var out: [String] = []
        for f in faces {
            guard let tables = u16(f + 4) else { continue }
            var nameAt: Int?
            for t in 0..<min(tables, 128) where bytes(f + 12 + 16 * t, 4) == Data("name".utf8) {
                nameAt = u32(f + 12 + 16 * t + 8)
            }
            guard let nt = nameAt, let count = u16(nt + 2), let strOff = u16(nt + 4) else { continue }
            var windows: String?, mac: String?
            for r in 0..<min(count, 4096) {
                let rec = nt + 6 + 12 * r
                guard let pid = u16(rec), let lid = u16(rec + 4), let nid = u16(rec + 6),
                      let len = u16(rec + 8), let off = u16(rec + 10), nid == 1,
                      let raw = bytes(nt + strOff + off, len) else { continue }
                if pid == 3 && lid == 0x409 { windows = String(data: raw, encoding: .utf16BigEndian) }
                else if pid == 1 && lid == 0 && mac == nil { mac = String(data: raw, encoding: .macOSRoman) }
                else if pid == 0 && mac == nil { mac = String(data: raw, encoding: .utf16BigEndian) }
            }
            if let name = windows ?? mac, !name.isEmpty, !out.contains(name) { out.append(name) }
        }
        return out
    }

    // MARK: - where the fonts are

    /// Folders where macOS and Wine keep the fonts this app names, in the order
    /// to look. PingFang is a macOS download ("asset"), so its folder has a hash
    /// in it and is found by listing.
    static func fontDirs(home: String, wineFontsDir: String?, listDir: (String) -> [String]) -> [String] {
        var dirs = ["/System/Library/Fonts", "/System/Library/Fonts/Supplemental",
                    "/Library/Fonts", home + "/Library/Fonts"]
        let assets = "/System/Library/AssetsV2"
        for kind in listDir(assets).sorted() where kind.hasPrefix("com_apple_MobileAsset_Font") {
            for a in listDir(assets + "/" + kind).sorted() { dirs.append("\(assets)/\(kind)/\(a)/AssetData") }
        }
        if let w = wineFontsDir { dirs.append(w) }
        return dirs
    }

    /// Fonts the person installed themselves (Font Book puts them here). Wine on
    /// a Mac loads these too.
    static func installedFontDirs(home: String) -> [String] { [home + "/Library/Fonts", "/Library/Fonts"] }

    static let fontFileExtensions: Set<String> = ["ttf", "ttc", "otf", "otc"]

    // MARK: - reading the lists from system.reg

    enum Value: Equatable {
        case list([String])
        /// There, but not in a form read here (THE TRAP 3).
        case unreadable
    }

    /// The SystemLink values, keyed by name as written. nil when the section is
    /// not in the file at all (no prefix yet, or Wine has not written it):
    /// then nothing is touched.
    static func systemLinks(systemReg: String) -> [String: Value]? {
        let header = "[" + systemLinkRegSection.lowercased().replacingOccurrences(of: "\\", with: "\\\\") + "]"
        var inSection = false, found = false
        var out: [String: Value] = [:]
        for raw in systemReg.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                // "[Key] 1789057661": the number after the bracket is a timestamp.
                inSection = line.lowercased().hasPrefix(header)
                found = found || inSection
                continue
            }
            guard inSection, line.hasPrefix("\""), let (name, rest) = splitNameAndData(line) else { continue }
            if rest.hasPrefix("str(7):\""), rest.hasSuffix("\"") {
                let body = String(rest.dropFirst("str(7):\"".count).dropLast())
                out[name] = .list(unescape(body).components(separatedBy: "\0").filter { !$0.isEmpty })
            } else {
                out[name] = .unreadable            // hex(7), another type, a broken line
            }
        }
        return found ? out : nil
    }

    /// `"Name"=data` -> (Name, data), with the name's escapes undone.
    private static func splitNameAndData(_ line: String) -> (String, String)? {
        var name = "", i = line.index(after: line.startIndex), escaped = false
        while i < line.endIndex {
            let c = line[i]
            if escaped { name.append("\\"); name.append(c); escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { break }
            else { name.append(c) }
            i = line.index(after: i)
        }
        guard i < line.endIndex else { return nil }
        let afterQuote = line.index(after: i)
        guard afterQuote < line.endIndex, line[afterQuote] == "=" else { return nil }
        return (unescape(name), String(line[line.index(after: afterQuote)...]))
    }

    /// Wine's escapes in .reg strings: \\ \" \0 \n \r \t, and \xNNNN for
    /// anything outside ASCII (1 to 4 hex digits; Wine writes 4 when a hex
    /// digit follows, so reading up to 4 is right). "\0" becomes a real NUL.
    static func unescape(_ s: String) -> String {
        var out = ""
        var it = Array(s.unicodeScalars)[...]
        while let c = it.popFirst() {
            guard c == "\\", let n = it.popFirst() else { out.unicodeScalars.append(c); continue }
            switch n {
            case "0": out.append("\0")
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "x":
                var hex = ""
                while hex.count < 4, let h = it.first, h.properties.isASCIIHexDigit {
                    hex.unicodeScalars.append(h); it.removeFirst()
                }
                if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                else { out.append("\\x" + hex) }
            default: out.unicodeScalars.append(n)  // \\ and \"
            }
        }
        return out
    }

    // MARK: - what to write

    /// `remembered`: entries of fonts chosen in the dropdown (see remembering).
    static func isOurs(_ entry: String, remembered: [String] = []) -> Bool {
        allOurs.contains { $0.entry.caseInsensitiveCompare(entry) == .orderedSame }
            || remembered.contains { $0.caseInsensitiveCompare(entry) == .orderedSame }
    }

    /// Wine's own list: the list without our entries (THE TRAP 2).
    static func withoutOurs(_ list: [String], remembered: [String] = []) -> [String] {
        list.filter { !isOurs($0, remembered: remembered) }
    }

    /// One value to write. `list` nil means delete the value: it was not there
    /// before ours (ＭＳ Ｐゴシック has no list of Wine's own).
    struct Change: Equatable {
        let name: String
        let list: [String]?
    }

    /// What to write for the five names.
    ///
    /// `force` writes every name even when the file already looks right. After
    /// a click it has to: Wine writes system.reg a few seconds after a change,
    /// so the file can still show the state from before an earlier click, and
    /// skipping "unchanged" values would then leave the old state in Wine. The
    /// lists written are right either way, because they are computed from
    /// Wine's own part, which a lagging file has too. At launch, force is off:
    /// a normal launch starts no reg.exe at all.
    static func changes(current: [String: Value]?, on: Bool, fonts: [LinkFont],
                        remembered: [String] = [], force: Bool = false) -> [Change] {
        guard let current = current else { return [] }
        var out: [Change] = []
        for name in saiFontNames {
            let key = current.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame }
            let value = key.flatMap { current[$0] }
            if value == .unreadable { continue }                          // THE TRAP 3
            let now: [String]? = { if case .list(let l)? = value { return l }; return nil }()
            let wine = withoutOurs(now ?? [], remembered: remembered)
            let target: [String]? = on ? entries(for: name, fonts: fonts) + wine : (wine.isEmpty ? nil : wine)
            if !force && target == (now.map { $0.isEmpty ? nil : $0 } ?? nil) { continue }
            // Nothing there and nothing wanted: no delete to send.
            if target == nil && now == nil && !force { continue }
            out.append(Change(name: key ?? name, list: target))
        }
        return out
    }

    /// The `wine reg` arguments for one change. reg.exe splits REG_MULTI_SZ
    /// data at a literal backslash-zero, and rejects an empty entry, so no
    /// list here ever holds one (empty entries are dropped when reading).
    static func regCommand(_ c: Change) -> [String] {
        if let list = c.list {
            return ["reg", "add", systemLinkKey, "/v", c.name, "/t", "REG_MULTI_SZ",
                    "/d", list.joined(separator: "\\0"), "/f"]
        }
        return ["reg", "delete", systemLinkKey, "/v", c.name, "/f"]
    }
}
