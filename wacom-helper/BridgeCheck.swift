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
            return "SAI is running but hasn't loaded our DLL. Press Repair."
        case .noContext:
            return "Loaded, but SAI isn't set to Use WinTab API. Turn it on."
        case .noSamples:
            return "Loaded, but no pen samples are arriving from this app."
        case .ignoring:
            return "SAI gets pressure but reads none. Try the AirBrush tool."
        case .working:
            return "Working. SAI has drawn \(status?.fetched ?? 0) points."
        }
    }

    // ---- 2b. the DLL file in the prefix -------------------------------------
    // The prefix DLL and this app's helper are a matched pair (#21), so any
    // difference is worth a row. But "different" covers two very unlike
    // situations, and the row used to say the alarming one for both.
    //
    // The common one, by far, is version skew: a second copy of this app —
    // a fresh build in dist/ next to the one in /Applications — was launched
    // once and left its own, newer DLL behind. Nothing is broken; the two
    // copies are simply not the same build, and whichever one you open next
    // complains about the other's file. Calling that a broken bridge sends
    // people to Repair, which quietly DOWNGRADES the prefix to the older
    // copy's DLL. So it is named for what it is, and says which way it goes.

    enum DLLSkew: Equatable {
        case matches        // byte-identical: nothing to say
        case prefixNewer    // another, newer build of this app installed it
        case differs        // older or unrelated: the honest "press Repair"
    }

    /// Classify the DLL in the prefix against the one shipped in this app.
    ///
    /// Dates decide the direction only; `identical` decides whether there is
    /// anything to report at all. A missing date means we cannot tell newer
    /// from older, and the cautious answer is the general one.
    static func dllSkew(identical: Bool, prefixDate: Date?, shippedDate: Date?) -> DLLSkew {
        if identical { return .matches }
        guard let p = prefixDate, let s = shippedDate, p > s else { return .differs }
        return .prefixNewer
    }

    /// The row's sentence for a skew. Under sixty characters, like the rest.
    static func explainSkew(_ skew: DLLSkew) -> String {
        switch skew {
        case .matches:     return ""
        case .prefixNewer: return "A newer build set this up. Repair goes back to this one."
        case .differs:     return "A different wintab32.dll than this app's. Press Repair."
        }
    }

    // ---- 3. the probe: the far side, tested with SAI closed ------------------
    // Everything above answers "what is happening right now inside SAI", which
    // needs SAI to be running and being drawn in. That is a lot to ask of
    // someone reporting a bug, and it is the reason #29 went round twice: the
    // only proof anyone could offer was a stroke that came out flat.
    //
    // wtprobe.exe removes SAI from the question. It is a separate Windows
    // process that loads wintab32.dll the same way SAI does — through the same
    // DllOverrides key — opens a context and answers the DLL's WT_PACKET
    // messages. So it exercises every link the pen depends on, in three
    // seconds, with nothing else open. Parsing what it says is deterministic,
    // so it lives here; running it needs Wine and lives in Setup.swift.

    struct Probe: Equatable {
        var dllLoaded = false      // a wintab32 loaded at all
        var ours = false           // ...and it was OURS, not Wine's built-in
        var build = ""             // which build of ours
        var entryPoints = false    // the WinTab functions resolved
        var contextOpen = false    // a tablet context could be opened
        var msgs = 0               // WT_PACKET messages the DLL posted
        var fetched = 0            // of those, the ones WTPacket handed over
        var down = 0               // packets with the tip switch pressed
        var pmaxSeen = 0           // strongest pressure that arrived
        var secs = 0               // how long it listened
    }

    /// Parse wtprobe.exe's key=value output. nil when the output isn't the
    /// probe's at all (wine printed an error, nothing ran, the file is
    /// missing) — which must not be mistaken for a probe that ran and found
    /// nothing, because those two call for opposite advice.
    static func parseProbe(_ text: String) -> Probe? {
        var p = Probe()
        var sawMarker = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            let val = String(line[line.index(after: eq)...])
            switch key {
            case "probe":       sawMarker = true
            case "dll":         p.dllLoaded = (val == "loaded")
            case "ours":        p.ours = (val == "yes")
            case "build":       p.build = (val == "-") ? "" : val
            case "entrypoints": p.entryPoints = (val == "ok")
            case "ctx":         p.contextOpen = (val == "open")
            case "msgs":        p.msgs = Int(val) ?? 0
            case "fetched":     p.fetched = Int(val) ?? 0
            case "down":        p.down = Int(val) ?? 0
            case "pmax_seen":   p.pmaxSeen = Int(val) ?? 0
            case "secs":        p.secs = Int(val) ?? 0
            default: break
            }
        }
        return sawMarker ? p : nil
    }

    /// One streamed line from a probe running ALONGSIDE the pen test:
    ///
    ///     tick=1 p=1234 msgs=88 fetched=87 pmax=3381 down=80
    ///
    /// Space-separated on a single line, unlike the one-key-per-line summary,
    /// because this is read live out of a pipe and one line is the unit that
    /// arrives whole. `p` is the pressure in the most recent packet, which is
    /// what makes a received-side bar possible next to the sent-side one.
    struct Tick: Equatable {
        var pressure = 0
        var msgs = 0
        var fetched = 0
        var pmax = 0
        var down = 0
    }

    /// Take whole lines off the front of a streaming buffer, leaving any
    /// partial last line behind for the next read.
    ///
    /// THE TRAP: this reads the output of a WINDOWS program, so its lines end
    /// with CRLF — and Swift counts "\r\n" as ONE Character, which is not
    /// equal to "\n". `firstIndex(of: "\n")` therefore never matches, the
    /// buffer grows without ever yielding a line, and the caller sits waiting
    /// for data it has already been given. That is not hypothetical: it is
    /// exactly how the received-side bar came to sit at "starting…" while the
    /// probe was streaming perfectly into the pipe. Matching a character SET
    /// is what makes it work for CRLF and LF alike.
    static func takeLines(_ buffer: inout String) -> [String] {
        var lines: [String] = []
        while let r = buffer.rangeOfCharacter(from: .newlines) {
            let line = String(buffer[buffer.startIndex..<r.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            // CR and LF are matched one at a time, so a CRLF hands back the
            // line and then an empty string. Every line the probe writes is a
            // key=value, never blank, so dropping blanks is safe — and it makes
            // CRLF, plain LF, and a read that happens to split between the two
            // all behave identically, which is worth more here than fidelity to
            // whitespace nobody sends.
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    /// nil for any line that isn't a tick — the probe's header lines come down
    /// the same pipe, and treating one of those as an all-zero tick would park
    /// the received bar at zero while the pen was being pressed.
    static func parseTick(_ line: String) -> Tick? {
        var t = Tick()
        var isTick = false
        for field in line.split(separator: " ") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let v = Int(parts[1]) else { continue }
            switch parts[0] {
            case "tick":    isTick = (v == 1)
            case "p":       t.pressure = v
            case "msgs":    t.msgs = v
            case "fetched": t.fetched = v
            case "pmax":    t.pmax = v
            case "down":    t.down = v
            default: break
            }
        }
        return isTick ? t : nil
    }

    /// Fold a live tick's counters into what the header said.
    ///
    /// THE TRAP: the header — everything the probe prints before its first
    /// tick — describes the WIRING (which DLL, whether a context opened) and
    /// can say nothing about traffic, because at that moment none has happened.
    /// Judging the far side from the header alone therefore fixes the answer at
    /// "no pen data reached it" for ever, and it stays on screen contradicting
    /// a received-side bar that is visibly moving. The counters have to come
    /// from the ticks, and the verdict has to be recomputed as they arrive.
    static func merging(_ probe: Probe?, _ tick: Tick) -> Probe? {
        guard var p = probe else { return nil }
        p.msgs = tick.msgs
        p.fetched = tick.fetched
        p.pmaxSeen = tick.pmax
        p.down = tick.down
        return p
    }

    enum ProbeVerdict: Equatable {
        case didNotRun      // wine couldn't run it, or it isn't the probe's output
        case noDLL          // nothing called wintab32 loaded at all
        case wineOwnDLL     // a wintab32 loaded — Wine's. THIS is #29.
        case unusable       // ours, but the entry points aren't there
        case noContext      // ours, loaded, but it wouldn't open a context
        case noPackets      // all wired up; nothing came down the wire
        case notReadable    // packets were posted but couldn't be read back
        case working
    }

    /// Order is the argument. "A wintab32 loaded" was the answer that made #29
    /// look healthy for weeks, so `dllLoaded` is never good news on its own —
    /// `ours` is asked immediately after, and everything else is only worth
    /// saying once that is a yes.
    static func probeVerdict(_ p: Probe?) -> ProbeVerdict {
        guard let p = p else { return .didNotRun }
        if !p.dllLoaded { return .noDLL }
        if !p.ours { return .wineOwnDLL }
        if !p.entryPoints { return .unusable }
        if !p.contextOpen { return .noContext }
        if p.msgs == 0 { return .noPackets }
        if p.fetched == 0 { return .notReadable }
        return .working
    }

    /// One sentence for someone who has just pressed a button called "Test the
    /// SAI side" and is owed a plain answer. Longer than explain()'s, because
    /// these are shown in a result label rather than a checklist row.
    static func explainProbe(_ v: ProbeVerdict, _ p: Probe?) -> String {
        switch v {
        case .didNotRun:
            return "The test couldn't run inside Wine. Check Wine is installed."
        case .noDLL:
            return "Wine has no wintab32 at all. Press Repair."
        case .wineOwnDLL:
            return "Wine loaded its own wintab32, not ours. SAI would get no pressure. Press Repair."
        case .unusable:
            return "The wintab32 in Wine is ours but unusable. Press Repair."
        case .noContext:
            return "Our DLL loaded but wouldn't open a tablet context. Press Repair."
        case .noPackets:
            return "Our DLL is live inside Wine, but no pen data reached it. Press the pen while the test runs."
        case .notReadable:
            return "Pen data reached our DLL but couldn't be read back out. Please report this."
        case .working:
            let n = p?.fetched ?? 0
            let peak = p?.pmaxSeen ?? 0
            return "Working. \(n) packets arrived inside Wine, up to \(peak)."
        }
    }
}
