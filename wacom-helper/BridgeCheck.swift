// BridgeCheck.swift — the PURE logic behind one question the app could never
// answer before: is the bridge actually working inside SAI?
//
// Everything else the setup window checks lives on the mac side, where we can
// see it. The half that matters is the DLL loaded into SAI's own process, and
// until #29 nothing looked at it: a field report came back with every check
// green — permission granted, DLL file present, pressure bar moving — while
// SAI was drawing with the plain mouse the whole time, because Wine had been
// loading its OWN wintab32 all along. Every symptom of that is invisible from
// here, so the app has to read two things it had been ignoring:
//
//   1. the Wine registry override that decides WHICH wintab32 gets loaded, and
//   2. the status file our DLL writes from inside SAI (see wtc_format_status).
//
// Parsing both is deterministic input -> output, so it lives here and is
// covered by tests/BridgeTests.swift. The file I/O and the repair (which needs
// wine) stay in Setup.swift.

import Foundation

enum BridgeCheck {

    // ---- 1. the registry override -------------------------------------------
    // Wine prefers its BUILT-IN wintab32 unless the prefix says otherwise, and
    // the file we install is simply ignored without this key. It is written
    // once, by installBridge(), and nothing re-checked it afterwards — so a
    // prefix that never got it (built by an older version, or left behind by a
    // half-finished reset) stayed broken through every relaunch, reinstall of
    // the app, and permission re-grant. Reading user.reg costs nothing and can
    // be done with wine not even running.

    /// The value of the wintab32 DLL override in a `user.reg`, or nil when the
    /// key isn't there at all.
    ///
    /// Both spellings count: winecfg writes `"*wintab32"`, `wine reg add`
    /// writes `"wintab32"`, and either makes Wine load ours. Section headers in
    /// user.reg escape their backslashes (`[Software\\Wine\\DllOverrides]`),
    /// hence the unescaping before comparison.
    static func overrideValue(inUserReg text: String) -> String? {
        var inSection = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                // "[Software\\Wine\\DllOverrides] 1757500000" -> the key path
                guard let close = line.firstIndex(of: "]") else { inSection = false; continue }
                let path = String(line[line.index(after: line.startIndex)..<close])
                    .replacingOccurrences(of: "\\\\", with: "\\")
                inSection = path.caseInsensitiveCompare("Software\\Wine\\DllOverrides") == .orderedSame
                continue
            }
            guard inSection, line.hasPrefix("\"") else { continue }
            let parts = line.components(separatedBy: "\"")
            // "wintab32"="native,builtin"  ->  ["", "wintab32", "=", "native,builtin", ""]
            guard parts.count >= 4 else { continue }
            var name = parts[1]
            if name.hasPrefix("*") { name.removeFirst() }
            guard name.caseInsensitiveCompare("wintab32") == .orderedSame else { continue }
            return parts[3]
        }
        return nil
    }

    /// The same value as printed by `wine reg query`, which is what wineserver
    /// currently holds rather than what user.reg has got round to spelling.
    ///
    /// Needed because the two disagree for several seconds after every write:
    /// see bridgeOverrideViaWine(). The output is a header line then one
    /// indented row per value —
    ///
    ///     HKEY_CURRENT_USER\Software\Wine\DllOverrides
    ///         wintab32    REG_SZ    native,builtin
    ///
    /// — so the value is whatever follows REG_SZ on the wintab32 row. Matched
    /// on the NAME field rather than "does the line contain wintab32", or a
    /// neighbouring override whose value happened to mention it would answer
    /// for ours.
    static func overrideValue(inRegQuery text: String) -> String? {
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let typeRange = line.range(of: "REG_SZ") else { continue }
            var name = String(line[line.startIndex..<typeRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard name.caseInsensitiveCompare("wintab32") == .orderedSame else { continue }
            return String(line[typeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Does that value actually make Wine load OUR dll?
    ///
    /// The value is a preference ORDER, so "builtin,native" is not a weaker yes
    /// — it is a no: Wine finds its own first and never looks at ours. Only a
    /// list that starts with native counts.
    static func overrideIsNative(_ value: String?) -> Bool {
        guard let v = value else { return false }
        let first = v.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
        return first?.caseInsensitiveCompare("native") == .orderedSame
    }

    // ---- 2. the status file our DLL writes ----------------------------------

    struct Status: Equatable {
        var build = ""          // when the loaded DLL was compiled
        var open = false        // SAI opened a WinTab context
        var recv = 0            // samples that reached the DLL from this app
        var posted = 0          // packets the DLL posted to SAI
        var fetched = 0         // packets SAI actually came and read
        var pmax = 0            // full-scale pressure the DLL is advertising
    }

    /// Parse `wt_status.txt`. Deliberately lenient about unknown keys (a newer
    /// DLL may add some) but strict about the `v=` marker, so we never report
    /// on some other file that happens to be sitting there.
    static func parseStatus(_ text: String) -> Status? {
        var s = Status()
        var sawVersion = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            let val = String(line[line.index(after: eq)...])
            switch key {
            case "v":       sawVersion = true
            case "build":   s.build = val
            case "open":    s.open = (val == "1")
            case "recv":    s.recv = Int(val) ?? 0
            case "posted":  s.posted = Int(val) ?? 0
            case "fetched": s.fetched = Int(val) ?? 0
            case "pmax":    s.pmax = Int(val) ?? 0
            default: break
            }
        }
        return sawVersion ? s : nil
    }

    // ---- 3. what the numbers mean -------------------------------------------
    // Four failures used to look identical from outside — "strokes draw, but
    // pressure is flat" — and telling them apart took a debug log, a rebuild,
    // and a round of correspondence each time. They are one glance apart here.

    enum Verdict: Equatable {
        case notLoaded      // SAI never loaded our DLL (or it died)
        case noContext      // loaded, but SAI never asked for a tablet
        case noSamples      // SAI is listening; nothing is arriving from us
        case ignoring       // samples arrive, SAI doesn't read the packets
        case working
    }

    /// `ageSeconds` is how long ago the DLL last wrote the file; nil when there
    /// is no file. The DLL refreshes it about once a second, so anything older
    /// than a few seconds means nothing is running on that side — which is the
    /// same conclusion as no file at all, and must not be reported as the state
    /// the stale file happens to describe.
    static func verdict(_ status: Status?, ageSeconds: Double?, staleAfter: Double = 5) -> Verdict {
        guard let s = status, let age = ageSeconds, age <= staleAfter else { return .notLoaded }
        if !s.open { return .noContext }
        if s.recv == 0 { return .noSamples }
        if s.fetched == 0 { return .ignoring }
        return .working
    }

    /// One sentence a person can act on, written for someone who has just been
    /// told "pressure doesn't work" and has no idea which half is at fault.
    ///
    /// Short on purpose: these are printed into a checklist row that truncates,
    /// and a warning cut off mid-word is worse than a blunt one.
    static func explain(_ verdict: Verdict, _ status: Status?) -> String {
        switch verdict {
        case .notLoaded:
            return "SAI is running but hasn't loaded our DLL — press Repair."
        case .noContext:
            return "Loaded, but SAI isn't set to Use WinTab API — turn it on."
        case .noSamples:
            return "Loaded, but no pen samples are arriving from this app."
        case .ignoring:
            return "SAI gets pressure but reads none — check the brush Min Size."
        case .working:
            return "Working — SAI has drawn \(status?.fetched ?? 0) points."
        }
    }
}
